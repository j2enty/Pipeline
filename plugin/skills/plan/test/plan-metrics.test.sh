#!/usr/bin/env bash
# plan-metrics.test.sh — plan-metrics.sh(단계별 소요시간·토큰 계측) 단위 테스트 (이슈 #83).
#
# 무엇을 단언하나(시간 계산·포맷 로직을 분리한 스크립트라 결정적으로 검증 가능):
#   (A) fmt-duration: epoch 쌍 → 사람용 포맷("3m12s"·"4m05s"·"2h..")·0초·역행("?")·비정수("?").
#   (B) mark+report: start/end 쌍 → 정확한 소요초 표시, 합계 누적.
#   (C) 누락 단계(start 만 / end 만 / 역행) → "(미측정)" 로 방어, 합계엔 미반영.
#   (D) token: 정수만 기록, 비정수(추정·미표기)는 조용히 스킵.
#   (E) report-comment: 마크다운 표 + 데이터 없으면 빈 출력(호출자가 코멘트 스킵).
#   (F) 빈/없는 TSV → 크래시 없이 안내 + exit 0.
#
# structure.test.sh 의 pass/fail·색상·exit 규약 차용. 임시파일은 mktemp + trap 정리.
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="$TEST_DIR/../scripts/plan-metrics.sh"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n" "$1" >&2; }

# 임시파일 정리 — trap 으로 보장.
TMPFILES=()
# shellcheck disable=SC2329  # trap 으로 간접 호출됨.
cleanup() { for f in "${TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap cleanup EXIT
mk() { local f; f="$(mktemp)"; TMPFILES+=("$f"); printf '%s' "$f"; }

# 출력 동등/포함 단언.
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대='$1' 실제='$2')"; fi
}
assert_has() {
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (출력에 '$2' 없음)" ;; esac
}
assert_absent() {
  case "$1" in *"$2"*) fail "$3 (출력에 '$2' 있음)" ;; *) pass "$3" ;; esac
}

echo ""
echo -e "${C_CYAN}══ plan-metrics.sh 단위 테스트 (이슈 #83) ══${C_NC}"

[ -f "$METRICS" ] || { fail "plan-metrics.sh 존재"; echo "통과 0 실패 1"; exit 1; }

echo -e "\n${C_CYAN}── (A) fmt-duration 포맷 ──${C_NC}"
assert_eq "3m12s"     "$(bash "$METRICS" fmt-duration 1000 1192)" "(A) 192s → 3m12s"
assert_eq "4m05s"     "$(bash "$METRICS" fmt-duration 1000 1245)" "(A) 245s → 4m05s (zero-pad 초)"
assert_eq "0s"        "$(bash "$METRICS" fmt-duration 1000 1000)" "(A) 0s"
assert_eq "59s"       "$(bash "$METRICS" fmt-duration 1000 1059)" "(A) 59s (분 미만)"
assert_eq "2h10m00s"  "$(bash "$METRICS" fmt-duration 1000 8800)" "(A) 7800s → 2h10m00s"
assert_eq "?"         "$(bash "$METRICS" fmt-duration 1192 1000)" "(A) 역행(end<start) → ?"
assert_eq "?"         "$(bash "$METRICS" fmt-duration abc 1000)"  "(A) 비정수 start → ?"
assert_eq "?"         "$(bash "$METRICS" fmt-duration 1000 '')"   "(A) 빈 end → ?"
# fmt-seconds 직접 — 누적 합계 포맷에 쓰는 경로.
assert_eq "1m00s"     "$(bash "$METRICS" fmt-seconds 60)"   "(A) fmt-seconds 60 → 1m00s"
assert_eq "?"         "$(bash "$METRICS" fmt-seconds -5)"   "(A) fmt-seconds 음수 → ?"

echo -e "\n${C_CYAN}── (B) mark+report 소요시간·합계 ──${C_NC}"
# 실시간 date 의존을 피하려고 TSV 를 직접 만들어 집계 로직만 검증(결정적).
t="$(mk)"
{
  printf 'time\tplanner\tstart\t1000\n'
  printf 'time\tplanner\tend\t1192\n'              # 192s = 3m12s
  printf 'time\tcompleteness-critic\tstart\t2000\n'
  printf 'time\tcompleteness-critic\tend\t2245\n'  # 245s = 4m05s
} > "$t"
out="$(bash "$METRICS" report "$t")"
assert_has "$out" "3m12s" "(B) planner 3m12s 표시"
assert_has "$out" "4m05s" "(B) completeness-critic 4m05s 표시"
# 합계 192+245=437s = 7m17s
assert_has "$out" "7m17s" "(B) 합계 7m17s"

