# 에스컬레이션 템플릿·진단

> Step 9(에스컬 플로우, G2 + G3-b)에서 참조. `blocked` 라벨(9-a)·에스컬 코멘트 본문(9-b)·
> 상태 파일 업데이트(9-c)·영역별 독립 원칙(9-d)·Slack 이중 발송 규칙.
> `<owner>`·`<영역>`·`<parent-repo-name>` 등은 SKILL.md 의 config 주입값·실행 컨텍스트로
> 채운다 (하드코딩 금지).

## 9-a. `blocked` 라벨 보장 + 부착

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
gh label create blocked \
  --repo "$OWNER/<영역>" \
  --color "d73a4a" \
  --description "/kickoff 에스컬 발생 — 사용자 대응 필요" \
  2>/dev/null || true

gh issue edit <sub-N> --repo "$OWNER/<영역>" --add-label blocked
```

> `blocked` 라벨은 `/kickoff` 소유. `/review` 의 `review-blocked` 와 혼동 금지.

## 9-b. 에스컬 코멘트 발송 (G2-b 템플릿)

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
SLACK_TOKEN_KEY="$(bash "$CFG" slack-token-key)"
SLACK_CHANNEL="$(bash "$CFG" slack-channel)"

# sub-issue 의 assignees 조회
ASSIGNEES=$(gh api /repos/$OWNER/<영역>/issues/<sub-N> \
  --jq '[.assignees[].login | "@" + .] | join(" ")')

COMMENT=$(cat <<EOF
## 🚨 \`/kickoff\` 중단 — <영역>

${ASSIGNEES:+${ASSIGNEES} 확인 요청.}

**기능:** <slug>  (parent: $OWNER/$PARENT_REPO_NAME#<parent-N>)
**실패 유형:** \`<카테고리> / <subcategory>\` (<count>/<limit>)
**에러 메시지:** <errorSummary.message 1~2줄>
**상세 로그:** 상태 파일 \`rawTail\` 참조 — \`.pipeline/state/sessions/<slug>.json\`

**실행 컨텍스트**
- 브랜치: \`feature/#<sub-N>-<slug>\`
- 재시도: <카테고리> <count>/<limit> ✖
- 이전 PR 시도: <PR URL or "없음">

**재개 방법**
1. 위 에러 메시지·상세 로그로 원인 진단 후 수정 커밋
2. \`/kickoff <parent-url>\` 재실행
3. 상태 파일 감지 → AskUserQuestion [재개 / 처음부터 / 취소] — "재개" 시 실패 영역만 다시 실행

**참고**
- 플랜: Docs/claude/plans/<parent-N>-<slug>-<영역소문자>.md

---
*자동 발송됨.*
EOF
)

COMMENT_URL=$(gh issue comment <sub-N> --repo "$OWNER/<영역>" --body "$COMMENT")

# Slack 이중 발송 (보조 채널 — 발송 실패해도 파이프라인 차단 안 함).
# 메시지는 짧게: 제목 + 컨텍스트 1~3줄 + GitHub 링크. 풀 내용은 위 GitHub 코멘트가 기록.
#   SLACK_TOKEN_KEY(slack-token-key 가 준 env 이름표, 민감키·--dump 미노출)를 헬퍼에 env 로
#   넘긴다. 간접확장(env 이름표를 실제 값으로 푸는 bash 전용 문법)은 헬퍼(slack-notify.sh)
#   안에서 한다 — 헬퍼가 bash shebang 이라 안전. 이 펜스는 사용자 셸(zsh 가능)로 실행되므로
#   간접확장을 여기 두면 zsh 에서 "bad substitution" 으로 깨진다(그래서 펜스엔 안 둔다).
#   헬퍼는 SLACK_TOKEN_KEY 역참조 우선, 없으면 SLACK_WEBHOOK_URL 폴백, 둘 다 없으면
#   graceful skip → 파이프라인 차단 없음.
SLACK_CONTEXT=$(printf '기능: %s\n실패 유형: %s %s/%s\n에러: %s' \
  "<slug>" "<카테고리>" "<count>" "<limit>" "<errorSummary.message 1줄>")
SLACK_TOKEN_KEY="$SLACK_TOKEN_KEY" \
  "${CLAUDE_SKILL_DIR}/scripts/slack-notify.sh" "/kickoff 중단 — <영역>" "$COMMENT_URL" "$SLACK_CONTEXT"
```

**진단 힌트**: executor 의 `errorSummary.message` + `rawTail` 이 이미 구체적이므로 일반화
힌트 표 없음. 사용자는 에러 메시지로 검색·진단. 2026-04-20 파일럿 실측: 표 9항목 중 실제
에스컬(Android JDK 미설치) 매치 0건.

**`--bot` 모드 표기**: `BOT_MODE=true` 면 에스컬 코멘트에 "🤖 봇 자동 실행 중 발생" 명시.

**Slack 이중 발송 규칙**:
- 메시지 형식: 제목 + 컨텍스트 (실패 유형·에러 요약) + GitHub 코멘트 링크. 풀 컨텍스트
  중복 금지 (GitHub 이 영구 기록)
- 펜스는 `SLACK_TOKEN_KEY`(slack-token-key 가 준 env 이름표)를 헬퍼에 env 로 넘긴다. 간접확장(bash 전용 문법)은 헬퍼(bash shebang) 안에서 수행 — 펜스엔 간접확장을 두지 않아 zsh 에서도 안전. 헬퍼는 `SLACK_TOKEN_KEY` 역참조 우선, 없으면 `SLACK_WEBHOOK_URL` 폴백, 둘 다 미설정 시 graceful skip → 파이프라인 차단 없음
- Slack 발송 실패도 차단 없음 (보조 채널)
- GitHub 코멘트 발송이 1차, Slack 은 항상 그 뒤 호출 (순서 고정 — Slack 먼저 가면 사용자가
  빈 링크 클릭 위험)

## 9-c. 상태 파일 업데이트

```json
"areas": {
  "<area>": {
    "status": "escalated",
    "escalation": {
      "category": "fixing|transient|immediate",
      "subcategory": "<한글>",
      "commentUrl": "<이슈 코멘트 URL>",
      "commentedAt": "...",
      "blockedLabelAdded": true
    },
    "lastError": "<stderr 말미 20줄>"
  }
},
"events": [..., {"ts":"...", "type":"escalation", "area":"<area>", "category":"..."}]
```

## 9-d. 영역별 독립 원칙 (G3)

- 한 영역 에스컬 시 **나머지 영역은 계속 실행**
- 단 Backend 선행 영역이 에스컬되면 나머지 영역은 실행하지 않음 (8-b 참조 — Backend 계약
  없이 FE/iOS/Android 진행하면 G1-a 근거가 깨짐)
- 최종 리포트에 혼합 상태 그대로 표기
