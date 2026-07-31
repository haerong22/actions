# Slack Notify

워크플로우 실행 결과를 **일관된 형식으로** Slack에 보냅니다.

---

## 무엇을 하나

Block Kit JSON을 워크플로우마다 30~50줄씩 복붙하는 대신, 값 몇 개만 넘기면 됩니다.
레포·브랜치·커밋·실행자·실행 링크는 액션이 알아서 채웁니다.

```yaml
- uses: haerong22/actions/slack-notify@v1
  if: always()
  with:
    slack-bot-token: ${{ secrets.SLACK_BOT_TOKEN }}
    channel-id: ${{ secrets.SLACK_CHANNEL_ID }}
    status: ${{ job.status }}
```

```
┃ 🔴 Failure
┃
┃ Repo                     Ref
┃ ogqcorp/pit-monorepo     master
┃ Actor                    Commit
┃ haerong22                abc1234 fix: 토큰 검증 누락
┃
┃ [View logs ↗]
┃ Deploy Prod #42
```

| status | 이모지 | 색상 | 기본 제목 |
|---|---|---|---|
| `success` | ✅ | 초록 | Success |
| `failure` | 🔴 | 빨강 | Failure |
| `cancelled` | ⚪ | 회색 | Cancelled |
| `skipped` | ⏭️ | 회색 | Skipped |
| 그 외 | 🔔 | 파랑 | status 값 그대로 |

---

## 사용법

### 사전 준비

1. Slack 앱을 만들고 **`chat:write`** 스코프를 부여합니다.
2. 보낼 채널에 봇을 초대합니다.
3. 레포 시크릿에 `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`를 등록합니다.

### CI — 실패만 알림

```yaml
      - name: Notify Slack
        if: failure()
        uses: haerong22/actions/slack-notify@v1
        with:
          slack-bot-token: ${{ secrets.SLACK_BOT_TOKEN }}
          channel-id: ${{ secrets.SLACK_CHANNEL_ID }}
          status: failure
          title: "테스트 실패"
          mention: here
```

### 배포 — 성공·실패 모두

```yaml
      - name: Notify Slack
        if: always()
        uses: haerong22/actions/slack-notify@v1
        with:
          slack-bot-token: ${{ secrets.SLACK_BOT_TOKEN }}
          channel-id: ${{ secrets.SLACK_CHANNEL_ID }}
          status: ${{ job.status }}
          fields: |
            Env=production
            Target=payment-server
          mention: here          # mention-on 기본값이 failure 라 실패 시에만 붙는다
```

> `if: always()` 를 빼면 **실패했을 때 알림이 오지 않습니다.** 앞 스텝이 실패하면
> 뒤 스텝은 기본적으로 실행되지 않습니다.

### 링크 바꾸기

기본 버튼은 성공이면 커밋, 그 외에는 실행 로그로 갑니다. 바꾸려면:

```yaml
          links: |
            배포된 서비스=https://api.example.com
            대시보드=https://grafana.example.com/d/abc
```

### 완전히 다른 메시지를 보내야 할 때

템플릿이 안 맞으면 Block Kit 페이로드를 직접 넘깁니다.

```yaml
          payload: |
            {
              "text": "주간 리포트",
              "blocks": [{ "type": "divider" }]
            }
```

`channel` 을 생략하면 `channel-id` 입력이 채워집니다.

### 입력

| 입력 | 기본값 | 설명 |
|---|---|---|
| `slack-bot-token` | **필수** | Bot Token (`chat:write` 필요) |
| `channel-id` | **필수** | 채널 ID (봇이 초대되어 있어야 함) |
| `status` | `success` | `success`/`failure`/`cancelled`/`skipped`/임의 문자열 |
| `title` | status별 | 헤드라인 |
| `message` | - | 헤드라인 아래 본문 |
| `fields` | - | `키=값` 줄바꿈 구분. 2열로 렌더링 |
| `links` | status별 | `텍스트=URL` 줄바꿈 구분. 버튼으로 렌더링 |
| `mention` | - | `here` / `channel` / `<@U123>` / `<!subteam^S123>` |
| `mention-on` | `failure` | 멘션을 붙일 status. `all` 이면 항상 |
| `notify-on` | `all` | 알림을 보낼 status. `all` 이면 항상 |
| `include-commit` | `true` | 커밋 SHA·제목 포함 여부 |
| `emoji` | status별 | 헤드라인 이모지 덮어쓰기 |
| `color` | status별 | 좌측 색상 바 덮어쓰기 |
| `payload` | - | Block Kit 페이로드 직접 지정 (템플릿 무시) |
| `fail-on-error` | `false` | 전송 실패 시 스텝을 실패시킬지 |
| `dry-run` | `false` | 전송하지 않고 페이로드만 로그에 출력 |

### 출력

| 출력 | 설명 |
|---|---|
| `sent` | 실제로 전송했는지 (`true`/`false`) |
| `ts` | 전송된 메시지 타임스탬프. 스레드 답글에 쓸 수 있다 |

---

## 어떻게 동작하나

### 실행 흐름

```
1. notify-on 판정        보낼 status 가 아니면 여기서 종료
2. status 해석           이모지·색상·기본 제목 결정
3. 컨텍스트 수집          레포·Ref·실행자·커밋 (호출부가 넘기지 않아도 됨)
4. 페이로드 조립          jq 로 Block Kit 생성
5. chat.postMessage      curl 로 전송 → 응답의 .ok 확인
```

### 커밋 제목은 3단으로 찾습니다

```
github.event.head_commit.message   push 이벤트
        ↓ 없으면
github.event.pull_request.title    PR 이벤트
        ↓ 없으면
git log -1 --pretty=%s             workflow_dispatch (checkout 이 앞에 있을 때)
        ↓ 없으면
생략
```

`head_commit` 은 **push 이벤트에만 존재**합니다. 수동 실행(`workflow_dispatch`)에서
커밋 제목이 비지 않도록 폴백합니다.

### 이스케이프

Slack mrkdwn은 `&`, `<`, `>`를 특수문자로 씁니다. 커밋 메시지에 이런 문자가 있으면
메시지가 깨지므로 변환합니다.

```
feat: A & B          →  feat: A &amp; B
fix: a<b 비교 오류    →  fix: a&lt;b 비교 오류
```

단, `<url|text>` 링크 문법과 `plain_text` 버튼 라벨은 이스케이프하지 않습니다.
이 계층 구분 때문에 페이로드를 **문자열 조립이 아니라 jq로** 만듭니다.

### 실패해도 워크플로우를 막지 않습니다

알림 전송 실패가 배포를 실패로 만들면 안 되므로, 기본적으로 경고만 남기고 넘어갑니다.
반대 동작이 필요하면 `fail-on-error: true`.

Slack은 페이로드가 잘못돼도 **HTTP 200**을 주는 경우가 있어, 응답의 `ok` 필드까지 확인합니다.

### 길이 제한

Slack section text는 3000자 제한이 있습니다.

| 대상 | 상한 | 초과 시 |
|---|---|---|
| `message` | 2500자 | 잘라내고 로그에 남김 |
| 커밋 제목 | 200자 | 잘라내고 로그에 남김 |
| section fields | 10개 | **잘라내지 않고 섹션을 나눔** |

### 로컬에서 페이로드 확인하기

`dry-run: true` 로 넘기면 전송하지 않고 조립된 JSON만 출력합니다.
Slack [Block Kit Builder](https://app.slack.com/block-kit-builder)에 붙여넣어 미리 볼 수 있습니다.
