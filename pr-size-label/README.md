# PR Size Label

PR 변경 규모를 재서 `size/XS` ~ `size/XL` 라벨을 자동으로 붙입니다.

---

## 무엇을 하나

```
📏 변경 42 (metric=total) — +30 -12, 파일 5개
   제외: package-lock.json 외 1개, 4821줄
🏷️  → size/M
```

- PR이 갱신되면 이전 size 라벨을 떼고 다시 붙입니다.
- 락파일 같은 생성물은 크기 계산에서 빼되, **얼마나 뺐는지 로그에 남깁니다.**
- 라벨이 레포에 없으면 색상과 함께 만들어 줍니다.
- `actions/checkout`이 필요 없습니다. GitHub API로 파일 목록만 조회합니다.

| 구간 | 변경 줄 수 | 색상 |
|---|---|---|
| `size/XS` | 0 – 9 | 초록 |
| `size/S` | 10 – 29 | 연두 |
| `size/M` | 30 – 99 | 노랑 |
| `size/L` | 100 – 499 | 주황 |
| `size/XL` | 500+ | 빨강 |

---

## 사용법

```yaml
# .github/workflows/pr-size.yml
name: "PR Size"
on:
  pull_request:
    types: [opened, reopened, synchronize]

jobs:
  size:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: haerong22/actions/pr-size-label@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

`contents: read`도 `actions/checkout`도 필요 없습니다.

### 생성물 제외하기

**이 설정이 라벨 품질을 좌우합니다.** `package-lock.json` 하나만 갱신돼도 5000줄이라, 제외하지 않으면 3줄 고친 PR이 `size/XL`로 찍힙니다.

기본값은 흔한 락파일만 거릅니다. 프로젝트에 생성물이 더 있다면 추가하세요.

```yaml
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          exclude-paths: |
            **/package-lock.json
            **/*.lock
            dist/**
            **/__snapshots__/**
            **/*.generated.ts
```

패턴은 셸 glob입니다. `*`는 `/`도 넘어서 매칭하며, `**/x`는 최상위의 `x`도 포함합니다.

### 구간 조정하기

```yaml
          sizes: |
            tiny=20
            small=100
            large=1000
            huge
          label-prefix: "PR:"
```

작은 것부터 `이름=상한` 순으로 적고, **마지막 줄은 상한 없이 이름만** 적으면 나머지 전부를 받습니다. 위 설정은 `PR:tiny` ~ `PR:huge` 라벨을 만듭니다.

### 큰 PR 막기

```yaml
          fail-over: XL     # XL 이상이면 스텝 실패
```

기본은 비어 있어 실패시키지 않습니다.

### 입력

| 입력 | 기본값 | 설명 |
|---|---|---|
| `github-token` | **필수** | `pull-requests: write` 권한 필요 |
| `label-prefix` | `size/` | 라벨 접두사 |
| `sizes` | XS/S/M/L/XL | `이름=상한` 줄바꿈 구분. 마지막은 상한 없음 |
| `metric` | `total` | `total`(추가+삭제) / `additions` / `files` |
| `exclude-paths` | 락파일 목록 | 제외할 경로 glob |
| `create-labels` | `true` | 없는 라벨을 색상과 함께 생성 |
| `label-colors` | 구간별 기본색 | `이름=hex` 로 덮어쓰기 |
| `fail-over` | - | 이 구간 이상이면 스텝 실패 |
| `fail-on-error` | `false` | 라벨 부착 실패 시 스텝 실패 여부 |
| `dry-run` | `false` | 라벨을 붙이지 않고 계산만 |

### 출력

| 출력 | 예시 |
|---|---|
| `size` | `size/M` |
| `bucket` | `M` |
| `total` / `additions` / `deletions` / `files` | 제외 후 값 |
| `excluded-files` / `excluded-lines` | 제외된 양 |

---

## 어떻게 동작하나

```
1. 파일 목록 조회    gh api --paginate .../pulls/{n}/files
2. 제외 필터         exclude-paths glob 매칭 → 제외량 로그
3. 크기 계산         metric 기준으로 합산
4. 구간 판정         sizes 의 상한과 비교
5. 라벨 반영         기존 size/* 제거 → 대상 라벨 부착
```

이미 올바른 라벨이 붙어 있으면 지우고 다시 붙이지 않습니다.

---

## 알아둘 것

### fork PR에서는 라벨을 못 붙입니다

`pull_request` 이벤트는 fork에서 온 PR에 대해 `GITHUB_TOKEN`이 읽기 전용이라 부착이 403으로 실패합니다.

기본적으로 **경고만 남기고 워크플로우를 막지 않습니다.**

```
::warning::라벨 부착 실패: size/M (fork PR 은 토큰이 읽기 전용이라 실패합니다)
```

fork PR에도 붙이려면 `pull_request_target`을 써야 하는데, 그건 fork 코드에 쓰기 권한을 주는 셈이라 일반적으로 권하지 않습니다. 다만 이 액션은 **코드를 체크아웃하지 않으므로** 상대적으로 위험이 낮은 편입니다.

### 파일 3000개 상한

GitHub PR files API는 3000개까지만 반환합니다. 넘으면 크기가 실제보다 작게 계산되므로 경고를 남깁니다. 조용히 자르지 않습니다.

### code-reviewer와 함께 쓰기

size 라벨은 규모 표시용이라 리뷰를 트리거하지 않습니다. 규모에 따라 리뷰 관점을 자동으로 정하고 싶다면 [code-reviewer](../code-reviewer)의 `label-profile-map`에 연결하세요.

```yaml
          label-profile-map: |
            size/XL=architecture
            size/XS=quick
```

> 이렇게 하면 size 라벨만으로 **모든 PR이 리뷰 대상**이 됩니다.
> 필요한 PR에만 리뷰를 받으려면 연결하지 말고 `claude-review` 라벨을 그대로 쓰세요.
