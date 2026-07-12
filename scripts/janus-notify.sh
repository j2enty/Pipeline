#!/usr/bin/env bash
# janus-notify.sh — Janus 게이트웨이로 "버튼 달린" 메시지 발송 (best-effort 옵셔널 어댑터)
#
# 배경:
#   Janus(사내 메시지 게이트웨이 — Slack 소켓을 대신 쥐고 REST 로 발송·콜백해주는 프록시)를
#   통하면 Slack 에 "버튼"을 붙인 메시지를 보낼 수 있다. 사용자가 버튼을 1탭 하면 Janus 가
#   그 클릭을 App(POST /janus/callback)으로 콜백해준다. 이 스크립트는 그 "발사측"이다.
#
#   slack-notify.sh(텍스트 전용 webhook 발송)의 형제 스크립트로, 구조·문체를 맞췄다.
#   차이: (1) Janus REST(/messages)로 보내고 (2) 버튼 배열을 실을 수 있다.
#
#   ⚠️ 옵셔널 어댑터 — Janus 타깃(주소·토큰)이 설정돼 있지 않으면 조용히 스킵(exit 0)한다.
#   또 발송이 실패(네트워크·비 2xx·payload 조립 실패)해도 exit 0 + 경고만 낸다.
#   파이프라인(예: /plan)을 이 알림 하나가 절대 막지 않게 하기 위함(best-effort).
#
# 사용법:
#   ./scripts/janus-notify.sh <channel> <text> <buttons-json> [correlation-id]
#     channel       — Slack 채널 (예: "#reclip-alerts")
#     text          — 메시지 본문 (줄바꿈 허용)
#     buttons-json   — Janus /messages 의 buttons 배열 원문(JSON). 빈 문자열이면 버튼 없이 발송.
#                     예: '[{"action":"set-status","label":"보내기 🚀","value":{...}}]'
#     correlation-id — (옵션) 콜백 상관키. 있으면 payload 에 correlation_id 로 실린다.
#
# 환경변수 (Janus 타깃 결정 — slack-notify.sh 의 SLACK_TOKEN_KEY 역참조 기법과 동일):
#   JANUS_URL_KEY     — (옵션) Janus base URL 이 담긴 env 변수의 "이름표" (예: RECLIP_JANUS_URL).
#                       config janus.base-url-key 가 가리키는 env 이름. 주어지고 그 env 에 값이
#                       있으면 그것을 base URL 로 쓴다. 역참조(${!VAR})는 이 스크립트가 bash
#                       shebang 이라 안전하다(호출 펜스가 zsh 여도 여기서만 간접확장).
#   JANUS_TOKEN_KEY   — (옵션) Janus 인증 토큰이 담긴 env 변수의 "이름표" (예: RECLIP_JANUS_TOKEN).
#                       config janus.token-key 가 가리키는 env 이름.
#   JANUS_BASE_URL    — Janus base URL 직접 주입 경로 / 폴백 (예: http://host.docker.internal:8700).
#                       JANUS_URL_KEY 역참조가 값을 못 주면 이 값으로 폴백.
#   JANUS_AUTH_TOKEN  — Janus Bearer 토큰 직접 주입 / 폴백.
#   base URL·토큰 중 하나라도 비면 발송 스킵 + exit 0 (옵셔널 어댑터).
#   JANUS_SOURCE_ID   — (옵션) 메시지 source_id. 기본 "pipeline" (App 콜백 수신부 기대값과 동일).
#
# 예:
#   # (a) 이름표 전달 — 헬퍼가 역참조:
#   JANUS_URL_KEY=RECLIP_JANUS_URL JANUS_TOKEN_KEY=RECLIP_JANUS_TOKEN \
#   RECLIP_JANUS_URL=http://host.docker.internal:8700 RECLIP_JANUS_TOKEN=xxx \
#   ./scripts/janus-notify.sh "#reclip-alerts" "본문" '[{...버튼...}]' "plan-42"
#   # (b) 직접 주입:
#   JANUS_BASE_URL=http://... JANUS_AUTH_TOKEN=xxx \
#   ./scripts/janus-notify.sh "#reclip-alerts" "본문" "" ""

set -euo pipefail

# ── Janus base URL 결정: JANUS_URL_KEY(env 이름표) 역참조 우선, 없으면 JANUS_BASE_URL 폴백. ──
#   ${!VAR} 간접확장은 bash-ism — 이 스크립트는 bash shebang 이라 안전.
BASE_URL="${JANUS_BASE_URL:-}"
if [ -n "${JANUS_URL_KEY:-}" ] && [ -n "${!JANUS_URL_KEY:-}" ]; then
  BASE_URL="${!JANUS_URL_KEY}"
