#!/usr/bin/env bash
# verdict-write.test.sh — 8-c-bis aggregate.verdict write 단계의 실제 동작 검증 (#54).
#
# 배경(#54 critical): aggregate.verdict(critic 종합 verdict pass|concerns|blocker)를
#   상태파일에 쓰는 실행 단계가 처음부터 없어 항상 초기값 null 로 남았다. critic.yml:423 이
#   null 을 읽어 allowlist 미스 → indeterminate → critic 자동머지 fail-closed(영구 차단).
#
# 이 테스트는 SKILL.md 8-c-bis 에 "문서로 박힌" jq write 명령을 그대로 추출해 실제 적용한다:
#   ① 더미 상태파일(aggregate.verdict=null) 생성
#   ② SKILL.md 8-c-bis 의 jq 트랜잭션을 실행(plugin/tmpl 양쪽 검증은 structure.test.sh 담당)
#   ③ verdict 가 pass|concerns|blocker 로 채워지는지 + criticFindings 동시 기록 단언
#   ④ 레드 입증: write 단계(jq 라인)를 제거하면 verdict 가 null 로 남아 FAIL
#
# 결정적·격리: 임시 디렉토리에서만 작업, 외부 호출 없음(jq 만 사용).
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$TEST_DIR/../SKILL.md"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n" "$1" >&2; }

echo ""
echo -e "${C_CYAN}══ 8-c-bis aggregate.verdict write 동작 테스트 (#54) ══${C_NC}"

command -v jq >/dev/null 2>&1 || { fail "jq 필요(미설치)"; echo "통과 0 실패 1"; exit 1; }
[ -f "$SKILL" ] || { fail "SKILL.md 존재"; echo "통과 0 실패 1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 더미 상태파일 — 초기값(aggregate.verdict=null, criticFindings=[]) 재현.
make_state() {
  cat > "$WORK/state.json" <<'EOF'
{
  "schemaVersion": "1.1",
  "mode": "parent",
  "aggregate": {
    "verdict": null,
    "parentCommentUrl": "https://example/comment",
    "criticFindings": [],
    "completedAt": null
  }
}
EOF
}

# SKILL.md 8-c-bis 의 jq 트랜잭션 라인을 추출(문서가 SSOT — 복사본이 아니라 실제 명령을 실행).
#   8-c-bis 코드펜스 안에서 'jq --arg cv' 로 시작하는 멀티라인 명령을 끝(.json" > "$TEMP")까지 잇는다.
SKILL_8CBIS="$(awk '/^#### 8-c-bis/{f=1; next} f&&/^#### /{exit} f{print}' "$SKILL")"
JQ_FILTER="$(printf '%s\n' "$SKILL_8CBIS" \
  | awk "/jq --arg cv/{c=1} c{print} c&&/mv \"\\\$TEMP\"/{exit}")"

if [ -z "$JQ_FILTER" ]; then
  fail "(VW-0) SKILL 8-c-bis 에서 jq write 명령 추출 — write 단계 부재 의심"
  echo ""; printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"; exit 1
fi
pass "(VW-0) SKILL 8-c-bis jq write 명령 추출 성공"

# 추출한 명령에서 실제 실행할 jq 필터 본문만 뽑는다(문서의 <placeholder> 변수는 우리가 주입).
#   문서 명령의 jq 필터(작은따옴표 안)를 그대로 쓰되, 입력/출력은 테스트가 제어한다.
JQ_BODY="$(printf '%s\n' "$JQ_FILTER" | sed -n "s/.*jq.*'\(.*\)'.*/\1/p")"
# 멀티라인 형태(필터가 다음 줄에 있는 경우)도 처리: 작은따옴표 사이 전체를 추출.
if [ -z "$JQ_BODY" ]; then
  JQ_BODY="$(printf '%s\n' "$JQ_FILTER" | tr '\n' ' ' | sed -n "s/.*jq[^']*'\([^']*\)'.*/\1/p")"
fi
if [ -z "$JQ_BODY" ]; then
  fail "(VW-0b) jq 필터 본문 추출 — 필터가 .aggregate.verdict 세팅을 포함해야 함"
  echo ""; printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"; exit 1
fi
pass "(VW-0b) jq 필터 본문 추출 성공"

# 추출한 jq 필터가 실제로 verdict 를 채우는지 검증 — pass/concerns/blocker 각각.
run_write() {
  local cv="$1" cf="$2"
  make_state
  jq --arg cv "$cv" --argjson cf "$cf" "$JQ_BODY" "$WORK/state.json" > "$WORK/out.json" \
    && mv "$WORK/out.json" "$WORK/state.json"
}

for v in pass concerns blocker; do
  if run_write "$v" '[]'; then
    got="$(jq -r '.aggregate.verdict' "$WORK/state.json")"
    if [ "$got" = "$v" ]; then
      pass "(VW-1) verdict=$v 기록됨(null→$got)"
    else
      fail "(VW-1) verdict=$v 기대인데 '$got'"
    fi
  else
    fail "(VW-1) verdict=$v jq write 실행 실패"
  fi
done

# criticFindings 도 같은 트랜잭션으로 기록되는지(verdict 와 함께).
run_write concerns '[{"severity":"major","area":"cross-area","title":"t","description":"d","affected_prs":[]}]'
cf_len="$(jq '.aggregate.criticFindings | length' "$WORK/state.json")"
cf_v="$(jq -r '.aggregate.verdict' "$WORK/state.json")"
if [ "$cf_len" = "1" ] && [ "$cf_v" = "concerns" ]; then
  pass "(VW-2) verdict+criticFindings 동시 기록(verdict=concerns, findings=1)"
else
  fail "(VW-2) verdict+criticFindings 동시 기록 실패(verdict=$cf_v, findings=$cf_len)"
fi

# 레드 입증: write 가 없으면(필터에서 .aggregate.verdict 대입 제거) verdict 가 null 로 남는다.
BROKEN_BODY="$(printf '%s' "$JQ_BODY" | sed -E 's/\.aggregate\.verdict[[:space:]]*=[[:space:]]*\$cv[[:space:]]*\|?[[:space:]]*//')"
make_state
jq --arg cv "pass" --argjson cf '[]' "$BROKEN_BODY" "$WORK/state.json" > "$WORK/out.json" 2>/dev/null \
  && mv "$WORK/out.json" "$WORK/state.json"
broken_v="$(jq -r '.aggregate.verdict' "$WORK/state.json" 2>/dev/null)"
if [ "$broken_v" = "null" ]; then
  pass "(VW-3) 레드 입증: write 제거 시 verdict 가 null 로 남음(critic.yml fail-closed 재현)"
else
  fail "(VW-3) 레드 입증 실패: write 제거했는데 verdict='$broken_v'(null 기대)"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
