#!/usr/bin/env bash
#
# 이전 실행이 남긴 인라인 리뷰 코멘트를 정리한다.
#
# PR 요약 코멘트는 claude-code-action 의 use_sticky_comment 가 덮어쓰므로 여기서 건드리지 않는다.
# (삭제 후 재작성보다 덮어쓰기가 API 호출이 적고 rate limit 위험도 없다)
#
# 인라인 스레드는 아래 두 조건을 모두 만족할 때만 삭제한다.
#   - 미해결(unresolved) 스레드
#   - 스레드의 모든 코멘트가 bot 작성 (사용자 답글이 있으면 보존 — 코드만 덩그러니 남는 문제 방지)
#
set +e # 코멘트 정리 실패가 리뷰 자체를 막아서는 안 된다

DELETE_DELAY="${DELETE_DELAY:-0.3}"
# 기본 GITHUB_TOKEN 으로 남긴 코멘트의 GraphQL author.login ('[bot]' 접미사 없음)
BOT_LOGIN="${BOT_LOGIN:-github-actions}"

echo "🔍 이전 인라인 리뷰 검색 중..."

RESPONSE=$(gh api graphql \
  -F owner="${REPO%/*}" -F name="${REPO#*/}" -F number="$PR_NUMBER" \
  -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(last: 100) {
          nodes {
            isResolved
            comments(first: 50) {
              nodes {
                databaseId
                author {
                  login
                }
              }
            }
          }
        }
      }
    }
  }')

# 조회에 실패했는데 "정리 완료"를 찍으면 로그가 거짓말을 한다
if ! printf '%s' "$RESPONSE" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1; then
  echo "⚠️  리뷰 스레드 조회 실패 — 정리를 건너뜁니다 (리뷰는 계속 진행)"
  exit 0
fi

printf '%s' "$RESPONSE" \
  | jq -r --arg bot "$BOT_LOGIN" '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | select([.comments.nodes[].author.login] | all(. == $bot))
      | .comments.nodes[].databaseId' \
  | while read -r comment_id; do
      echo "🗑️  인라인 코멘트 삭제: $comment_id"
      gh api -X DELETE "repos/$REPO/pulls/comments/$comment_id" 2>/dev/null || echo "⚠️  삭제 실패 (무시)"
      sleep "$DELETE_DELAY"
    done

echo "✅ 인라인 리뷰 정리 완료"
