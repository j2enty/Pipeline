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
#   (G) report-file: 데이터 있으면 파일 생성(표 마커 포함), 데이터 없으면 파일 미생성(빈 timing.md 방지),
#       파일 내용이 report-comment stdout 과 동일.
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

echo -e "\n${C_CYAN}── (D2) reset 으로 누적 오염 차단 ──${C_NC}"
# 잔여 TSV(이전 중단 실행) 위에 reset 없이 또 token 을 쌓으면 합산돼 부풀려지는 회귀를
# reset 이 막는지 검증. reset 후 단일 실행분만 남아야 한다.
t4="$(mk)"
bash "$METRICS" token "$t4" planner in 100   # 잔여(옛 실행)
bash "$METRICS" token "$t4" planner in 100   # 잔여
# 새 실행 — 첫 펜스에서 reset 하면 옛 200 이 사라지고 50 만 남아야 한다.
bash "$METRICS" reset "$t4"
bash "$METRICS" mark "$t4" planner start
bash "$METRICS" mark "$t4" planner end
bash "$METRICS" token "$t4" planner in 50
out4="$(bash "$METRICS" report "$t4")"
assert_has   "$out4" "50"  "(D2) reset 후 새 토큰(50) 표시"
# 200(=100+100 누적) 이 남으면 안 됨.
assert_absent "$out4" "200" "(D2) reset 이 옛 누적 토큰(200) 제거"
# reset 직후 TSV 는 비어 있어야(누적분 제거) — 이후 append 만 들어감.
e2="$(mk)"; printf 'token\tplanner\tin\t999\n' > "$e2"
bash "$METRICS" reset "$e2"
assert_eq "" "$(cat "$e2")" "(D2) reset → TSV 비워짐(truncate)"

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

echo -e "\n${C_CYAN}── (G) report-file 파일 보존 ──${C_NC}"
# (G1) 데이터 있는 TSV → 파일 생성 + report-comment 와 동일한 표 마커 포함.
g1out="$(mk)"   # mktemp 가 만든 빈 파일 — report-file 이 덮어쓴다.
bash "$METRICS" report-file "$t3" "$g1out"; rc=$?
assert_eq "0" "$rc" "(G1) report-file exit 0"
[ -f "$g1out" ] && pass "(G1) 데이터 있으면 파일 생성됨" || fail "(G1) 데이터 있으면 파일 생성됨"
g1content="$(cat "$g1out")"
assert_has "$g1content" "📊 plan timing" "(G1) 파일에 표 헤더 마커"
assert_has "$g1content" "53120"          "(G1) 파일에 토큰 값 포함"
# (G2) 데이터 없는 TSV → 파일 미생성(빈 timing.md 커밋 방지) + exit 0.
g2out="${TMPDIR:-/tmp}/plan-metrics-g2-$$.md"
rm -f "$g2out"; TMPFILES+=("$g2out")   # 존재하지 않는 경로에서 시작 + 정리 등록.
bash "$METRICS" report-file "$empty" "$g2out"; rc=$?
assert_eq "0" "$rc" "(G2) 빈 TSV report-file exit 0"
[ ! -f "$g2out" ] && pass "(G2) 데이터 없으면 파일 미생성" || fail "(G2) 데이터 없으면 파일 미생성"
# (G3) 파일 내용 == report-comment stdout (동일 렌더러 재사용 확인).
assert_eq "$(bash "$METRICS" report-comment "$t3")" "$g1content" "(G3) 파일 == report-comment stdout"
# (G4) tsv 인자 누락 → exit 2.
bash "$METRICS" report-file >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "(G4) tsv 누락 → exit 2"
# (G5) out 인자 누락(tsv 만 줌) → exit 2.
bash "$METRICS" report-file "$t3" >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "(G5) out 누락 → exit 2"
# (G6) 원자적 쓰기 — 정상 생성(G1) 후 이 out 의 임시파일($g1out.tmp.*)이 남지 않아야(성공 시 mv 가 소모).
#   공유 temp 디렉토리의 무관한 *.tmp.* 오탐을 피하려 정확히 이 out 경로 접두로만 스코핑한다.
leftover="$(ls "$g1out".tmp.* 2>/dev/null)"
assert_eq "" "$leftover" "(G6) 잔여 임시파일($g1out.tmp.*) 없음"

