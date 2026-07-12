#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034,SC2329
# test-janus-notify.sh — janus-notify.sh(Janus 버튼 알림 발사측, #37 PR2) 단위 테스트.
#
# 검증 계약(전부 best-effort — 어떤 경로도 파이프라인을 막지 않는다: exit 0 불변):
#   JN-1 Janus 타깃 미설정 → 발송 스킵 + exit 0 (curl 미호출)
#   JN-2 env 이름표 역참조(JANUS_URL_KEY/JANUS_TOKEN_KEY)가 직접 env 보다 우선
#   JN-3 직접 env(JANUS_BASE_URL/JANUS_AUTH_TOKEN) 폴백
#   JN-4 버튼 value 2000자 초과 → 버튼 제거하고 텍스트만 발송 (payload 에 buttons 없음)
#   JN-5 비 2xx 응답 → 경고 + exit 0
#   JN-6 정상 발송 payload 구조 (source_id 기본 pipeline·correlation_id·buttons object)
#   JN-7 base URL 뒤 슬래시 제거 → {base}/messages 정확 조립
#
# 라이브 접근 없음 — curl 은 PATH 스텁으로 가로채 요청을 로그파일에 기록한다.

NOTIFY="$REPO_ROOT/scripts/janus-notify.sh"

# 각 테스트가 fresh 한 curl 스텁 dir·요청 로그를 갖도록 셋업.
#   $1: (옵션) curl 이 반환할 HTTP 코드(기본 200). "NET_FAIL" 이면 curl 자체를 exit 7 로.
# 스텁 dir 경로를 stdout 으로 반환 → 호출부가 PATH 앞에 붙이고 CURL_LOG 를 읽는다.
_setup_curl_stub() {
  local code="${1:-200}"
  local dir; dir="$(mktemp -d)"
  export CURL_LOG="$dir/req.log"; : > "$CURL_LOG"
  if [ "$code" = "NET_FAIL" ]; then
    cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  else
    cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
# 마지막 인자(URL)와 --data payload 를 로그로 남기고 HTTP 코드 반환.
url="\${@: -1}"; data=""
while [ \$# -gt 0 ]; do case "\$1" in --data) shift; data="\$1";; esac; shift; done
{ echo "URL=\$url"; echo "DATA=\$data"; } >> "$CURL_LOG"
printf '%s' "$code"
EOF
  fi
  chmod +x "$dir/curl"
  echo "$dir"
}

VALUE_JSON='{"v":1,"t":"set-status","projectId":"PVT_x","fieldId":"PVTSSF_y","optionId":"opt1","items":["PVTI_a","PVTI_b"],"label":"In Progress"}'
BUTTONS_JSON='[{"action":"set-status","label":"In Progress 보내기 🚀","value":'"$VALUE_JSON"'}]'

# ── JN-1: 미설정 스킵 ────────────────────────────────────────────────
it "JN-1 Janus 타깃 미설정 → 발송 스킵 + exit 0 (curl 미호출)"
(
  dir="$(_setup_curl_stub 200)"
  CURL_LOG="$dir/req.log"
  rc=0
  PATH="$dir:$PATH" env -u JANUS_BASE_URL -u JANUS_AUTH_TOKEN -u JANUS_URL_KEY -u JANUS_TOKEN_KEY \
    bash "$NOTIFY" "#c" "txt" "$BUTTONS_JSON" "cid" >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "미설정 시 exit 0" || exit 0
  [ ! -s "$CURL_LOG" ] && pass || fail "미설정인데 curl 호출됨(로그 비어야 함)"
)

# ── JN-2: 이름표 역참조 우선 ─────────────────────────────────────────
it "JN-2 env 이름표(JANUS_URL_KEY/TOKEN_KEY)가 직접 env 보다 우선"
(
  dir="$(_setup_curl_stub 200)"
  CURL_LOG="$dir/req.log"
  PATH="$dir:$PATH" \
    JANUS_URL_KEY=MY_URL JANUS_TOKEN_KEY=MY_TOK \
    MY_URL="http://label-host:8700" MY_TOK="labeltok" \
    JANUS_BASE_URL="http://direct-should-not-use" JANUS_AUTH_TOKEN="directtok" \
    bash "$NOTIFY" "#c" "txt" "" "" >/dev/null 2>&1
  log="$(cat "$CURL_LOG")"
  assert_contains "$log" "URL=http://label-host:8700/messages" "이름표 URL 우선" || exit 0
  assert_not_contains "$log" "direct-should-not-use" "직접 env 를 안 써야" || exit 0
  pass
)

# ── JN-3: 직접 env 폴백 ──────────────────────────────────────────────
it "JN-3 이름표 없으면 직접 env(JANUS_BASE_URL/JANUS_AUTH_TOKEN) 폴백"
(
  dir="$(_setup_curl_stub 200)"
  CURL_LOG="$dir/req.log"
  PATH="$dir:$PATH" env -u JANUS_URL_KEY -u JANUS_TOKEN_KEY \
    JANUS_BASE_URL="http://direct-host:8700" JANUS_AUTH_TOKEN="dtok" \
    bash "$NOTIFY" "#c" "txt" "" "" >/dev/null 2>&1
  assert_contains "$(cat "$CURL_LOG")" "URL=http://direct-host:8700/messages" "직접 env 폴백 URL" || exit 0
  pass
)

# ── JN-4: 버튼 value 2000자 초과 → 버튼 제거 ─────────────────────────
it "JN-4 버튼 value 2000자 초과 → 버튼 제거하고 텍스트만 발송 (exit 0)"
(
  dir="$(_setup_curl_stub 200)"
  CURL_LOG="$dir/req.log"
  big="$(python3 -c 'print("x"*2100)')"
  bigbtn='[{"action":"set-status","label":"L","value":"'"$big"'"}]'
  rc=0
  PATH="$dir:$PATH" JANUS_BASE_URL="http://h:8700" JANUS_AUTH_TOKEN="t" \
    bash "$NOTIFY" "#c" "txt" "$bigbtn" "cid" >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "2000자 초과여도 exit 0" || exit 0
  log="$(cat "$CURL_LOG")"
  assert_contains "$log" "DATA=" "발송은 됨(텍스트만)" || exit 0
  assert_not_contains "$log" '"buttons"' "버튼 필드 제거됨" || exit 0
  pass
)

# ── JN-5: 비 2xx → exit 0 ───────────────────────────────────────────
it "JN-5 비 2xx(500) 응답 → 경고 + exit 0 (파이프라인 차단 안 함)"
(
  dir="$(_setup_curl_stub 500)"
  CURL_LOG="$dir/req.log"
  rc=0
  PATH="$dir:$PATH" JANUS_BASE_URL="http://h:8700" JANUS_AUTH_TOKEN="t" \
    bash "$NOTIFY" "#c" "txt" "" "" >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "비 2xx 여도 exit 0" || exit 0
  pass
)

# ── JN-5b: 네트워크 실패(curl 자체 exit≠0) → exit 0 ─────────────────
it "JN-5b curl 네트워크 실패 → exit 0"
(
  dir="$(_setup_curl_stub NET_FAIL)"
  CURL_LOG="$dir/req.log"
  rc=0
  PATH="$dir:$PATH" JANUS_BASE_URL="http://h:8700" JANUS_AUTH_TOKEN="t" \
    bash "$NOTIFY" "#c" "txt" "" "" >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "네트워크 실패여도 exit 0" && pass
)

# ── JN-6: 정상 발송 payload 구조 ─────────────────────────────────────
it "JN-6 payload 구조 (source_id 기본 pipeline·correlation_id·buttons value object)"
(
  dir="$(_setup_curl_stub 200)"
  CURL_LOG="$dir/req.log"
  PATH="$dir:$PATH" env -u JANUS_SOURCE_ID \
    JANUS_BASE_URL="http://h:8700" JANUS_AUTH_TOKEN="t" \
    bash "$NOTIFY" "#reclip-alerts" "본문" "$BUTTONS_JSON" "plan-42" >/dev/null 2>&1
  data="$(grep '^DATA=' "$CURL_LOG" | sed 's/^DATA=//')"
  # python 으로 파싱해 구조 단언(문자열 grep 보다 견고).
  ok="$(printf '%s' "$data" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["source_id"]=="pipeline", d.get("source_id")
assert d["channel"]=="#reclip-alerts"
assert d["correlation_id"]=="plan-42"
b=d["buttons"][0]
assert b["action"]=="set-status"
v=b["value"]              # value 는 object 로 실려야 함(App validateSetStatusValue 가 object/문자열 모두 수용)
assert v["v"]==1 and v["t"]=="set-status"
assert v["projectId"].startswith("PVT_") and v["fieldId"].startswith("PVTSSF_")
assert v["items"]==["PVTI_a","PVTI_b"] and v["label"]=="In Progress"
print("ok")
' 2>/dev/null)"
  assert_eq "ok" "$ok" "payload 구조가 PR1 스키마와 일치" && pass
)

# ── JN-7: base URL 뒤 슬래시 정규화 ─────────────────────────────────
it "JN-7 base URL 뒤 슬래시 제거 → {base}/messages 이중슬래시 없음"
(
  dir="$(_setup_curl_stub 200)"
  CURL_LOG="$dir/req.log"
  PATH="$dir:$PATH" JANUS_BASE_URL="http://h:8700///" JANUS_AUTH_TOKEN="t" \
    bash "$NOTIFY" "#c" "txt" "" "" >/dev/null 2>&1
  log="$(cat "$CURL_LOG")"
  assert_contains "$log" "URL=http://h:8700/messages" "슬래시 정규화" || exit 0
  assert_not_contains "$log" "8700//messages" "이중슬래시 없음" || exit 0
  pass
)
