# Label-based Claude Code Reviewer

PR에 붙인 **라벨에 따라 리뷰 관점을 골라서** Claude Code로 자동 리뷰합니다.

---

## 무엇을 하나

라벨이 곧 리뷰 주문서입니다. 붙인 라벨에 맞는 관점으로만 리뷰합니다.

| 라벨 | 리뷰 관점 |
|---|---|
| `claude-review` | 정확성, 엣지 케이스, 에러 처리, 가독성, 호환성 |
| `claude-review:security` | 인젝션, 인증/인가, 시크릿 노출, 입력 검증, 암호화 |
| `claude-review:performance` | N+1, 루프 내 I/O, 메모리, 캐싱, 동시성 |
| `claude-review:test` | 커버리지, 분기 검증, 취약한 테스트 |
| `claude-review:architecture` | 책임 분리, 의존 방향, 확장성, 과설계 |
| `claude-review:quick` | 치명적 이슈만 (Critical/Major) |
| `claude-review:all` | 위 관점 전부 (quick 제외) |

- **라벨이 없으면 리뷰하지 않습니다.** 필요한 PR에만 선택적으로 받을 수 있습니다.
- 여러 라벨을 붙이면 관점이 합쳐져 **한 번만** 실행됩니다.
- 새 커밋을 푸시하면 이전 리뷰를 정리하고 다시 리뷰합니다.

---

## 사용법

### 1. 라벨 만들기

```bash
gh label create claude-review              --color 7C3AED --description "Claude 전반 코드 리뷰"
gh label create claude-review:security     --color D73A4A --description "Claude 보안 관점 리뷰"
gh label create claude-review:performance  --color FBCA04 --description "Claude 성능 관점 리뷰"
gh label create claude-review:test         --color 0E8A16 --description "Claude 테스트 관점 리뷰"
gh label create claude-review:architecture --color 1D76DB --description "Claude 설계 관점 리뷰"
gh label create claude-review:quick        --color BFDADC --description "Claude 빠른 확인"
gh label create claude-review:all          --color 5319E7 --description "Claude 전체 관점 리뷰"
```

### 2. 워크플로우 추가

레포에 `CLAUDE_CODE_OAUTH_TOKEN` 시크릿이 등록되어 있어야 합니다.

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
      cancel-in-progress: true # 새 커밋이 오면 이전 리뷰 실행 취소
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4 # 필수. 액션에 포함되어 있지 않음
      - uses: haerong22/actions/code-reviewer@v1
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

세 가지를 빠뜨리기 쉽습니다.

- `types` 에 **`labeled`** — 없으면 이미 열린 PR에 라벨을 붙여도 반응하지 않습니다.
- **`permissions`** — 레포 기본 `GITHUB_TOKEN` 권한이 읽기 전용이면 코멘트 작성이 실패합니다.
  (Settings → Actions → General → Workflow permissions)
- **`actions/checkout`** — 액션에 포함되어 있지 않아 직접 호출해야 합니다.

### 3. 리뷰 요청하기

PR에 라벨을 붙이면 끝입니다. 리뷰를 한 번만 받고 싶다면 완료 후 라벨을 떼면 됩니다.

### 커스터마이징

**프로젝트 컨텍스트 덧붙이기**

```yaml
with:
  extra_instructions: |
    Spring Boot 기반이며 컨벤션은 CONTRIBUTING.md 를 따릅니다.
```

**프롬프트 직접 작성하기** — 파일 이름이 곧 프로필 이름입니다.

```
.github/review-prompts/
├── _base.md      # 모든 리뷰에 공통 적용 (선택)
├── security.md   # 내장 프롬프트를 덮어씀
└── db.md         # claude-review:db 라벨이 새로 생김
```

```yaml
with:
  prompts_dir: .github/review-prompts
```

**기존 라벨 재사용하기**

```yaml
with:
  label_profile_map: |
    security-audit=security
    hotfix=quick
```

### 입력

