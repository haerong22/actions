#!/usr/bin/env bash
#
# PR 변경 규모를 재서 size 라벨을 붙인다.
#
# 설계 노트
#   - 락파일 같은 생성물을 빼지 않으면 3줄 고친 PR 이 XL 로 찍혀 라벨이 노이즈가 된다.
#     제외는 하되 얼마나 뺐는지 반드시 로그에 남긴다 (조용한 절삭 금지).
#   - gh api 로 파일 목록을 받으므로 actions/checkout 이 필요 없다.
#   - fork PR 은 GITHUB_TOKEN 이 읽기 전용이라 라벨 부착이 실패한다.
#     기본적으로 경고만 남기고 워크플로우를 막지 않는다.
#
set -euo pipefail

# 기본값은 action.yml 이 소유한다. 여기서 또 정의하면 두 곳이 어긋난다.
# 스크립트는 비어 있어도 동작하도록만 하고, 필수인 것은 아래에서 검증한다.
LABEL_PREFIX="${LABEL_PREFIX:-size/}"
METRIC="${METRIC:-total}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"
LABEL_COLORS="${LABEL_COLORS:-}"
FAIL_OVER="${FAIL_OVER:-}"
SIZES="${SIZES:-}"

MAX_FILES=3000 # GitHub PR files API 상한

# ---------------------------------------------------------------- 헬퍼
emit() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }

summary() { printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# 라벨 이름이 URL 경로에 들어가므로 반드시 인코딩해야 한다.
# 기본 접두사 'size/' 의 슬래시가 경로 구분자로 새면 404 가 나고,
# 이전 라벨 제거가 조용히 실패해 PR 에 size 라벨이 여러 개 쌓인다.
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

# 'True' 같은 대소문자 차이로 dry-run 이 꺼지는 사고를 막는다.
# 명령 치환으로 호출되므로 경고는 stderr 로 보낸다 (stdout 에 쓰면 값이 오염된다)
parse_bool() { # $1=값 $2=입력이름 $3=기본값
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | yes | 1 | on) printf 'true' ;;
    false | no | 0 | off) printf 'false' ;;
    '') printf '%s' "$3" ;;
    *)
      echo "⚠️  $2 값을 해석할 수 없습니다: '$1' — 기본값 '$3' 을 사용합니다" >&2
      printf '%s' "$3"
      ;;
  esac
}

CREATE_LABELS="$(parse_bool "${CREATE_LABELS:-}" create-labels true)"
FAIL_ON_ERROR="$(parse_bool "${FAIL_ON_ERROR:-}" fail-on-error false)"
DRY_RUN="$(parse_bool "${DRY_RUN:-}" dry-run false)"

finish_error() {
  if [ "$FAIL_ON_ERROR" = "true" ]; then
    echo "::error::$1"
    exit 1
  fi
  echo "::warning::$1 (fail-on-error=false 이므로 워크플로우는 계속)"
  exit 0
}

# composite action 의 `required: true` 는 GitHub 이 강제하지 않는다
for _req in GH_TOKEN REPO PR_NUMBER; do
  eval "_val=\${${_req}:-}"
  if [ -z "$_val" ]; then
    finish_error "필수 값이 비어 있습니다: $_req (PR 이벤트에서 실행했는지 확인하세요)"
  fi
done

# ---------------------------------------------------------------- 제외 판정
# bash case 의 '*' 는 '/' 도 넘어서 매칭한다. 제외 패턴 용도로는 그 편이 편하다.
# '**/x' 는 최상위의 'x' 도 잡아야 하므로 접두사를 뗀 형태로도 시도한다.
EXCLUDE_LIST=()
while IFS= read -r _line; do
  _line="$(trim "$_line")"
  case "$_line" in '' | \#*) continue ;; esac
  EXCLUDE_LIST+=("$_line")
done <<<"$EXCLUDE_PATHS"

is_excluded() {
  local path="$1" pat
  for pat in ${EXCLUDE_LIST[@]+"${EXCLUDE_LIST[@]}"}; do
    case "$path" in $pat) return 0 ;; esac
    case "$pat" in
      '**/'*)
        case "$path" in ${pat#'**/'}) return 0 ;; esac
        ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------- 파일 목록
echo "🔍 PR #${PR_NUMBER} 변경 파일 조회 중..."
FILES_TSV="$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/files" \
  --jq '.[] | [.filename, .additions, .deletions] | @tsv' 2>&1)" || {
  finish_error "PR 파일 목록을 가져오지 못했습니다: $(printf '%s' "$FILES_TSV" | head -1)"
}

