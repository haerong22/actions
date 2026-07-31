#!/usr/bin/env bash
#
# 워크플로우 결과를 Slack chat.postMessage 로 보낸다.
#
# 설계 노트
#   - 페이로드는 전부 jq 로 만든다. 문자열 조립을 하면 커밋 메시지의 따옴표 하나로 깨진다.
#   - Slack mrkdwn 이스케이프(& < >)는 JSON 이스케이프와 별개 계층이라 따로 처리한다.
#     단, `<url|text>` 링크 문법과 plain_text 버튼 라벨은 이스케이프하면 안 된다.
#   - Slack 은 실패해도 HTTP 200 을 주므로 응답의 .ok 를 확인한다.
#   - 알림 실패가 워크플로우를 실패시키지 않는다 (fail-on-error 로 변경 가능).
#
set -euo pipefail

STATUS="${STATUS:-success}"
TITLE="${TITLE:-}"
MESSAGE="${MESSAGE:-}"
FIELDS="${FIELDS:-}"
LINKS="${LINKS:-}"
MENTION="${MENTION:-}"
MENTION_ON="${MENTION_ON:-failure}"
NOTIFY_ON="${NOTIFY_ON:-all}"
EMOJI_OVERRIDE="${EMOJI_OVERRIDE:-}"
COLOR_OVERRIDE="${COLOR_OVERRIDE:-}"
PAYLOAD_OVERRIDE="${PAYLOAD_OVERRIDE:-}"
SERVER_URL="${SERVER_URL:-https://github.com}"

MAX_MESSAGE=2500 # Slack section text 는 3000자 제한
MAX_SUBJECT=200
US=$'\x1f' # 라벨/값 구분자 (실제 값에 나타나지 않는 제어문자)

# ---------------------------------------------------------------- 헬퍼
emit() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }

# 불리언 입력 해석.
# 'True' 같은 대소문자 차이로 dry-run 이 꺼져 실제 전송되는 사고를 막는다.
# 해석 불가한 값은 조용히 넘기지 않고 경고한다.
parse_bool() { # $1=값 $2=입력이름 $3=기본값
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | yes | 1 | on) printf 'true' ;;
    false | no | 0 | off) printf 'false' ;;
    '') printf '%s' "$3" ;;
    *)
      # 명령 치환으로 호출되므로 경고는 stderr 로 보낸다. stdout 에 쓰면 값이 오염된다
      echo "⚠️  $2 값을 해석할 수 없습니다: '$1' — 기본값 '$3' 을 사용합니다" >&2
      printf '%s' "$3"
      ;;
  esac
}

# Slack mrkdwn 이스케이프. & 를 먼저 바꿔야 이중 변환이 안 생긴다
esc() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

# 쉼표/공백 구분 목록에 값이 있는지. 'all' 이 들어있으면 항상 참
in_list() {
  local norm=" $(printf '%s' "$1" | tr ',\n\t' '   ') "
  case "$norm" in *" all "*) return 0 ;; esac
  case "$norm" in *" $2 "*) return 0 ;; esac
  return 1
}

finish_skipped() {
  echo "⏭️  알림 건너뜀: $1"
  emit sent false
  emit ts ""
  exit 0
}

finish_error() {
  emit sent false
  emit ts ""
  if [ "$FAIL_ON_ERROR" = "true" ]; then
    echo "::error::Slack 전송 실패 — $1"
    exit 1
  fi
  echo "::warning::Slack 전송 실패 — $1 (fail-on-error=false 이므로 워크플로우는 계속)"
  exit 0
}

INCLUDE_COMMIT="$(parse_bool "${INCLUDE_COMMIT:-}" include-commit true)"
FAIL_ON_ERROR="$(parse_bool "${FAIL_ON_ERROR:-}" fail-on-error false)"
DRY_RUN="$(parse_bool "${DRY_RUN:-}" dry-run false)"

