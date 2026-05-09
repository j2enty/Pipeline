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
#   SLACK_WEBHOOK_URL — Slack Incoming Webhook URL
#                       미설정이면 발송 스킵 + exit 0 (파이프라인 중단 안 함)
#                       GitHub 코멘트가 이미 발송된 후 호출되므로 알림 누락만 발생.
#
# 예:
#   SLACK_WEBHOOK_URL=https://hooks.slack.com/... \
#   ./scripts/slack-notify.sh \
#     "kickoff 중단 — Frontend" \
#     "https://github.com/org/repo/issues/12#issuecomment-..." \
#     "실패 유형: fixing 3/3\n에러: 컴파일 실패"

set -euo pipefail

WEBHOOK="${SLACK_WEBHOOK_URL:-}"
if [ -z "$WEBHOOK" ]; then
  echo "SLACK_WEBHOOK_URL 미설정 — Slack 발송 스킵 (GitHub 코멘트는 이미 발송됨)" >&2
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
