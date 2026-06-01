#!/usr/bin/env bash
# dry-run-guard.negative.test.sh — dry-run-guard.test.sh 의 음성(negative) 회귀 테스트.
#
# 목적:
#   안전망(dry-run-guard.test.sh) 자체가 실제 위반을 잡는지 검증한다.
#   plan.md.tmpl 의 코드펜스에 위반을 주입한 임시 사본을 만들어
#   dry-run-guard.test.sh 가 FAIL(exit 1)을 내는지 단언한다.
#
# 음성 케이스:
#   [기존 c-old — 보조 정지선 앞 bash 펜스에 쓰기 주입]
#   1. gh issue edit    4. git push        7. git -C Docs push
#   2. gh pr create     5. git commit      8. gh api -f 암묵 POST (G1)
#   3. gh issue create  6. gh label create 9. ```sh 펜스에 숨긴 gh pr create (G2)
#
#   [c-new — self-guard 제거]
#   10. Step 6b 펜스에서 self-guard 줄을 제거한 사본 → FAIL
#   11. Step 7  펜스에서 self-guard 줄을 제거한 사본 → FAIL
#   12. Step 8  펜스에서 self-guard 줄을 제거한 사본 → FAIL
#   13. Step 9  펜스에서 self-guard 줄을 제거한 사본 → FAIL
#
# baseline: 주입 없음 → PASS 확인.
#
# 격리 원칙:
#   - 임시 사본은 mktemp -d 로 생성, 테스트 종료 시 자동 정리.
#   - 실제 레포 파일·원격 절대 건드리지 않음. 순수 로컬 텍스트 조작.
#   - gh·git 등 외부 호출 없음.

set -uo pipefail

# ── 경로 ────────────────────────────────────────────────────────────────────
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$TEST_DIR/dry-run-guard.test.sh"
TEMPLATE="$TEST_DIR/../plan.md.tmpl"

# ── 색상 ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

FAILED=0
pass_neg() { printf "${C_GREEN}✓ PASS${C_NC} %s\n" "$1"; }
fail_neg() { printf "${C_RED}✗ FAIL${C_NC} %s\n" "$1"; FAILED=1; }

if [ ! -f "$TEMPLATE" ] || [ ! -f "$GUARD_SH" ]; then
  printf "${C_RED}✗ 필수 파일 없음: %s 또는 %s${C_NC}\n" "$TEMPLATE" "$GUARD_SH"
  exit 1
fi

printf "${C_CYAN}══ dry-run 가드 음성(negative) 회귀 테스트 ══${C_NC}\n\n"

# ── 주입 위치 ────────────────────────────────────────────────────────────────
# 보조 정지선보다 앞 bash 펜스(Step 2)에 위반 명령을 삽입한다.
INJECT_ANCHOR='ISSUE_JSON=$(cat "$ISSUE_FIXTURE")'

# ── 헬퍼: bash 펜스 안으로 한 줄 주입 후 가드 실행 ──────────────────────────
run_negative_bash() {
  local label="$1" evil_cmd="$2"
  local tmpdir; tmpdir="$(mktemp -d)"
  python3 - "$TEMPLATE" "$tmpdir/plan.md.tmpl" "$INJECT_ANCHOR" "$evil_cmd" <<'PYEOF'
import sys
src, dst, anchor, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(src).readlines()
out = []
for l in lines:
    out.append(l)
    if anchor in l:
        out.append(cmd + '\n')
open(dst, 'w').writelines(out)
PYEOF
  local code=0
  TEMPLATE="$tmpdir/plan.md.tmpl" bash "$GUARD_SH" >/dev/null 2>&1 || code=$?
  rm -rf "$tmpdir"
  if [ "$code" -ne 0 ]; then
    pass_neg "FAIL(exit $code) 예상대로 잡힘 — $label"
  else
    fail_neg "PASS(exit 0) — 잡혀야 할 위반을 통과시킴 — $label"
  fi
}

# ── 헬퍼: ```sh 펜스 블록을 앵커 뒤에 삽입 (G2 테스트용) ────────────────────
run_negative_sh_fence() {
  local label="$1" evil_cmd="$2"
  local tmpdir; tmpdir="$(mktemp -d)"
  python3 - "$TEMPLATE" "$tmpdir/plan.md.tmpl" "$INJECT_ANCHOR" "$evil_cmd" <<'PYEOF'
import sys
src, dst, anchor, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(src).readlines()
out = []
for l in lines:
    out.append(l)
    if anchor in l:
        out.append('```sh\n')
        out.append(cmd + '\n')
        out.append('```\n')
open(dst, 'w').writelines(out)
PYEOF
  local code=0
  TEMPLATE="$tmpdir/plan.md.tmpl" bash "$GUARD_SH" >/dev/null 2>&1 || code=$?
  rm -rf "$tmpdir"
  if [ "$code" -ne 0 ]; then
    pass_neg "FAIL(exit $code) 예상대로 잡힘 — $label"
  else
    fail_neg "PASS(exit 0) — 잡혀야 할 위반을 통과시킴 — $label"
  fi
}