echo -e "\n${C_CYAN}── (H) cost-snapshot 비용 계측 (이슈 #92) ──${C_NC}"
# provider 를 주입(PLAN_COST_PROVIDER)해 ccusage 네트워크 의존 없이 결정적으로 검증한다.
# 시나리오: start=$12.5010(in 80000/out 6000/cache_read 180000/cache_create 150000),
#           end  =$12.9230(in 88076/out 6639/cache_read 198571/cache_create 165287)
#  → 델타 cost $0.4220 / in 8,076 / out 639 / cache r18,571·w15,287
hc="$(mk)"
PLAN_COST_PROVIDER='echo "cost 12.5010 in 80000 out 6000 cache_read 180000 cache_create 150000"' \
  bash "$METRICS" cost-snapshot "$hc" start
PLAN_COST_PROVIDER='echo "cost 12.9230 in 88076 out 6639 cache_read 198571 cache_create 165287"' \
  bash "$METRICS" cost-snapshot "$hc" end
bash "$METRICS" mark "$hc" planner start
bash "$METRICS" mark "$hc" planner end
hc_out="$(bash "$METRICS" report-comment "$hc")"
assert_has "$hc_out" '📊 usage (plan)' "(H1) usage 줄 존재"
assert_has "$hc_out" 'cost $0.4220'    "(H1) 델타 비용 정확(12.9230-12.5010)"
assert_has "$hc_out" 'in 8,076·out 639 tok' "(H1) 델타 토큰 정확 + 천단위 콤마"
assert_has "$hc_out" 'cache r18,571·w15,287' "(H1) cache 델타 정확"
# (H2) cost 스냅샷 행이 가짜 단계(start/end)로 timing 표에 새지 않는다.
assert_absent "$hc_out" "| start |" "(H2) cost 행이 timing 단계로 안 샘(start)"
assert_absent "$hc_out" "| end |"   "(H2) cost 행이 timing 단계로 안 샘(end)"
assert_has    "$hc_out" "planner"   "(H2) 진짜 단계(planner)는 표에 존재"
# (H3) 비용 스냅샷 없음 → usage 줄 생략(timing 표만).
hc3="$(mk)"
bash "$METRICS" mark "$hc3" planner start; bash "$METRICS" mark "$hc3" planner end
hc3_out="$(bash "$METRICS" report-comment "$hc3")"
assert_absent "$hc3_out" '📊 usage (plan)' "(H3) 비용 없으면 usage 줄 생략"
assert_has    "$hc3_out" '📊 plan timing'  "(H3) 시간 표는 그대로"
# (H4) provider 실패(비0) → 스냅샷 스킵(TSV 에 cost 행 미기록) + exit 0.
hc4="$(mk)"
PLAN_COST_PROVIDER='exit 1' bash "$METRICS" cost-snapshot "$hc4" start; rc=$?
assert_eq "0" "$rc" "(H4) provider 실패해도 exit 0(best-effort)"
assert_absent "$(cat "$hc4")" "cost" "(H4) provider 실패 시 cost 행 미기록"
# (H5) 잘못된 when → exit 2.
bash "$METRICS" cost-snapshot "$hc4" middle >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "(H5) when 이 start|end 아니면 exit 2"
# (H6) tsv 인자 누락 → exit 2.
bash "$METRICS" cost-snapshot >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "(H6) tsv 누락 → exit 2"
# (H7) 음수 비용(스냅샷 역순·이상) → usage 줄 생략(오해 방지).
hc7="$(mk)"
PLAN_COST_PROVIDER='echo "cost 13.0 in 100 out 10 cache_read 0 cache_create 0"' \
  bash "$METRICS" cost-snapshot "$hc7" start
PLAN_COST_PROVIDER='echo "cost 12.0 in 90 out 5 cache_read 0 cache_create 0"' \
  bash "$METRICS" cost-snapshot "$hc7" end
bash "$METRICS" mark "$hc7" planner start; bash "$METRICS" mark "$hc7" planner end
assert_absent "$(bash "$METRICS" report-comment "$hc7")" '📊 usage (plan)' "(H7) 음수 비용 → usage 줄 생략"
# (H8) cache 0 → cache 표기 생략(잡음 제거).
hc8="$(mk)"
PLAN_COST_PROVIDER='echo "cost 1.0 in 100 out 10 cache_read 0 cache_create 0"' \
  bash "$METRICS" cost-snapshot "$hc8" start
PLAN_COST_PROVIDER='echo "cost 1.5 in 200 out 20 cache_read 0 cache_create 0"' \
  bash "$METRICS" cost-snapshot "$hc8" end
hc8_out="$(bash "$METRICS" report-comment "$hc8")"
assert_has    "$hc8_out" 'cost $0.5000' "(H8) cache 없어도 cost 렌더"
assert_absent "$hc8_out" 'cache r'      "(H8) cache 0 이면 cache 표기 생략"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; else echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; fi
