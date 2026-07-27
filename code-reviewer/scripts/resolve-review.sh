#!/usr/bin/env bash
#
# PR 라벨을 읽어 리뷰 실행 여부와 리뷰 프롬프트를 결정한다.
#
# 라벨 해석 규칙 (우선순위 순)
#   1. label_profile_map 에 명시된 라벨      -> 매핑된 프로필
#   2. <review_label>                        -> default_profile
#   3. <review_label><separator><profile>    -> <profile>
#
# 출력 (GITHUB_OUTPUT)
#   should_review : true/false
#   profiles      : 적용된 프로필 (쉼표 구분)
#   prompt        : 조립된 리뷰 프롬프트
#
set -euo pipefail

LABELS_JSON="${LABELS_JSON:-[]}"
REVIEW_LABEL="${REVIEW_LABEL:-claude-review}"
PROFILE_SEPARATOR="${PROFILE_SEPARATOR:-:}"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-default}"
LABEL_PROFILE_MAP="${LABEL_PROFILE_MAP:-}"
REQUIRE_LABEL="${REQUIRE_LABEL:-true}"
PROMPTS_DIR="${PROMPTS_DIR:-}"
EXTRA_INSTRUCTIONS="${EXTRA_INSTRUCTIONS:-}"
PROMPT_OVERRIDE="${PROMPT_OVERRIDE:-}"
ALL_KEYWORD="${ALL_KEYWORD:-all}"
# ':-' 가 아닌 '-' 를 쓴다. 빈 문자열은 "제외 없음"이라는 유효한 의도이므로 기본값으로 덮지 않는다
ALL_EXCLUDES="${ALL_EXCLUDES-quick}"
BUILTIN_PROMPTS_DIR="${BUILTIN_PROMPTS_DIR:?BUILTIN_PROMPTS_DIR 가 설정되지 않았습니다}"

# 쉼표/공백 구분을 공백 하나로 정규화하고 양끝을 감싸, case 부분일치로 제외 여부를 판정한다
ALL_EXCLUDES_SET=" $(printf '%s' "$ALL_EXCLUDES" | tr ',\n\t' '   ') "

# 참고: bash 4.3 이하는 set -u 아래에서 빈 배열 확장이 에러라 '${arr[@]+"${arr[@]}"}' 로 감싼다
# (러너는 bash 5.x 지만 로컬 macOS bash 3.2 에서도 돌려볼 수 있도록 유지)

# ---------------------------------------------------------------- 공용 헬퍼
join_csv() {
  local IFS=,
  printf '%s' "$*"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

emit() {
  local name="$1" value="$2" delim
  # 값 안에 구분자와 같은 줄이 있으면 GitHub 의 출력 파싱이 깨진다.
  # 프롬프트는 사용자 입력(extra_instructions, prompt, 프롬프트 파일)을 담으므로
  # 무작위 구분자를 쓰고, 그래도 겹치면 다시 뽑는다.
  delim="ghadelim_${name}_${RANDOM}${RANDOM}"
  while [[ $value == *"$delim"* ]]; do
    delim="ghadelim_${name}_${RANDOM}${RANDOM}"
  done
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >>"$GITHUB_OUTPUT"
}

# Job Summary 한 블록을 추가한다 (헤더는 여기서만 정의)
summary() {
  {
    printf '### 🤖 Claude Code Review\n\n'
    printf '%s\n' "$@"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

skip_review() {
  echo "⏭️  리뷰 건너뜀: $1"
  emit "should_review" "false"
  emit "profiles" ""
  emit "prompt" ""
  summary "리뷰를 건너뛰었습니다 — $1"
  exit 0
}

# ---------------------------------------------------------------- 라벨 파싱
LABELS=()
while IFS= read -r line; do
  [ -n "$line" ] && LABELS+=("$line")
done < <(printf '%s' "$LABELS_JSON" | jq -r 'if type == "array" then .[] else empty end')

echo "🏷️  PR 라벨: ${LABELS[*]:-(없음)}"
echo "🔎 기준 라벨: '${REVIEW_LABEL}' (프로필 구분자: '${PROFILE_SEPARATOR}')"

# label_profile_map 조회: `라벨=프로필` 한 줄에 하나씩
lookup_mapped_profile() {
  local target="$1" line key
  [ -z "$LABEL_PROFILE_MAP" ] && return 0
  while IFS= read -r line; do
    line="$(trim "$line")"
    case "$line" in '' | \#*) continue ;; esac
    [ "$line" = "${line%=*}" ] && continue # '=' 없는 줄은 무시
    key="$(trim "${line%%=*}")"
    if [ "$key" = "$target" ]; then
      trim "${line#*=}"
      return 0
    fi
  done <<<"$LABEL_PROFILE_MAP"
}

PROFILES=()
add_profile() {
  local candidate="$1" existing
  case "$candidate" in
    '') return 0 ;;
    # '_' 로 시작하는 파일은 관점이 아니라 공통 지침(_base.md)이다.
    # 관점으로도 받으면 프롬프트에 두 번 들어간다.
    _*)
      echo "⚠️  '_' 로 시작하는 이름은 공통 지침 전용이라 관점으로 쓸 수 없습니다: '$candidate'"
      return 0
      ;;
    # 라벨은 외부 입력이므로 파일 경로로 쓰기 전에 문자셋을 제한한다
    *[!A-Za-z0-9_-]*)
      echo "⚠️  프로필 이름에 사용할 수 없는 문자가 있어 무시합니다: '$candidate'"
      return 0
      ;;
  esac
  for existing in ${PROFILES[@]+"${PROFILES[@]}"}; do
    [ "$existing" = "$candidate" ] && return 0
  done
  PROFILES+=("$candidate")
}