# ── 헬퍼: self-guard 줄을 제거한 사본으로 가드 실행 (c-new 테스트용) ─────────
# self-guard 시그니처: case " $ARGUMENTS " in *" --dry-run "*) ... exit 0
# 해당 줄을 제거한 사본이 FAIL(exit 1) 나는지 확인.
run_negative_remove_guard() {
  local label="$1" anchor_phrase="$2"
  local tmpdir; tmpdir="$(mktemp -d)"
  python3 - "$TEMPLATE" "$tmpdir/plan.md.tmpl" "$anchor_phrase" <<'PYEOF'
import sys
src, dst, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).readlines()
# self-guard 시그니처: case " $ARGUMENTS " in *" --dry-run "*)
# anchor_phrase 가 포함된 펜스의 self-guard 줄(시그니처 포함)을 제거한다.
# 단순화: 파일 전체에서 첫 번째로 anchor_phrase 가 나온 뒤 가장 가까운 self-guard 줄 제거
found_anchor = False
removed = False
out = []
for l in lines:
    if not found_anchor and anchor in l:
        found_anchor = True
    if found_anchor and not removed and 'case " $ARGUMENTS "' in l and '--dry-run' in l:
        removed = True   # 이 줄을 제거(출력 안 함)
        continue
    out.append(l)
open(dst, 'w').writelines(out)
PYEOF
  local code=0
  TEMPLATE="$tmpdir/plan.md.tmpl" bash "$GUARD_SH" >/dev/null 2>&1 || code=$?
  rm -rf "$tmpdir"
  if [ "$code" -ne 0 ]; then
    pass_neg "FAIL(exit $code) 예상대로 잡힘 — $label"
  else
    fail_neg "PASS(exit 0) — 잡혀야 할 위반을 통과시킴 — $label"
  fi
}

# ── baseline: 주입 없음 → PASS 확인 ─────────────────────────────────────────
printf "  baseline(주입 없음):\n"
base_code=0
TEMPLATE="$TEMPLATE" bash "$GUARD_SH" >/dev/null 2>&1 || base_code=$?
if [ "$base_code" -eq 0 ]; then
  pass_neg "baseline — 주입 없음 → PASS (가드 자체는 정상)"
else
  fail_neg "baseline — 주입 없음인데 FAIL (가드 오탐, 수정 필요)"
fi

# ── c-old: 보조 정지선 앞 bash/sh 펜스에 쓰기 주입 ───────────────────────────
printf "\n  [c-old] 보조 정지선 앞 bash 펜스 쓰기 주입 9종:\n"
run_negative_bash "1. gh issue edit"                "gh issue edit 42 --repo org/repo --body x"
run_negative_bash "2. gh pr create"                 "gh pr create --title evil --body x"
run_negative_bash "3. gh issue create"              "gh issue create --repo org/repo --title evil"
run_negative_bash "4. git push"                     "git push -u origin plan/slug"
run_negative_bash "5. git commit"                   "git commit -m 'evil'"
run_negative_bash "6. gh label create"              "gh label create evil --repo org/repo --color 000000"
run_negative_bash "7. git -C Docs push"             "git -C Docs push origin plan/slug"
run_negative_bash "8. gh api -f 암묵 POST (G1)"     "gh api /repos/org/repo/issues -f title=evil"
run_negative_sh_fence "9. \`\`\`sh 펜스 gh pr create (G2)" "gh pr create --title evil --body x"

# ── c-new: self-guard 제거 → FAIL 확인 ───────────────────────────────────────
# 각 단계의 bash 펜스에서 [R2 self-guard] 줄을 제거하면 (c-new) 가 FAIL 해야 한다.
# anchor_phrase: 해당 펜스를 특정하는 고유 문자열(self-guard 줄 바로 앞 주석 또는 뒷 줄)
printf "\n  [c-new] self-guard 제거 4종(→ FAIL 기대):\n"
run_negative_remove_guard \
  "10. Step 6b self-guard 제거" \
  "Step 6b(git/PR) 원격 반영 스킵"
run_negative_remove_guard \
  "11. Step 7 self-guard 제거" \
  "Step 7(sub-issue 생성) 원격 반영 스킵"
run_negative_remove_guard \
  "12. Step 8 self-guard 제거" \
  "Step 8(Project 세팅) 원격 반영 스킵"
run_negative_remove_guard \
  "13. Step 9 self-guard 제거" \
  "Step 9(parent 본문 업데이트) 원격 반영 스킵"

# R5-1: Step 9.5 self-guard 제거
run_negative_remove_guard \
  "14. Step 9.5 self-guard 제거" \
  "Step 9.5(자가 검증 보정) 원격 반영 스킵"

# R5-2: 감싼-쓰기(명령치환 래핑) 탐지 — self-guard 없는 펜스에
#        X=$(gh issue create ...) 형태만 주입해도 FAIL 나는지(R4 탐지기 검증)
printf "\n  [R4/R5-2] 감싼-쓰기 래핑 탐지:\n"
run_negative_bash \
  "15. 명령치환 래핑 X=\$(gh issue create) — R4 탐지기 검증" \
  "X=\$(gh issue create --repo org/repo --title evil)"

# ── 집계 ────────────────────────────────────────────────────────────────────
printf "\n${C_CYAN}══════════════════════════════${C_NC}\n"
if [ "$FAILED" -eq 0 ]; then
  printf "${C_GREEN}전체 PASS — 안전망이 모든 위반 패턴을 잡음${C_NC}\n"
  exit 0
else
  printf "${C_RED}FAIL — 위 항목 확인 필요 (잡지 못한 위반 존재)${C_NC}\n"
  exit 1
fi