fi
# ── Janus 토큰 결정: JANUS_TOKEN_KEY 역참조 우선, 없으면 JANUS_AUTH_TOKEN 폴백. ──
TOKEN="${JANUS_AUTH_TOKEN:-}"
if [ -n "${JANUS_TOKEN_KEY:-}" ] && [ -n "${!JANUS_TOKEN_KEY:-}" ]; then
  TOKEN="${!JANUS_TOKEN_KEY}"
fi

# 앞뒤 공백 trim — env 값이 공백뿐이면 -z 가 통과해 쓰레기 값으로 발송하는 것 방지
# (slack-notify.sh 와 동일한 bash 패턴제거 기법).
BASE_URL="${BASE_URL#"${BASE_URL%%[![:space:]]*}"}"   # leading whitespace 제거
BASE_URL="${BASE_URL%"${BASE_URL##*[![:space:]]}"}"   # trailing whitespace 제거
TOKEN="${TOKEN#"${TOKEN%%[![:space:]]*}"}"            # leading whitespace 제거
TOKEN="${TOKEN%"${TOKEN##*[![:space:]]}"}"            # trailing whitespace 제거
# base URL 뒤 슬래시 제거 — {base}/messages 조립 시 이중 슬래시 방지(alert.ts 와 동일 정규화).
BASE_URL="${BASE_URL%"${BASE_URL##*[!/]}"}"

if [ -z "$BASE_URL" ] || [ -z "$TOKEN" ]; then
  echo "JANUS_URL_KEY/JANUS_BASE_URL·JANUS_TOKEN_KEY/JANUS_AUTH_TOKEN 미설정(또는 공백) — Janus 발송 스킵 (옵셔널 어댑터)" >&2
  exit 0
fi

CHANNEL="${1:?사용법: $0 <channel> <text> <buttons-json> [correlation-id]}"
TEXT="${2:?text 인자 필요}"
BUTTONS_JSON="${3:-}"
CORRELATION_ID="${4:-}"
SOURCE_ID="${JANUS_SOURCE_ID:-pipeline}"

# 버튼 value 최대 길이 — Slack 인터랙티브 요소 value 제한(2000자). 초과하면 버튼을 빼고
# 텍스트만 발송한다(기능 저하지만 알림 자체는 나간다).
MAX_BUTTON_VALUE_LEN=2000

# payload 조립은 python3 로 — 셸 따옴표·특수문자 이스케이프 지옥 회피 + 버튼 value 길이 가드.
#   비정상 종료(python 크래시 등) 시 PAYLOAD 를 빈 값으로 두고 아래에서 스킵(best-effort).
PAYLOAD="$(python3 -c '
import json, sys
source_id, channel, text, buttons_raw, correlation_id, max_len = sys.argv[1:7]
max_len = int(max_len)
payload = {"source_id": source_id, "channel": channel, "text": text}
if correlation_id:
    payload["correlation_id"] = correlation_id
if buttons_raw.strip():
    try:
        buttons = json.loads(buttons_raw)
    except Exception as e:
        sys.stderr.write(f"WARN: buttons-json 파싱 실패 — 버튼 없이 텍스트만 발송: {e}\n")
        buttons = None
    if buttons:
        # 버튼 value 2000자 초과 가드 — 하나라도 초과하면 버튼 전체 제거(텍스트만 발송) + 경고.
        too_long = False
        for b in buttons:
            v = b.get("value") if isinstance(b, dict) else None
            vs = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
            if len(vs) > max_len:
                too_long = True
                break
        if too_long:
            sys.stderr.write(f"WARN: 버튼 value 가 {max_len}자 초과 — 버튼 제거하고 텍스트만 발송\n")
        else:
            payload["buttons"] = buttons
sys.stdout.write(json.dumps(payload, ensure_ascii=False))
' "$SOURCE_ID" "$CHANNEL" "$TEXT" "$BUTTONS_JSON" "$CORRELATION_ID" "$MAX_BUTTON_VALUE_LEN")" || PAYLOAD=""

if [ -z "$PAYLOAD" ]; then
  echo "WARN: Janus payload 조립 실패 — 발송 스킵 (best-effort)" >&2
  exit 0
fi

# POST {base}/messages — Bearer 인증. 실패해도 파이프라인을 막지 않는다.
#   -o /dev/null -w '%{http_code}' 로 상태코드만 받고, 네트워크 실패는 || 로 000 처리.
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data "$PAYLOAD" \
  "$BASE_URL/messages" 2>/dev/null)" || HTTP_CODE="000"

case "$HTTP_CODE" in
  2*) : ;;  # 성공(2xx)
  *) echo "WARN: Janus 발송 실패 — HTTP $HTTP_CODE (best-effort 스킵)" >&2 ;;
esac

exit 0
