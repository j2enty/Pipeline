#!/usr/bin/env bash
# slack-wiring.test.sh — slack-notify.sh 의 SLACK_TOKEN_KEY 역참조 + 펜스 zsh 호환 검증 (#49-1).
#
# 배경(#49-1):
#   1차 수정(역참조를 펜스에서 ${!SLACK_TOKEN_KEY} 로)이 잘못이었다. ${!VAR} 간접확장은
#   bash-ism 이라 펜스가 zsh 로 실행되면 "bad substitution" 으로 死. SKILL/reference
#   펜스엔 bash 보장 단서가 없다. → 역참조를 slack-notify.sh(bash shebang) 안으로 옮긴다.
#   kickoff 의 에스컬 펜스는 reference/escalation.md 에 있고 헬퍼에 SLACK_TOKEN_KEY 만 env 로 넘긴다.
#   (P3.1) 정적 펜스 가드 대상은 plugin 자산(SKILL·reference)만 — 배포 SSOT 가 SKILL.md 로 일원화돼
#   templates/claude-commands/*.tmpl 의존 제거.
#
# 헬퍼 기준 검증(외부 발송은 curl 스텁으로 차단). 시나리오: 역참조 / GHA 폴백 / 둘 다 없음 /
#   빈 가드 / 레드입증 / 펜스 ${! 정적가드(escalation.md 포함) / 헬퍼 shebash bash.
# 결정적·격리: 임시 디렉토리·서브셸 env. 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$TEST_DIR/../scripts/slack-notify.sh"
ESCALATION="$TEST_DIR/../reference/escalation.md"
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
[ -f "$ESCALATION" ] || { fail "reference/escalation.md 존재"; echo "통과 0 실패 1"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 필요(헬퍼가 payload 생성에 사용)"; echo "통과 0 실패 1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export WORK

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do url="$a"; done
printf '%s' "$url" > "$WORK_CURL_URL"
printf 'ok'
EOF
chmod +x "$WORK/bin/curl"

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
[ "$CURL_URL" = "https://hooks.slack.com/AAA" ] \
  && pass "(SW-1) 헬퍼 역참조: SLACK_TOKEN_KEY=MY_HOOK → MY_HOOK webhook 으로 발송" \
  || fail "(SW-1) 헬퍼 역참조 실패: curl url='$CURL_URL'"

# SW-2 GHA 폴백.
run_helper "MY_HOOK" "https://hooks.slack.com/GHA" ""
[ "$CURL_URL" = "https://hooks.slack.com/GHA" ] \
  && pass "(SW-2) GHA 폴백: 토큰키 env 부재면 SLACK_WEBHOOK_URL 로 발송" \
  || fail "(SW-2) GHA 폴백 실패: curl url='$CURL_URL'"

# SW-3 둘 다 없음 → graceful skip.
run_helper "MY_HOOK" "" ""
{ [ "$HELPER_EXIT" -eq 0 ] && [ -z "$CURL_URL" ]; } \
  && pass "(SW-3) 둘 다 미설정 → graceful skip(exit 0, 발송 안 함)" \
  || fail "(SW-3) graceful skip 실패: exit=$HELPER_EXIT curl-url='$CURL_URL'"

# SW-4 빈 SLACK_TOKEN_KEY 가드 + 폴백.
run_helper "" "https://hooks.slack.com/EMPTYKEY" ""
{ [ "$HELPER_EXIT" -eq 0 ] && [ "$CURL_URL" = "https://hooks.slack.com/EMPTYKEY" ]; } \
  && pass "(SW-4) SLACK_TOKEN_KEY 빈 문자열 → 에러 없이 SLACK_WEBHOOK_URL 폴백(가드 동작)" \
  || fail "(SW-4) 빈 토큰키 가드 실패: exit=$HELPER_EXIT curl-url='$CURL_URL' err='$HELPER_ERR'"

# SW-5 레드 입증: 헬퍼 역참조 블록 제거 시 토큰키 시나리오가 발송 안 됨.
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
  [ -z "$broken_url" ] \
    && pass "(SW-5) 레드 입증: 헬퍼 역참조 제거 시 토큰키 시나리오가 발송 안 됨(데드 재현)" \
    || fail "(SW-5) 레드 입증 실패: 역참조 없는데 발송됨 url='$broken_url'"
fi

# SW-6 정적 가드(zsh 회귀 차단): 펜스에 ${! 간접확장 0건(escalation.md 포함 광역).
#   ⚠️ '${!' 패턴은 grep 구현/모드에 따라 매치 여부가 갈린다:
#      - BRE 에서 '$' 가 패턴 끝이 아니면 보통 literal 이지만(BSD grep 은 매치),
#        ugrep -G 등 일부 구현은 '${!' 를 매치 안 함(미탐지 = 가짜 안전망).
#      - 이 레포 셸 환경(zsh)의 grep 래퍼는 ugrep 으로, '${!' 를 BRE 로 못 잡았다.
#      → 구현 무관 결정적 탐지를 위해 반드시 -F(fixed-string) 로 리터럴 매치한다.
#   레드입증(SW-6r)은 두 축으로: (a) 정적 — 스캔이 grep -F 를 쓰는지 소스 단언(구현 무관),
#                              (b) 기능 — 프로브 주입→탐지/제거→통과(이 러너에서 실제 동작).
scan_fences() {
  # $1 = 추가로 스캔할 프로브 파일(옵션). 본체 펜스 + 프로브에서 '${!' 리터럴 검색(-F 필수).
  #   (P3.1) 스캔 대상은 plugin 자산(SKILL·reference)만 — 배포 SSOT 가 SKILL.md 로 일원화돼
  #   templates/claude-commands/*.tmpl 의존을 제거했다. zsh 회귀 광역 차단은 plugin 펜스로 충분.
  grep -rFn '${!' \
    "$REPO_ROOT"/plugin/skills/*/SKILL.md \
    "$REPO_ROOT"/plugin/skills/*/reference/*.md \
    ${1:+"$1"} 2>/dev/null || true
}
FENCE_HITS="$(scan_fences)"
if [ -z "$FENCE_HITS" ]; then
  pass "(SW-6) SKILL·reference 펜스에 \${!} 간접확장 0건(zsh 호환)"
else
  fail "(SW-6) 펜스에 \${!} 간접확장 발견(zsh 깨짐 위험):"
  printf '%s\n' "$FENCE_HITS" | sed 's/^/    ↳ /' >&2
fi

# SW-6r(a) 정적 레드입증 — 스캔이 grep -F(fixed-string)를 쓰는지 소스에서 단언.
#   grep 구현에 무관하게 -F 누락(=앵커/메타문자 함정 재도입)을 결정적으로 잡는다.
#   ⚠️ 파일 전체가 아니라 scan_fences() 함수 본문만 검사한다(이 단언문 자신의 패턴 문자열에
#      self-match 해서 항상 통과하는 가짜 안전망 방지). awk 로 함수 본문만 떼어 grep.
SELF="${BASH_SOURCE[0]}"
SCAN_BODY="$(awk '/^scan_fences\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SELF")"
# 주석이 아닌 실제 grep 호출 줄만(앞공백 후 'grep -r' 로 시작).
SCAN_GREP_LINE="$(printf '%s\n' "$SCAN_BODY" | grep -E '^[[:space:]]*grep -r' || true)"
if printf '%s' "$SCAN_GREP_LINE" | grep -Eq 'grep -r[A-Za-z]*F'; then
  pass "(SW-6r-a) 정적: scan_fences 가 grep -F(fixed-string) 사용(구현 무관 탐지)"
else
  fail "(SW-6r-a) 정적: scan_fences 에 grep -F 누락 — '\${!' 가 grep 구현 따라 미탐지될 위험 (line='$SCAN_GREP_LINE')"
fi

# SW-6r(b) 기능 레드입증 — 프로브에 ${!VAR} 주입 시 탐지, 깨끗하면 미탐지(이 러너에서 동작 확인).
PROBE="$WORK/fence-probe.md"
printf 'fence with ${!SLACK_TOKEN_KEY} indirect expansion\n' > "$PROBE"
injected="$(scan_fences "$PROBE")"
printf 'clean fence line, no indirect expansion here\n' > "$PROBE"
cleaned="$(scan_fences "$PROBE")"
if printf '%s' "$injected" | grep -qF "$PROBE" && ! printf '%s' "$cleaned" | grep -qF "$PROBE"; then
  pass "(SW-6r-b) 기능: \${!VAR} 주입 시 탐지·제거 시 통과"
else
  fail "(SW-6r-b) 기능 실패: 주입 탐지='$injected' / 제거 후='$cleaned'"
fi

# SW-6b escalation.md 펜스가 헬퍼에 SLACK_TOKEN_KEY 를 env 로 넘기는지(역참조 위임 보장).
if grep -qE 'SLACK_TOKEN_KEY="\$SLACK_TOKEN_KEY"' "$ESCALATION"; then
  pass "(SW-6b) escalation.md 펜스가 SLACK_TOKEN_KEY env 를 헬퍼에 전달"
else
  fail "(SW-6b) escalation.md 펜스에 SLACK_TOKEN_KEY env 전달 부재"
fi

# SW-7 헬퍼 shebang 이 bash.
head -1 "$HELPER" | grep -qE '^#!.*bash' \
  && pass "(SW-7) 헬퍼 shebang 이 bash(역참조 \${!} 안전 보장)" \
  || fail "(SW-7) 헬퍼 shebang 이 bash 아님 — \${!} 안전 근거 상실"

# SW-8 공백뿐인 webhook → trim 후 graceful skip(쓰레기 URL 로 curl 안 함).
run_helper "MY_HOOK" "" "   "
{ [ "$HELPER_EXIT" -eq 0 ] && [ -z "$CURL_URL" ]; } \
  && pass "(SW-8) 공백뿐 webhook → trim 후 graceful skip(발송 안 함)" \
  || fail "(SW-8) 공백뿐 webhook 처리 실패: exit=$HELPER_EXIT curl-url='$CURL_URL'"
run_helper "" "   " ""
{ [ "$HELPER_EXIT" -eq 0 ] && [ -z "$CURL_URL" ]; } \
  && pass "(SW-8b) 공백뿐 SLACK_WEBHOOK_URL → trim 후 graceful skip" \
  || fail "(SW-8b) 공백뿐 SLACK_WEBHOOK_URL 처리 실패: exit=$HELPER_EXIT curl-url='$CURL_URL'"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