MATCHED_LABELS=()
for label in ${LABELS[@]+"${LABELS[@]}"}; do
  mapped="$(lookup_mapped_profile "$label")"
  if [ -n "$mapped" ]; then
    MATCHED_LABELS+=("$label")
    add_profile "$mapped"
    continue
  fi

  if [ "$label" = "$REVIEW_LABEL" ]; then
    MATCHED_LABELS+=("$label")
    add_profile "$DEFAULT_PROFILE"
    continue
  fi

  prefix="${REVIEW_LABEL}${PROFILE_SEPARATOR}"
  case "$label" in
    "$prefix"?*)
      MATCHED_LABELS+=("$label")
      add_profile "${label#"$prefix"}"
      ;;
  esac
done

if [ ${#MATCHED_LABELS[@]} -eq 0 ]; then
  # 'false' 로 명시했을 때만 라벨 요구를 해제한다.
  # 오타('True', 'ture' 등)는 "모든 PR을 리뷰"가 아니라 "건너뜀" 쪽으로 실패해야 한다.
  if [ "$REQUIRE_LABEL" != "false" ]; then
    if [ "$REQUIRE_LABEL" != "true" ]; then
      echo "⚠️  require_label 값이 'true'/'false' 가 아닙니다: '${REQUIRE_LABEL}' — 안전하게 라벨 필수로 처리합니다."
    fi
    skip_review "'${REVIEW_LABEL}' 라벨이 없습니다."
  fi
  echo "ℹ️  일치하는 라벨은 없지만 require_label=false 이므로 기본 프로필로 진행합니다."
  add_profile "$DEFAULT_PROFILE"
fi

MATCHED_CSV="$(join_csv ${MATCHED_LABELS[@]+"${MATCHED_LABELS[@]}"})"
[ -n "$MATCHED_CSV" ] || MATCHED_CSV="none"

# ---------------------------------------------------------------- 'all' 키워드 확장
# 커스텀 디렉토리와 내장 디렉토리를 합치므로, 사용자가 추가한 프로필도 'all' 에 포함된다.
# '_' 로 시작하는 파일(_base.md)은 관점이 아니라 공통 지침이므로 제외한다.
list_available_profiles() {
  local dir f name
  for dir in "$PROMPTS_DIR" "$BUILTIN_PROMPTS_DIR"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -e "$f" ] || continue
      name="${f##*/}"
      name="${name%.md}"
      case "$name" in _*) continue ;; esac
      printf '%s\n' "$name"
    done
  done | sort -u
}

