#!/usr/bin/env bash
# healthcheck-watch.sh — Pipeline App 컨테이너 외부 살아있음 감시
#
# 배경:
#   App 의 /health 엔드포인트는 "App 프로세스가 살아있을 때" 만 응답한다.
#   프로세스가 통째로 죽으면(컨테이너 死·OOM·crash) /health 자체가 응답 불가 →
#   App 내부 알림(notifyFailure)도 못 보낸다. 그래서 이 스크립트는 App 외부에서
#   /health 를 찔러 실패 시 slack-notify.sh 로 "컨테이너 死" 알림을 보낸다.
#
# 사용법:
#   ./scripts/healthcheck-watch.sh
#
# 환경변수:
#   HEALTHCHECK_URL   — 헬스체크 엔드포인트 (옵션, 기본 http://localhost:3000/health)
#   SLACK_WEBHOOK_URL — slack-notify.sh 가 사용. 미설정 시 알림 자동 스킵(exit 0).
#
# 맥미니 crontab 등록 예시 (5분마다 감시):
#   */5 * * * * SLACK_WEBHOOK_URL=https://hooks.slack.com/... \
#     /path/to/Pipeline/scripts/healthcheck-watch.sh >> /tmp/healthcheck-watch.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://localhost:3000/health}"

# /health 를 찔러 HTTP 200 인지 확인. 연결 실패·비200 → 컨테이너 死 간주.
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTHCHECK_URL" || echo "000")"

if [ "$HTTP_CODE" = "200" ]; then
  echo "healthcheck OK ($HEALTHCHECK_URL → $HTTP_CODE)"
  exit 0
fi

echo "healthcheck FAIL ($HEALTHCHECK_URL → $HTTP_CODE) — Slack 알림 시도" >&2

# slack-notify.sh 호출 — SLACK_WEBHOOK_URL 미설정 시 알아서 스킵(exit 0).
# url 인자에는 헬스체크 엔드포인트를 넘겨 운영자가 바로 확인하게 한다.
"$SCRIPT_DIR/slack-notify.sh" \
  "Pipeline App 응답 없음 — 컨테이너 死 의심" \
  "$HEALTHCHECK_URL" \
  "헬스체크 실패 (HTTP $HTTP_CODE). docker 컨테이너 상태를 확인하세요."

exit 0