# ---------------------------------------------------------------- 필수 입력 검증
# composite action 의 `required: true` 는 GitHub 이 강제하지 않는다.
# 비어 있으면 Slack 의 not_authed/channel_not_found 로 돌아오는데 원인을 알기 어렵다.
for _required in SLACK_BOT_TOKEN CHANNEL_ID; do
  eval "_value=\${${_required}:-}"
  if [ -z "$_value" ]; then
    finish_error "필수 입력이 비어 있습니다: $(printf '%s' "$_required" | tr '[:upper:]_' '[:lower:]-')"
  fi
done

# ---------------------------------------------------------------- 전송 여부
if ! in_list "$NOTIFY_ON" "$STATUS"; then
  finish_skipped "status=$STATUS, notify-on=$NOTIFY_ON"
fi

# ---------------------------------------------------------------- status 별 기본값
case "$STATUS" in
  success)
    D_EMOJI="✅" D_COLOR="#2EA043" D_TITLE="Success"
    ;;
  failure)
    D_EMOJI="🔴" D_COLOR="#D73A4A" D_TITLE="Failure"
    ;;
  cancelled)
    D_EMOJI="⚪" D_COLOR="#6E7781" D_TITLE="Cancelled"
    ;;
  skipped)
    D_EMOJI="⏭️" D_COLOR="#6E7781" D_TITLE="Skipped"
    ;;
  *)
    D_EMOJI="🔔" D_COLOR="#4C6EF5" D_TITLE="$STATUS"
    ;;
esac
EMOJI="${EMOJI_OVERRIDE:-$D_EMOJI}"
COLOR="${COLOR_OVERRIDE:-$D_COLOR}"
TITLE="${TITLE:-$D_TITLE}"

