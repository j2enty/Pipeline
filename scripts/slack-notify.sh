#!/usr/bin/env bash
# slack-notify.sh — 파이프라인 에스컬레이션 Slack 알림 발송
#
# 배경:
#   자동화가 에스컬레이션 케이스를 만나면 GitHub 이슈/PR 코멘트로 풀 컨텍스트를
#   남기고, 동시에 Slack 채널에 푸시 알림을 보내요. Slack 메시지는 "알아채기"
#   용도라서 짧게 (제목 + 컨텍스트 1~3줄 + GitHub 링크) 만 보내고, 풀 내용은
#   GitHub 이 영구 기록.
#
# 사용법:
#   ./scripts/slack-notify.sh <title> <github-url> <context>
#     title       — 한 줄 제목 (예: "kickoff 중단 — Frontend")
#     github-url  — GitHub 이슈/PR 코멘트 URL (사용자 클릭 진입점)
#     context     — 컨텍스트 1~3줄 (실패 유형·원인 요약 등 — 줄바꿈 \n 허용)
#
# 환경변수:
#   SLACK_TOKEN_KEY   — (옵션) webhook 이 담긴 env 변수의 "이름표" (예: RECLIP_SLACK_WEBHOOK).
#                       config slack-token-key 가 가리키는 env 이름. 주어지고 그 env 에 값이
#                       있으면 그것을 webhook 으로 사용한다. 이 역참조(${!VAR})는 이 스크립트가
#                       bash shebang(#!/usr/bin/env bash)이라 안전하다 — 호출 펜스의 셸(zsh 가능)과
#                       무관하게 여기서만 간접확장하므로 zsh "bad substitution" 함정을 피한다.
#   SLACK_WEBHOOK_URL — Slack Incoming Webhook URL (직접 주입 경로 / 폴백).
#                       GHA 는 이 값을 secret 으로 직접 주입한다. SLACK_TOKEN_KEY 역참조가
#                       값을 못 주면 이 값으로 폴백.
#                       둘 다 비면 발송 스킵 + exit 0 (파이프라인 중단 안 함).
#                       GitHub 코멘트가 이미 발송된 후 호출되므로 알림 누락만 발생.
#
# 예:
#   # (a) 토큰키 이름표 전달 — 헬퍼가 역참조:
#   SLACK_TOKEN_KEY=RECLIP_SLACK_WEBHOOK RECLIP_SLACK_WEBHOOK=https://hooks.slack.com/... \
#   ./scripts/slack-notify.sh "kickoff 중단 — Frontend" "<github-url>" "<context>"
#   # (b) webhook 직접 주입(GHA):
#   SLACK_WEBHOOK_URL=https://hooks.slack.com/... \
#   ./scripts/slack-notify.sh "kickoff 중단 — Frontend" "<github-url>" "<context>"

set -euo pipefail

# webhook 결정: SLACK_TOKEN_KEY(env 이름표) 역참조 우선, 없으면 SLACK_WEBHOOK_URL 폴백.
#   ${!VAR} 간접확장은 bash-ism — 이 스크립트는 bash shebang 이라 안전.
WEBHOOK="${SLACK_WEBHOOK_URL:-}"
if [ -n "${SLACK_TOKEN_KEY:-}" ] && [ -n "${!SLACK_TOKEN_KEY:-}" ]; then
  WEBHOOK="${!SLACK_TOKEN_KEY}"
fi
if [ -z "$WEBHOOK" ]; then
  echo "SLACK_TOKEN_KEY 역참조·SLACK_WEBHOOK_URL 모두 미설정 — Slack 발송 스킵 (GitHub 코멘트는 이미 발송됨)" >&2
  exit 0
fi

TITLE="${1:?사용법: $0 <title> <github-url> <context>}"
URL="${2:?github-url 인자 필요}"
CONTEXT="${3:-}"

# JSON safe escape 위해 python 사용 (셸 따옴표·특수문자 안전)
PAYLOAD=$(python3 -c '
import json, sys
title, url, context = sys.argv[1], sys.argv[2], sys.argv[3]
text = f"🚨 *{title}*\n{context}\n👀 <{url}|GitHub 코멘트 열기>"
print(json.dumps({"text": text}))
' "$TITLE" "$URL" "$CONTEXT")

RESPONSE=$(curl -sS -X POST \
  -H 'Content-type: application/json' \
  --data "$PAYLOAD" \
  "$WEBHOOK")

if [ "$RESPONSE" != "ok" ]; then
  echo "WARN: Slack 발송 실패 — response: $RESPONSE" >&2
  # 실패해도 exit 0 (파이프라인 차단 안 함)
fi

exit 0