echo -e "\n${C_CYAN}── (C) 누락 단계 방어 ──${C_NC}"
t2="$(mk)"
{
  printf 'time\tplanner\tstart\t1000\n'
  printf 'time\tplanner\tend\t1100\n'                 # 100s = 1m40s (정상)
  printf 'time\tconsistency-critic\tstart\t2000\n'    # end 누락
  printf 'time\tcodex-crosscheck\tstart\t3500\n'
  printf 'time\tcodex-crosscheck\tend\t3000\n'        # 역행
} > "$t2"
out2="$(bash "$METRICS" report "$t2")"
assert_has "$out2" "1m40s"   "(C) 정상 단계 1m40s"
assert_has "$out2" "(미측정)" "(C) 누락/역행 단계 (미측정) 표시"
# 합계는 정상 구간만(100s = 1m40s) — 누락 단계는 합산 안 됨.
assert_has "$out2" "합계" "(C) 합계 행 존재"
# 합계가 1m40s 인지(누락 단계가 0 이나 음수로 새지 않았는지).
case "$out2" in *"합계(측정 구간)      1m40s"*|*"합계(측정 구간) 1m40s"*) pass "(C) 합계=정상구간만(1m40s)" ;; *)
  # 공백 정렬 변동 대비 — '합계' 줄에 1m40s 가 있고 다른 시간이 안 섞였는지 느슨 검증.
  case "$out2" in *"합계"*"1m40s"*) pass "(C) 합계=정상구간만(1m40s)" ;; *) fail "(C) 합계=정상구간만(1m40s)" ;; esac ;;
esac

echo -e "\n${C_CYAN}── (D) token 기록(정수만) ──${C_NC}"
t3="$(mk)"
bash "$METRICS" mark "$t3" planner start
bash "$METRICS" mark "$t3" planner end
bash "$METRICS" token "$t3" planner in 53120
bash "$METRICS" token "$t3" planner out 8400
bash "$METRICS" token "$t3" planner in "추정불가"   # 비정수 → 스킵돼야
bash "$METRICS" token "$t3" planner out ""          # 빈 값 → 스킵
out3="$(bash "$METRICS" report "$t3")"
assert_has "$out3" "53120" "(D) 정수 in 토큰 기록됨"
assert_has "$out3" "8400"  "(D) 정수 out 토큰 기록됨"
assert_absent "$out3" "추정불가" "(D) 비정수 토큰은 기록 안 됨"
# TSV 에 비정수 token 줄이 안 들어갔는지 직접 확인.
assert_absent "$(cat "$t3")" "추정불가" "(D) TSV 에도 비정수 미기록"

echo -e "\n${C_CYAN}── (E) report-comment 마크다운 ──${C_NC}"
oc="$(bash "$METRICS" report-comment "$t3")"
assert_has "$oc" "📊 plan timing"      "(E) 코멘트 헤더"
assert_has "$oc" "| 단계 | 소요 |"      "(E) 마크다운 표 헤더"
assert_has "$oc" "53120"               "(E) 토큰 표시"
# 데이터 없는 TSV → 빈 출력(호출자가 코멘트 스킵).
empty="$(mk)"
oc_empty="$(bash "$METRICS" report-comment "$empty")"
assert_eq "" "$oc_empty" "(E) 빈 TSV → 빈 코멘트(스킵)"

echo -e "\n${C_CYAN}── (F) 빈/없는 TSV 방어 ──${C_NC}"
re="$(bash "$METRICS" report "$empty"; echo "rc=$?")"
assert_has "$re" "계측 데이터 없음" "(F) 빈 TSV report 안내"
assert_has "$re" "rc=0"            "(F) 빈 TSV report exit 0"
rn="$(bash "$METRICS" report /no/such/plan-metrics.tsv; echo "rc=$?")"
assert_has "$rn" "rc=0" "(F) 없는 TSV report exit 0(크래시 없음)"
# 인자 오류 → exit 2.
bash "$METRICS" mark "$empty" planner bogus >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "(F) mark phase 오류 → exit 2"
bash "$METRICS" bogus-subcmd >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "(F) 알 수 없는 서브커맨드 → exit 2"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; else echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; fi
