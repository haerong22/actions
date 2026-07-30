# Github Actions

재사용 가능한 GitHub Actions 모음.

## 목록

| 이름 | 종류 | 설명 |
|---|---|---|
| [code-reviewer](./code-reviewer) | Composite Action | PR 라벨에 따라 리뷰 관점을 골라 Claude Code로 자동 리뷰 |

## 빠른 시작

소비 레포에 아래 워크플로우를 추가하고 `CLAUDE_CODE_OAUTH_TOKEN` 시크릿을 등록합니다.

```yaml
# .github/workflows/code-review.yml
name: "Claude Code Review"
on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize, labeled]

jobs:
  review:
    runs-on: ubuntu-latest
    concurrency:
      group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: haerong22/actions/code-reviewer@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

PR에 `claude-review` 라벨을 붙이면 리뷰가 실행됩니다.
`claude-review:security` / `:performance` / `:test` / `:architecture` / `:quick` / `:all` 로
리뷰 관점을 바꿀 수 있습니다. 자세한 내용은 [code-reviewer/README.md](./code-reviewer/README.md).

## 버전

태그는 리포지토리 전체에 공유됩니다. `@v1` 은 최신 v1.x 를 가리키는 이동 태그입니다.

액션이 늘어나 액션별 독립 버전이 필요해지면 `code-reviewer/v1` 같은 접두사 태그로 전환할 예정입니다.