ADD=0 DEL=0 NFILES=0
EXC_FILES=0 EXC_LINES=0
EXC_SAMPLE=""
while IFS=$'\t' read -r fname fadd fdel; do
  [ -n "$fname" ] || continue
  fadd="${fadd:-0}"
  fdel="${fdel:-0}"
  if is_excluded "$fname"; then
    EXC_FILES=$((EXC_FILES + 1))
    EXC_LINES=$((EXC_LINES + fadd + fdel))
    [ -n "$EXC_SAMPLE" ] || EXC_SAMPLE="$fname"
    continue
  fi
  ADD=$((ADD + fadd))
  DEL=$((DEL + fdel))
  NFILES=$((NFILES + 1))
done <<<"$FILES_TSV"

TOTAL_SEEN=$((NFILES + EXC_FILES))
if [ "$TOTAL_SEEN" -ge "$MAX_FILES" ]; then
  echo "::warning::변경 파일이 ${MAX_FILES}개 상한에 도달했습니다. 크기가 실제보다 작게 계산될 수 있습니다"
fi

# ---------------------------------------------------------------- 크기 계산
case "$METRIC" in
  total) VALUE=$((ADD + DEL)) ;;
  additions) VALUE=$ADD ;;
  files) VALUE=$NFILES ;;
  *)
    echo "⚠️  metric 값을 해석할 수 없습니다: '$METRIC' — total 을 사용합니다"
    METRIC=total
    VALUE=$((ADD + DEL))
    ;;
esac

echo "📏 변경 ${VALUE} (metric=${METRIC}) — +${ADD} -${DEL}, 파일 ${NFILES}개"
if [ "$EXC_FILES" -gt 0 ]; then
  _etc=""
  [ "$EXC_FILES" -gt 1 ] && _etc=" 외 $((EXC_FILES - 1))개"
  echo "   제외: ${EXC_SAMPLE}${_etc}, ${EXC_LINES}줄"
fi

# ---------------------------------------------------------------- 구간 판정
NAMES=()
MAXES=()
while IFS= read -r _line; do
  _line="$(trim "$_line")"
  case "$_line" in '' | \#*) continue ;; esac
  if [ "$_line" = "${_line%=*}" ]; then
    NAMES+=("$_line")
    MAXES+=("") # '=' 없으면 상한 없음
  else
    _name="$(trim "${_line%%=*}")"
    _max="$(trim "${_line#*=}")"
    if [ -z "$_name" ]; then
      finish_error "sizes 의 구간 이름이 비어 있습니다: '${_line}'"
    fi
    # 숫자가 아니면 비교가 조용히 실패해 모든 PR 이 첫 구간으로 찍힌다
    case "$_max" in
      '' | *[!0-9]*)
        finish_error "sizes 의 상한이 숫자가 아닙니다: '${_line}'"
        ;;
    esac
    NAMES+=("$_name")
    MAXES+=("$_max")
  fi
done <<<"$SIZES"

