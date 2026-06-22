#!/usr/bin/env bash
# slack-wiring.test.sh — slack-notify.sh 의 SLACK_TOKEN_KEY 역참조 + 펜스 zsh 호환 검증 (#49-1).
#
# 배경(#49-1):
#   1차 수정(역참조를 SKILL 펜스에서 ${!SLACK_TOKEN_KEY} 로)이 잘못이었다. ${!VAR} 간접확장은
#   bash-ism 이라 펜스가 zsh 로 실행되면(실제 이 환경도 zsh) "bad substitution" 으로 死.
#   SKILL/reference/tmpl 펜스엔 bash 보장 단서(shebang·bash -c·shell:bash)가 없다.
#   → 역참조를 slack-notify.sh(#!/usr/bin/env bash shebang → ${!} 안전) **안으로** 옮긴다.
#   펜스는 SLACK_TOKEN_KEY(env 이름표)만 헬퍼에 env 로 넘긴다(${!} 없음 → zsh/bash 무관).
#
# 이 테스트는 헬퍼 기준으로 검증한다(외부 발송은 막아 functional·격리 유지):
#   ① SLACK_TOKEN_KEY=MY_HOOK + MY_HOOK=url → 헬퍼가 url 로 역참조해 발송 시도
#   ② GHA 시나리오: 토큰키 env 부재 + SLACK_WEBHOOK_URL 기설정 → 폴백 보존
#   ③ 둘 다 없음 → graceful skip(exit 0, 발송 안 함)
#   ④ SLACK_TOKEN_KEY 빈 문자열 → ${!} 가드로 에러 없이 SLACK_WEBHOOK_URL 폴백
#   ⑤ 레드 입증: 헬퍼에서 역참조 블록 제거 시 토큰키 시나리오가 skip 으로 떨어짐(데드)
#   ⑥ 정적 가드(zsh 회귀 차단): SKILL·reference·tmpl 펜스에 ${! 간접확장 0건
#   ⑦ 헬퍼 shebang 이 bash(역참조 ${!} 안전 근거)
#
# 발송 차단: curl 을 임시 PATH 스텁으로 가로채 실제 네트워크 호출 없이 "ok" 반환.
# 결정적·격리: 임시 디렉토리·서브셸 env 만 사용.
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$TEST_DIR/../scripts/slack-notify.sh"
# 펜스 정적 가드는 본체 전체(plugin skills + tmpl)를 대상으로 — zsh 회귀 광역 차단.
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n" "$1" >&2; }

echo ""
echo -e "${C_CYAN}══ slack-notify.sh SLACK_TOKEN_KEY 역참조 + 펜스 zsh 호환 (#49-1) ══${C_NC}"

