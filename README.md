# Github Actions

재사용 가능한 GitHub Actions 모음.

## 목록

| 이름 | 종류 | 설명 |
|---|---|---|
| [code-reviewer](./code-reviewer) | Composite Action | PR 라벨에 따라 리뷰 관점을 골라 Claude Code로 자동 리뷰 |
| [code-review.yml](./.github/workflows/code-review.yml) | Reusable Workflow | 위 액션을 job 단위로 감싼 것. 소비 레포는 8줄이면 끝 |

## 빠른 시작

```yaml
name: "Claude Code Review"
on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize, labeled]

jobs:
  review:
    permissions:
      contents: read
      pull-requests: write # 생략하면 레포 기본 권한이 읽기 전용일 때 코멘트 작성이 실패합니다
    uses: haerong22/actions/.github/workflows/code-review.yml@v1
    secrets: inherit
```

PR에 `claude-review` 라벨을 붙이면 리뷰가 실행됩니다.
`claude-review:security` / `:performance` / `:test` / `:architecture` / `:quick` / `:all` 로
리뷰 관점을 바꿀 수 있습니다. 자세한 내용은 [code-reviewer/README.md](./code-reviewer/README.md).

## 버전

태그는 리포지토리 전체에 공유됩니다. `@v1` 은 최신 v1.x 를 가리키는 이동 태그입니다.

액션이 늘어나 액션별 독립 버전이 필요해지면 `code-reviewer/v1` 같은 접두사 태그로 전환할 예정입니다.
