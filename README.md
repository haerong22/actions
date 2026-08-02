# Github Actions

재사용 가능한 GitHub Actions 모음.

## 목록

| 이름 | 종류 | 설명 |
|---|---|---|
| [code-reviewer](./code-reviewer) | Composite Action | PR 라벨에 따라 리뷰 관점을 골라 Claude Code로 자동 리뷰 |
| [slack-notify](./slack-notify) | Composite Action | 워크플로우 결과를 일관된 형식으로 Slack에 전송 |
| [pr-size-label](./pr-size-label) | Composite Action | PR 변경 규모를 재서 size 라벨 자동 부착 |

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

태그는 리포지토리 전체에 공유됩니다. `@v1` 은 최신 v1.x 를 가리키는 **이동 태그**이고,
`@v1.2.0` 처럼 버전을 직접 지정하면 고정됩니다.

### 릴리즈하는 법

버전 태그만 푸시하면 됩니다. `v1` 이동은 [release 워크플로우](./.github/workflows/release.yml)가 처리합니다.

```bash
git tag v1.2.0 && git push origin v1.2.0
```

```
v1.2.0 푸시
  → action.yml 파싱·스크립트 문법·실행 권한 검사
  → v1 을 v1.2.0 커밋으로 이동
  → GitHub Release 생성 (노트 자동 생성)
```

- 검사에 실패하면 `v1` 을 옮기지 않습니다. 깨진 액션이 전 소비 레포에 동시에 나가는 것을 막습니다.
- 이미 더 높은 버전이 있으면 `v1` 을 되돌리지 않습니다.
- `v1.3.0-beta.1` 같은 프리릴리즈는 `v1` 을 옮기지 않고 prerelease 로만 등록합니다.

> 이 워크플로우는 태그 푸시에 `contents: write` 가 필요합니다.
> Settings → Actions → General → Workflow permissions 가 읽기 전용이면 동작하지 않습니다.

액션이 늘어나 액션별 독립 버전이 필요해지면 `code-reviewer/v1` 같은 접두사 태그로 전환할 예정입니다.