is_excluded_from_all() {
  case "$ALL_EXCLUDES_SET" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

expand_all=false
for profile in ${PROFILES[@]+"${PROFILES[@]}"}; do
  [ "$profile" = "$ALL_KEYWORD" ] && expand_all=true
done

if [ "$expand_all" = "true" ]; then
  # 'all' 만 걷어낸 나머지는 이미 검증·중복제거를 거쳤으므로 그대로 되돌린다.
  # 명시한 프로필을 앞에 두어 제외 목록보다 우선하게 한다.
  EXPLICIT=()
  for profile in ${PROFILES[@]+"${PROFILES[@]}"}; do
    [ "$profile" = "$ALL_KEYWORD" ] || EXPLICIT+=("$profile")
  done
  PROFILES=(${EXPLICIT[@]+"${EXPLICIT[@]}"})

  # 전반 리뷰를 맨 앞에 두어 요약이 먼저 잡히도록 한다
  is_excluded_from_all "$DEFAULT_PROFILE" || add_profile "$DEFAULT_PROFILE"

  while IFS= read -r candidate; do
    [ "$candidate" = "$ALL_KEYWORD" ] && continue
    if is_excluded_from_all "$candidate"; then
      echo "↩️  '$ALL_KEYWORD' 확장에서 제외: $candidate"
      continue
    fi
    add_profile "$candidate"
  done < <(list_available_profiles)

  echo "🌐 '$ALL_KEYWORD' 확장 -> ${PROFILES[*]:-(없음)}"
fi

if [ ${#PROFILES[@]} -eq 0 ]; then
  skip_review "라벨은 있으나 유효한 리뷰 프로필을 찾지 못했습니다."
fi

# ---------------------------------------------------------------- 프롬프트 조립
# 커스텀 디렉토리 우선, 없으면 내장 프롬프트
find_prompt_file() {
  local profile="$1" dir
  for dir in "$PROMPTS_DIR" "$BUILTIN_PROMPTS_DIR"; do
    [ -n "$dir" ] || continue
    if [ -f "${dir%/}/${profile}.md" ]; then
      printf '%s' "${dir%/}/${profile}.md"
      return 0
    fi
  done
  return 1
}

APPLIED_PROFILES=()
SECTIONS=""
append_profile_section() {
  local profile="$1" file
  file="$(find_prompt_file "$profile")" || return 1
  echo "✅ 프로필 '$profile' -> $file"
  APPLIED_PROFILES+=("$profile")
  SECTIONS+=$'\n'"$(cat "$file")"$'\n'
}

if [ -n "$PROMPT_OVERRIDE" ]; then
  echo "📝 prompt 입력이 지정되어 라벨 기반 프롬프트 조립을 건너뜁니다."
  PROMPT="$PROMPT_OVERRIDE"
  PROFILES_CSV="$(join_csv "${PROFILES[@]}")"
  SUMMARY_DETAIL="- 프롬프트: 사용자 지정(\`prompt\` 입력)"
else
  for profile in "${PROFILES[@]}"; do
    append_profile_section "$profile" ||
      echo "⚠️  프로필 '$profile' 에 해당하는 프롬프트 파일이 없어 건너뜁니다."
  done

  if [ ${#APPLIED_PROFILES[@]} -eq 0 ]; then
    echo "ℹ️  적용 가능한 프로필이 없어 기본 프로필('${DEFAULT_PROFILE}')로 대체합니다."
    append_profile_section "$DEFAULT_PROFILE" ||
      skip_review "기본 프로필 '${DEFAULT_PROFILE}' 의 프롬프트 파일도 찾을 수 없습니다."
  fi

  PROFILES_CSV="$(join_csv "${APPLIED_PROFILES[@]}")"
  PROMPT="REPO: ${REPO:-}
PR NUMBER: ${PR_NUMBER:-}
PR TITLE: ${PR_TITLE:-}
BRANCH: ${HEAD_REF:-} -> ${BASE_REF:-}
적용된 라벨: ${MATCHED_CSV}
리뷰 관점: ${PROFILES_CSV}
"
  if base_file="$(find_prompt_file "_base")"; then
    PROMPT+=$'\n'"$(cat "$base_file")"$'\n'
  fi
  PROMPT+="$SECTIONS"
  if [ -n "$EXTRA_INSTRUCTIONS" ]; then
    PROMPT+=$'\n## 추가 지침\n\n'"$EXTRA_INSTRUCTIONS"$'\n'
  fi
  SUMMARY_DETAIL="- 리뷰 관점: \`${PROFILES_CSV}\`"
fi

emit "should_review" "true"
emit "profiles" "$PROFILES_CSV"
emit "prompt" "$PROMPT"
summary "- 적용 라벨: \`${MATCHED_CSV}\`" "$SUMMARY_DETAIL"

echo "🚀 리뷰 실행 — 관점: ${PROFILES_CSV}"