[ -f "$HELPER" ] || { fail "slack-notify.sh 존재"; echo "통과 0 실패 1"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 필요(헬퍼가 payload 생성에 사용)"; echo "통과 0 실패 1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export WORK

# curl 스텁 — 실제 발송 막고, 받은 webhook URL(마지막 위치인자)을 파일에 기록 후 "ok" 출력.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do url="$a"; done   # 마지막 인자 = webhook URL
printf '%s' "$url" > "$WORK_CURL_URL"
printf 'ok'
EOF
chmod +x "$WORK/bin/curl"

# 헬퍼 1회 실행 — 격리 env + curl 스텁 PATH. exit·잡은 URL·stderr 를 전역으로 돌려준다.
#   사용: run_helper "<SLACK_TOKEN_KEY>" "<SLACK_WEBHOOK_URL>" "<MY_HOOK 값(빈=unset)>"
run_helper() {
  local tkey="$1" weburl="$2" myhook="$3"
  : > "$WORK/curl-url"
  local env_args=(WORK_CURL_URL="$WORK/curl-url" PATH="$WORK/bin:$PATH")
  [ -n "$tkey" ]   && env_args+=("SLACK_TOKEN_KEY=$tkey")
  [ -n "$weburl" ] && env_args+=("SLACK_WEBHOOK_URL=$weburl")
  [ -n "$myhook" ] && env_args+=("MY_HOOK=$myhook")
  HELPER_EXIT=0
  HELPER_ERR="$(env "${env_args[@]}" bash "$HELPER" "제목" "https://gh/c" "ctx" 2>&1 1>/dev/null)" || HELPER_EXIT=$?
  CURL_URL="$(cat "$WORK/curl-url" 2>/dev/null || true)"
}

# SW-1 토큰키 역참조.
run_helper "MY_HOOK" "" "https://hooks.slack.com/AAA"
if [ "$CURL_URL" = "https://hooks.slack.com/AAA" ]; then
  pass "(SW-1) 헬퍼 역참조: SLACK_TOKEN_KEY=MY_HOOK → MY_HOOK 의 webhook 으로 발송"
else
  fail "(SW-1) 헬퍼 역참조 실패: curl url='$CURL_URL'(https://hooks.slack.com/AAA 기대)"
fi

# SW-2 GHA 폴백.
run_helper "MY_HOOK" "https://hooks.slack.com/GHA" ""
if [ "$CURL_URL" = "https://hooks.slack.com/GHA" ]; then
  pass "(SW-2) GHA 폴백: 토큰키 env 부재면 SLACK_WEBHOOK_URL 로 발송"
else
  fail "(SW-2) GHA 폴백 실패: curl url='$CURL_URL'(https://hooks.slack.com/GHA 기대)"
fi

# SW-3 둘 다 없음 → graceful skip.
run_helper "MY_HOOK" "" ""
if [ "$HELPER_EXIT" -eq 0 ] && [ -z "$CURL_URL" ]; then
  pass "(SW-3) 둘 다 미설정 → graceful skip(exit 0, 발송 안 함)"
else
  fail "(SW-3) graceful skip 실패: exit=$HELPER_EXIT curl-url='$CURL_URL'"
fi

# SW-4 빈 SLACK_TOKEN_KEY → ${!} 가드 + SLACK_WEBHOOK_URL 폴백.
run_helper "" "https://hooks.slack.com/EMPTYKEY" ""
if [ "$HELPER_EXIT" -eq 0 ] && [ "$CURL_URL" = "https://hooks.slack.com/EMPTYKEY" ]; then
  pass "(SW-4) SLACK_TOKEN_KEY 빈 문자열 → 에러 없이 SLACK_WEBHOOK_URL 폴백(가드 동작)"
else
  fail "(SW-4) 빈 토큰키 가드 실패: exit=$HELPER_EXIT curl-url='$CURL_URL' err='$HELPER_ERR'"
fi

# SW-5 레드 입증: 헬퍼 역참조 블록 제거 시 토큰키 시나리오가 발송 안 됨(1차 데드와이어링 재현).
BROKEN="$WORK/slack-notify-broken.sh"
awk '
  /if \[ -n "\$\{SLACK_TOKEN_KEY:-\}" \]/ {skip=1}
  skip && /^fi$/ {skip=0; next}
  skip {next}
  {print}
' "$HELPER" > "$BROKEN"
if grep -qF '${!SLACK_TOKEN_KEY' "$BROKEN"; then
  fail "(SW-5pre) 레드 픽스처에 역참조 블록이 남음 — awk 추출 실패"
else
  : > "$WORK/curl-url"
  env WORK_CURL_URL="$WORK/curl-url" PATH="$WORK/bin:$PATH" \
      SLACK_TOKEN_KEY="MY_HOOK" MY_HOOK="https://hooks.slack.com/AAA" \
      bash "$BROKEN" "제목" "https://gh/c" "ctx" >/dev/null 2>&1 || true
  broken_url="$(cat "$WORK/curl-url" 2>/dev/null || true)"
  if [ -z "$broken_url" ]; then
    pass "(SW-5) 레드 입증: 헬퍼 역참조 제거 시 토큰키 시나리오가 발송 안 됨(데드와이어링 재현)"
  else
    fail "(SW-5) 레드 입증 실패: 역참조 없는데 발송됨 url='$broken_url'"
  fi
fi

# SW-6 정적 가드(zsh 회귀 차단): 펜스에 ${! 간접확장 0건.
FENCE_HITS="$(grep -rn '${!' \
  "$REPO_ROOT"/plugin/skills/*/SKILL.md \
  "$REPO_ROOT"/plugin/skills/*/reference/*.md \
  "$REPO_ROOT"/templates/claude-commands/*.tmpl 2>/dev/null || true)"
if [ -z "$FENCE_HITS" ]; then
  pass "(SW-6) SKILL·reference·tmpl 펜스에 \${!} 간접확장 0건(zsh 호환)"
else
  fail "(SW-6) 펜스에 \${!} 간접확장 발견(zsh 깨짐 위험):"
  printf '%s\n' "$FENCE_HITS" | sed 's/^/    ↳ /' >&2
fi

# SW-7 헬퍼 shebang 이 bash(역참조 ${!} 의 안전 근거).
if head -1 "$HELPER" | grep -qE '^#!.*bash'; then
  pass "(SW-7) 헬퍼 shebang 이 bash(역참조 \${!} 안전 보장)"
else
  fail "(SW-7) 헬퍼 shebang 이 bash 아님 — \${!} 안전 근거 상실"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