| 입력 | 기본값 | 설명 |
|---|---|---|
| `github_token` | **필수** | GitHub API 토큰 |
| `claude_code_oauth_token` | **필수** | Claude Code OAuth 토큰 |
| `review_label` | `claude-review` | 리뷰를 트리거하는 기본 라벨 |
| `profile_separator` | `:` | 기본 라벨과 프로필의 구분자 |
| `default_profile` | `default` | 기본 라벨만 붙었을 때 쓸 프로필 |
| `label_profile_map` | - | 임의 라벨 → 프로필 매핑 (`라벨=프로필`) |
| `require_label` | `true` | 라벨 없는 PR을 건너뜀. 정확히 `false` 일 때만 해제 |
| `all_keyword` | `all` | 전체 관점으로 확장되는 예약어 |
| `all_excludes` | `quick` | `all` 확장에서 제외할 프로필 (쉼표 구분) |
| `prompts_dir` | - | 커스텀 프롬프트 디렉토리 |
| `extra_instructions` | - | 모든 리뷰에 덧붙일 지침 |
| `prompt` | - | 전체 프롬프트 직접 지정 (라벨 조립 무시) |
| `claude_args` | allowedTools | Claude CLI 추가 인자 |
| `show_full_output` | `true` | Claude 출력 전체 표시 |
| `use_sticky_comment` | `true` | 요약 코멘트를 새로 달지 않고 덮어씀 |
| `cleanup_inline_reviews` | `true` | 새 커밋 시 이전 인라인 스레드 삭제 |
| `delete_delay_seconds` | `0.3` | 삭제 API 호출 간 딜레이 |

### 출력

| 출력 | 설명 |
|---|---|
| `should_review` | 리뷰를 실행했는지 (`true`/`false`) |
| `profiles` | 적용된 리뷰 관점 (쉼표 구분) |

---

## 어떻게 동작하나

### 실행 흐름

```
PR 이벤트
   │
   ├─ 1. 라벨 해석   scripts/resolve-review.sh
   │      라벨 → 리뷰 관점 결정 → 프롬프트 조립
   │      매칭 없으면 여기서 종료
   │
   ├─ 2. 이전 리뷰 정리   scripts/cleanup-inline-reviews.sh
   │      synchronize 이벤트일 때만
   │
   └─ 3. 리뷰 실행   anthropics/claude-code-action@v1
```

### 1. 라벨 해석

PR의 라벨을 하나씩 아래 순서로 검사해 리뷰 관점을 모읍니다.

1. `label_profile_map` 에 등록된 라벨 → 매핑된 관점
2. `claude-review` 와 정확히 일치 → `default` 관점
3. `claude-review:` 로 시작 → 뒷부분이 관점 이름

하나도 매칭되지 않으면 리뷰 없이 종료하고, 그 이유를 Job Summary에 남깁니다.

`all` 은 파일이 아니라 확장 키워드입니다. 만나면 사용 가능한 모든 프롬프트 파일로 펼치는데,
`_base.md`(공통 지침)와 `all_excludes` 에 지정된 관점은 빠집니다. `quick` 은 "치명적 이슈만 보고"라
다른 관점과 충돌하므로 기본 제외입니다.

> 라벨은 파일 경로의 일부가 되므로 관점 이름은 `[A-Za-z0-9_-]` 로 제한합니다.
> `claude-review:../../etc/passwd` 같은 라벨은 차단됩니다.

### 2. 프롬프트 조립

이 순서로 이어붙여 하나의 프롬프트를 만듭니다.

```
PR 컨텍스트     REPO, PR 번호, 제목, 브랜치, 적용된 라벨
   +
_base.md        공통 규칙 — 한국어, 심각도 태그, 변경분만 리뷰, 출력 형식
   +
관점별 .md      security.md, performance.md, ... (매칭된 순서대로)
   +
extra_instructions
```

프롬프트 파일은 `prompts_dir` 을 먼저 찾고, 없으면 내장 `prompts/` 를 씁니다.
둘 다 없는 관점은 건너뛰고, 하나도 남지 않으면 `default` 로 대체합니다.

### 3. 이전 리뷰 정리

새 커밋(`synchronize`)이 오면 리뷰가 쌓이지 않도록 정리합니다. 두 종류를 다르게 다룹니다.

| 대상 | 처리 | 이유 |
|---|---|---|
| 요약 코멘트 | `use_sticky_comment` 로 **덮어씀** | 삭제·재작성보다 API 호출이 적고 rate limit 위험이 없음 |
| 인라인 스레드 | bot 전용 스레드만 **삭제** | sticky 대상이 아니라 계속 쌓임 |

인라인 스레드는 **미해결이면서 모든 코멘트가 bot 작성**인 것만 지웁니다.
사용자가 답글을 단 스레드는 보존합니다. 안 그러면 대화만 사라지고 코드가 덩그러니 남습니다.
