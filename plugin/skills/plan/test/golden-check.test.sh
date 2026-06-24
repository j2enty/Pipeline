#!/usr/bin/env bash
# golden-check.test.sh — check-golden.sh(골든 정답지 보조 대조기)의 자체 테스트 (이슈 #33).
#
# 무엇을 단언하나:
#   (A) good 샘플(필수 키워드 다 포함) → exit 0, 항목 ✅.
#   (B) bad 샘플(필수 키워드 1개 누락) → exit 1, 그 항목 ❌.
#   (C) 마커 없는 임시 expected → 스킵(exit 0).
#   (D) 실제 4종 expected.md smoke — 마커 추출이 되는지(자동 항목 ≥1, 단 precision 표적 G-2 는 0 허용).
#
# structure.test.sh 의 pass/fail·색상·exit 규약 차용. 임시파일은 mktemp + trap 정리.
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$TEST_DIR/check-golden.sh"
FIXTURES="$TEST_DIR/fixtures"

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
# shellcheck disable=SC2329  # trap 으로 간접 호출됨 — shellcheck 가 못 봄.
cleanup() { for f in "${TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap cleanup EXIT
mk() { local f; f="$(mktemp)"; TMPFILES+=("$f"); printf '%s' "$f"; }

echo ""
echo -e "${C_CYAN}══ check-golden.sh 자체 테스트 (이슈 #33) ══${C_NC}"

[ -f "$CHECK" ] || { fail "check-golden.sh 존재"; echo "통과 0 실패 1"; exit 1; }

# 헬퍼: check-golden.sh 를 돌리고 (stdout, exit) 를 잡는다.
#   $1=critic파일 $2=expected파일 → 전역 OUT/RC 에 채운다.
run_check() {
  OUT="$(bash "$CHECK" "$1" "$2" 2>&1)"; RC=$?
}

echo -e "\n${C_CYAN}── (A) good 샘플 → exit 0, 항목 ✅ ──${C_NC}"
# G-3(changelog-feed): 필수 C-1·C-2. 둘 다 포함한 인위적 critic 산출물.
G3="$FIXTURES/changelog-feed.expected.md"
good="$(mk)"
cat > "$good" <<'EOF'
### 명세 보강 가능 (자동 처리 가능)
- /changelog: rate limit 없음 — 무인증 공개라 무한 호출 시 DB 타격.
- /changelog: 응답에 버전·배포 시각을 같이 내릴지 정보 노출 검토 필요.
EOF
run_check "$good" "$G3"
if [ "$RC" -eq 0 ]; then pass "(A) good → exit 0"; else fail "(A) good → exit 0 (실제 $RC)"; fi
case "$OUT" in *"✅ C-1"*) pass "(A) C-1 ✅" ;; *) fail "(A) C-1 ✅ 출력" ;; esac
case "$OUT" in *"✅ C-2"*) pass "(A) C-2 ✅" ;; *) fail "(A) C-2 ✅ 출력" ;; esac

echo -e "\n${C_CYAN}── (B) bad 샘플(필수 1개 누락) → exit 1, 그 항목 ❌ ──${C_NC}"
# C-1(rate limit) 만 있고 C-2(정보 노출 계열) 누락.
bad="$(mk)"
cat > "$bad" <<'EOF'
### 명세 보강 가능 (자동 처리 가능)
- /changelog: rate limit 없음 — 무한 호출 우려.
EOF
run_check "$bad" "$G3"
if [ "$RC" -eq 1 ]; then pass "(B) bad → exit 1"; else fail "(B) bad → exit 1 (실제 $RC)"; fi
case "$OUT" in *"✅ C-1"*) pass "(B) C-1 여전히 ✅" ;; *) fail "(B) C-1 ✅ 출력" ;; esac
case "$OUT" in *"❌ C-2"*) pass "(B) C-2 ❌" ;; *) fail "(B) C-2 ❌ 출력" ;; esac
case "$OUT" in *"미발견: C-2"*) pass "(B) 요약에 미발견 C-2" ;; *) fail "(B) 요약 미발견 C-2" ;; esac

echo -e "\n${C_CYAN}── (C) 마커 없는 expected → 스킵(exit 0) ──${C_NC}"
nomark="$(mk)"
printf '# 마커 없는 정답지\n본문만 있고 golden-check 블록이 없다.\n' > "$nomark"
anycritic="$(mk)"
printf 'rate limit 없음. 버전 노출.\n' > "$anycritic"
run_check "$anycritic" "$nomark"
if [ "$RC" -eq 0 ]; then pass "(C) 마커 없음 → exit 0(스킵)"; else fail "(C) 마커 없음 → exit 0 (실제 $RC)"; fi
case "$OUT" in *"마커 없음"*) pass "(C) '마커 없음' 안내" ;; *) fail "(C) '마커 없음' 안내 출력" ;; esac

echo -e "\n${C_CYAN}── (C2) 인자/파일 오류 → exit 2 ──${C_NC}"
OUT="$(bash "$CHECK" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "(C2) 인자 없음 → exit 2"; else fail "(C2) 인자 없음 → exit 2 (실제 $RC)"; fi
OUT="$(bash "$CHECK" "/nonexistent/critic.txt" "$G3" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "(C2) 없는 critic 파일 → exit 2"; else fail "(C2) 없는 critic 파일 → exit 2 (실제 $RC)"; fi

echo -e "\n${C_CYAN}── (D) 실제 4종 expected.md 마커 smoke ──${C_NC}"
# good 샘플(모든 픽스처 필수 키워드를 한 데 모은 합집합)로 돌려, 마커가 파싱되고
# 자동 항목이 0이 아닌지(precision 표적 G-2 제외) 확인.
allgood="$(mk)"
cat > "$allgood" <<'EOF'
rate limit 없음 — 무인증 공개 엔드포인트.
첫 출범(신규 레포)인 Frontend 초기 스캐폴딩 포함.
정보 노출(버전·배포 시각) 검토.
# [contract] 계약 문서 생성. 공통 규약(snake_case) 통일.
EOF

# G-1·G-C·G-3: 마커 항목이 1개 이상 파싱되어야(스킵 안내가 아니어야) 한다.
for fx in service-status-page cross-area-recipe-card changelog-feed; do
  exp="$FIXTURES/$fx.expected.md"
  if [ ! -f "$exp" ]; then fail "(D) $fx.expected.md 존재"; continue; fi
  run_check "$allgood" "$exp"
  # '발견 N/M' 요약이 떴다 = 항목 ≥1 파싱됨(스킵 아님).
  case "$OUT" in
    *"발견 "*"/"*) pass "(D) $fx 마커 항목 ≥1 파싱" ;;
    *) fail "(D) $fx 마커 항목 ≥1 파싱 (스킵/0개?)" ;;
  esac
done

# G-2: precision 표적 — 마커는 있으나 자동 항목 0개 → 스킵 안내가 떠야 한다.
g2="$FIXTURES/admin-usage-stats.expected.md"
if [ -f "$g2" ]; then
  run_check "$allgood" "$g2"
  case "$OUT" in
    *"자동 보조 항목이 0개"*) pass "(D) G-2(admin-usage-stats) 자동 항목 0개 스킵" ;;
    *) fail "(D) G-2 자동 항목 0개 스킵 안내" ;;
  esac
else
  fail "(D) admin-usage-stats.expected.md 존재"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; else echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; fi