# ---------------------------------------------------------------- 커밋 제목 해석
# head_commit 은 push 이벤트에만 있다. 수동 실행(workflow_dispatch)에서 비지 않도록 폴백한다
resolve_commit_subject() {
  if [ -n "${HEAD_COMMIT_MSG:-}" ]; then
    printf '%s' "${HEAD_COMMIT_MSG%%$'\n'*}"
    return 0
  fi
  if [ -n "${PR_TITLE:-}" ]; then
    printf '%s' "$PR_TITLE"
    return 0
  fi
  if [ -n "${SHA:-}" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    git log -1 --pretty=%s "$SHA" 2>/dev/null || true
  fi
}

COMMIT_VALUE=""
if [ "$INCLUDE_COMMIT" = "true" ] && [ -n "${SHA:-}" ]; then
  SUBJECT="$(resolve_commit_subject)"
  if [ ${#SUBJECT} -gt $MAX_SUBJECT ]; then
    echo "ℹ️  커밋 제목이 길어 ${MAX_SUBJECT}자로 잘랐습니다"
    SUBJECT="${SUBJECT:0:$MAX_SUBJECT}…"
  fi
  COMMIT_VALUE="<${SERVER_URL}/${REPO}/commit/${SHA}|${SHA:0:7}>"
  [ -n "$SUBJECT" ] && COMMIT_VALUE="$COMMIT_VALUE $(esc "$SUBJECT")"
fi

# ---------------------------------------------------------------- 컨텍스트 필드
# 값에 <url|text> 링크 문법이 들어가므로 여기서 만든 문자열은 jq 에서 재이스케이프하지 않는다
if [ -n "${PR_NUMBER:-}" ] && [ -n "${PR_URL:-}" ]; then
  REF_LABEL="PR"
  REF_VALUE="<${PR_URL}|#${PR_NUMBER}> $(esc "${HEAD_REF:-}") → $(esc "${BASE_REF:-}")"
else
  REF_LABEL="Ref"
  REF_VALUE="<${SERVER_URL}/${REPO}/tree/${REF_NAME:-}|$(esc "${REF_NAME:-}")>"
fi

CTX_JSON=$(
  {
    printf 'Repo%s<%s/%s|%s>\n' "$US" "$SERVER_URL" "$REPO" "$(esc "$REPO")"
    printf '%s%s%s\n' "$REF_LABEL" "$US" "$REF_VALUE"
    printf 'Actor%s%s\n' "$US" "$(esc "${ACTOR:-}")"
    # '&&' 로 쓰면 COMMIT_VALUE 가 빈 경우 그룹이 1 을 반환해 set -e 로 스크립트가 죽는다
    if [ -n "$COMMIT_VALUE" ]; then
      printf 'Commit%s%s\n' "$US" "$COMMIT_VALUE"
    fi
  } | jq -R -s --arg us "$US" '
      split("\n") | map(select(length > 0))
      | map(split($us))
      | map({ type: "mrkdwn", text: ("*" + .[0] + "*\n" + (.[1] // "-")) })
    '
)

# ---------------------------------------------------------------- 사용자 필드
# `키=값` 줄 파싱과 mrkdwn 이스케이프를 모두 jq 안에서 처리한다
# 주의: jq 1.6 의 index() 는 바이트 오프셋을 주는데 문자열 슬라이싱은 코드포인트 기준이라
# 한글 키에서 어긋난다. 그래서 index/슬라이싱 대신 split 으로 첫 '=' 를 나눈다.
USER_FIELDS_JSON=$(printf '%s' "$FIELDS" | jq -R -s '
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  split("\n")
  | map(sub("^\\s+"; "") | sub("\\s+$"; ""))
  | map(select(length > 0 and (startswith("#") | not) and (contains("="))))
  | map(split("=") | { k: (.[0] | sub("\\s+$"; "")), v: (.[1:] | join("=") | sub("^\\s+"; "")) })
  | map(select(.k != ""))
  | map({ type: "mrkdwn", text: ("*" + (.k | esc) + "*\n" + (if .v == "" then "-" else (.v | esc) end)) })
')

# ---------------------------------------------------------------- 링크 버튼
# 사용자가 지정하면 기본 링크를 대체한다
if [ -n "$LINKS" ]; then
  LINKS_EFFECTIVE="$LINKS"
elif [ "$STATUS" = "success" ] && [ -n "${SHA:-}" ]; then
  LINKS_EFFECTIVE="See changes=${SERVER_URL}/${REPO}/commit/${SHA}"
else
  LINKS_EFFECTIVE="View logs=${SERVER_URL}/${REPO}/actions/runs/${RUN_ID:-}"
fi

# 버튼 라벨은 plain_text 라 mrkdwn 이스케이프를 하면 &amp; 가 그대로 보인다
LINKS_JSON=$(printf '%s' "$LINKS_EFFECTIVE" | jq -R -s '
  split("\n")
  | map(sub("^\\s+"; "") | sub("\\s+$"; ""))
  | map(select(length > 0 and (startswith("#") | not) and (contains("="))))
  | map(split("=") | { t: (.[0] | sub("\\s+$"; "")), u: (.[1:] | join("=") | sub("^\\s+"; "")) })
  | map(select(.t != "" and .u != ""))
  | map({ type: "button", text: { type: "plain_text", text: .t, emoji: true }, url: .u })
')

# ---------------------------------------------------------------- 멘션
MENTION_TEXT=""
if [ -n "$MENTION" ] && in_list "$MENTION_ON" "$STATUS"; then
  case "$MENTION" in
    here) MENTION_TEXT="<!here>" ;;
    channel) MENTION_TEXT="<!channel>" ;;
    *) MENTION_TEXT="$MENTION" ;; # <@U123>, <!subteam^S123> 등은 그대로
  esac
fi

# ---------------------------------------------------------------- 본문 조립
if [ ${#MESSAGE} -gt $MAX_MESSAGE ]; then
  echo "ℹ️  message 가 길어 ${MAX_MESSAGE}자로 잘랐습니다"
  MESSAGE="${MESSAGE:0:$MAX_MESSAGE}…"
fi

BODY="$MENTION_TEXT"
if [ -n "$MESSAGE" ]; then
  [ -n "$BODY" ] && BODY="$BODY "
  BODY="$BODY$(esc "$MESSAGE")"
fi

HEADLINE="*${EMOJI} $(esc "$TITLE")*"
FALLBACK="${EMOJI} $(esc "$TITLE") — $(esc "$REPO")"
CONTEXT_LINE="$(esc "${WORKFLOW:-}") #${RUN_NUMBER:-}"

# ---------------------------------------------------------------- 페이로드
if [ -n "$PAYLOAD_OVERRIDE" ]; then
  echo "📝 payload 입력이 지정되어 템플릿 조립을 건너뜁니다."
  # 일부 jq 빌드(Apple jq-1.6)는 파싱 실패에도 종료코드 0 을 준다.
  # 종료코드를 믿지 말고 출력이 비었는지로 판정한다.
  PAYLOAD=$(printf '%s' "$PAYLOAD_OVERRIDE" |
    jq --arg ch "$CHANNEL_ID" '. + { channel: (.channel // $ch) }' 2>/dev/null || true)
  if [ -z "$PAYLOAD" ]; then
    finish_error "payload 가 유효한 JSON 이 아닙니다"
  fi
else
  PAYLOAD=$(jq -n \
    --arg channel "$CHANNEL_ID" \
    --arg fallback "$FALLBACK" \
    --arg color "$COLOR" \
    --arg headline "$HEADLINE" \
    --arg body "$BODY" \
    --arg context "$CONTEXT_LINE" \
    --argjson ctx "$CTX_JSON" \
    --argjson uf "$USER_FIELDS_JSON" \
    --argjson links "$LINKS_JSON" \
    '
    # Slack section 의 fields 는 최대 10개다. 잘라내지 않고 섹션을 나눈다
    def chunk(n): . as $a | [range(0; ($a | length); n)] | map($a[.:(. + n)]);
    {
      channel: $channel,
      text: $fallback,
      attachments: [{
        color: $color,
        blocks: (
          [{ type: "section", text: { type: "mrkdwn",
             text: ($headline + (if $body == "" then "" else "\n" + $body end)) } }]
          + (($ctx + $uf) | chunk(10) | map({ type: "section", fields: . }))
          + (if ($links | length) == 0 then [] else [{ type: "actions", elements: $links }] end)
          + [{ type: "context", elements: [{ type: "mrkdwn", text: $context }] }]
        )
      }]
    }
    ')
fi

# 위와 같은 이유로 조립 결과가 비었는지도 확인한다
if [ -z "$PAYLOAD" ]; then
  finish_error "페이로드 조립에 실패했습니다"
fi

# ---------------------------------------------------------------- 전송
if [ "$DRY_RUN" = "true" ]; then
  echo "🧪 dry-run — 전송하지 않고 페이로드만 출력합니다."
  printf '%s\n' "$PAYLOAD" | jq .
  emit sent false
  emit ts ""
  exit 0
fi

echo "📨 Slack 전송 중... (channel=${CHANNEL_ID}, status=${STATUS})"
HTTP_CODE=0
RESPONSE=""
if ! RESPONSE=$(printf '%s' "$PAYLOAD" | curl -sS -X POST \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -w $'\n%{http_code}' \
  --data-binary @- \
  https://slack.com/api/chat.postMessage 2>&1); then
  finish_error "curl 실패: ${RESPONSE:0:300}"
fi

HTTP_CODE="${RESPONSE##*$'\n'}"
BODY_JSON="${RESPONSE%$'\n'*}"

# Slack 은 페이로드가 잘못돼도 200 을 주는 경우가 있어 .ok 까지 확인한다
if [ "$(printf '%s' "$BODY_JSON" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
  ERR="$(printf '%s' "$BODY_JSON" | jq -r '.error // "unknown"' 2>/dev/null || true)"
  # 응답이 JSON 이 아니면 jq 가 아무것도 출력하지 않는다 (종료코드는 0 일 수 있음)
  [ -n "$ERR" ] || ERR="invalid_response (응답이 JSON 이 아님)"
  finish_error "HTTP ${HTTP_CODE}, error=${ERR}"
fi

TS="$(printf '%s' "$BODY_JSON" | jq -r '.ts // ""')"
emit sent true
emit ts "$TS"
echo "✅ 전송 완료 (ts=${TS})"