if [ ${#NAMES[@]} -eq 0 ]; then
  finish_error "sizes 입력에서 유효한 구간을 찾지 못했습니다"
fi

BUCKET=""
BUCKET_IDX=-1
_i=0
while [ $_i -lt ${#NAMES[@]} ]; do
  _max="${MAXES[$_i]}"
  if [ -z "$_max" ] || [ "$VALUE" -le "$_max" ]; then
    BUCKET="${NAMES[$_i]}"
    BUCKET_IDX=$_i
    break
  fi
  _i=$((_i + 1))
done
if [ -z "$BUCKET" ]; then # 마지막 구간에도 상한이 있었던 경우
  BUCKET_IDX=$((${#NAMES[@]} - 1))
  BUCKET="${NAMES[$BUCKET_IDX]}"
fi

LABEL="${LABEL_PREFIX}${BUCKET}"
echo "🏷️  → ${LABEL}"

emit size "$LABEL"
emit bucket "$BUCKET"
emit total "$((ADD + DEL))"
emit additions "$ADD"
emit deletions "$DEL"
emit files "$NFILES"
emit excluded-files "$EXC_FILES"
emit excluded-lines "$EXC_LINES"

summary "### 📏 PR Size" "" \
  "- 라벨: \`${LABEL}\`" \
  "- 변경: +${ADD} -${DEL}, 파일 ${NFILES}개 (metric=${METRIC})" \
  "- 제외: 파일 ${EXC_FILES}개, ${EXC_LINES}줄"

# ---------------------------------------------------------------- 라벨 색상
default_color() {
  case "$1" in
    XS) printf '0E8A16' ;;
    S) printf '7CB342' ;;
    M) printf 'FBCA04' ;;
    L) printf 'EF6C00' ;;
    XL | XXL) printf 'D73A4A' ;;
    *) printf 'BFD4F2' ;;
  esac
}

color_for() {
  local target="$1" line key
  while IFS= read -r line; do
    line="$(trim "$line")"
    case "$line" in '' | \#*) continue ;; esac
    [ "$line" = "${line%=*}" ] && continue
    key="$(trim "${line%%=*}")"
    if [ "$key" = "$target" ]; then
      trim "${line#*=}"
      return 0
    fi
  done <<<"$LABEL_COLORS"
  default_color "$target"
}

# ---------------------------------------------------------------- 라벨 반영
if [ "$DRY_RUN" = "true" ]; then
  echo "🧪 dry-run — 라벨을 붙이지 않습니다. 적용될 라벨: ${LABEL}"
else
  if [ "$CREATE_LABELS" = "true" ]; then
    if ! gh api "repos/${REPO}/labels/$(urlenc "$LABEL")" >/dev/null 2>&1; then
      COLOR="$(color_for "$BUCKET")"
      echo "🎨 라벨 생성: ${LABEL} (#${COLOR})"
      gh api -X POST "repos/${REPO}/labels" \
        -f "name=${LABEL}" -f "color=${COLOR}" \
        -f "description=변경 규모 ${BUCKET}" >/dev/null 2>&1 ||
        echo "⚠️  라벨 생성 실패 (이미 있거나 권한 부족) — 계속 진행합니다"
    fi
  fi

  # 이전 size 라벨 정리.
  # 접두사 glob 으로 지우면 label-prefix 가 짧을 때(예: 's') 무관한 라벨까지 지운다.
  # 이 액션이 만들 수 있는 라벨(접두사 + 설정된 구간 이름)과 정확히 일치할 때만 지운다.
  is_managed_label() {
    local i=0
    while [ $i -lt ${#NAMES[@]} ]; do
      if [ "$1" = "${LABEL_PREFIX}${NAMES[$i]}" ]; then
        return 0
      fi
      i=$((i + 1))
    done
    return 1
  }

  CURRENT="$(gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" --jq '.[].name' 2>/dev/null || true)"
  ALREADY=false
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! is_managed_label "$name"; then
      continue
    fi
    if [ "$name" = "$LABEL" ]; then
      ALREADY=true
    else
      echo "🗑️  이전 라벨 제거: $name"
      gh api -X DELETE "repos/${REPO}/issues/${PR_NUMBER}/labels/$(urlenc "$name")" >/dev/null 2>&1 ||
        echo "⚠️  제거 실패 (무시): $name"
    fi
  done <<<"$CURRENT"

  if [ "$ALREADY" = "true" ]; then
    echo "✅ 이미 ${LABEL} 이 붙어 있습니다"
  else
    if ! gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/labels" \
      -f "labels[]=${LABEL}" >/dev/null 2>&1; then
      finish_error "라벨 부착 실패: ${LABEL} (fork PR 은 토큰이 읽기 전용이라 실패합니다)"
    fi
    echo "✅ 라벨 부착 완료: ${LABEL}"
  fi
fi

# ---------------------------------------------------------------- 상한 검사
if [ -n "$FAIL_OVER" ]; then
  FAIL_IDX=-1
  _i=0
  while [ $_i -lt ${#NAMES[@]} ]; do
    if [ "${NAMES[$_i]}" = "$FAIL_OVER" ]; then
      FAIL_IDX=$_i
      break
    fi
    _i=$((_i + 1))
  done
  if [ "$FAIL_IDX" -lt 0 ]; then
    echo "⚠️  fail-over 값 '${FAIL_OVER}' 이 sizes 구간에 없습니다 — 검사를 건너뜁니다"
  elif [ "$BUCKET_IDX" -ge "$FAIL_IDX" ]; then
    echo "::error::PR 규모가 ${FAIL_OVER} 이상입니다 (${BUCKET}, ${VALUE}). 나눠서 올려주세요"
    exit 1
  fi
fi
