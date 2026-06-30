#!/usr/bin/env bash
# parent-write.test.sh — Step 5 parent 모드 .parent write 단계의 실제 동작 검증 (#94).
#
# 배경(#94 critical, #54 와 동형): /review(생산자)가 parent 모드 상태파일
#   (.pipeline/state/reviews/<slug>.json)을 만들 때 .parent({url, number})를
#   결정적으로 기록하는 실행 단계가 SKILL.md Step 5 에 없었다. 그래서 LLM 이 비결정적으로
#   채우거나 빠뜨려 null 로 남으면, 소비자 critic.yml / resolve-review-statefile.sh 가
#   .parent.url == PARENT_URL 매칭에 실패 → indeterminate → fail-closed 로 머지 영구 차단.
#
# 이 테스트는 SKILL.md Step 5 에 "문서로 박힌" jq write 명령을 그대로 추출해 실제 적용한다
#   (verdict-write.test.sh 와 동일 패턴):
#   ① 더미 상태파일(parent=null, mode="parent") 생성
#   ② SKILL.md Step 5 의 jq 트랜잭션을 실행
#   ③ .parent.url 과 .parent.number 가 채워지는지 단언
#   ④ 레드 입증: write 단계(jq 대입)를 제거하면 parent 가 null 로 남아 FAIL(critic fail-closed 재현)
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
echo -e "${C_CYAN}══ Step 5 parent.write 동작 테스트 (#94) ══${C_NC}"

command -v jq >/dev/null 2>&1 || { fail "jq 필요(미설치)"; echo "통과 0 실패 1"; exit 1; }
[ -f "$SKILL" ] || { fail "SKILL.md 존재"; echo "통과 0 실패 1"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 더미 상태파일 — 초기값(parent=null, mode="parent") 재현.
make_state() {
  cat > "$WORK/state.json" <<'EOF'
{
  "schemaVersion": "1.1",
  "mode": "parent",
  "parent": null,
  "prs": {}
}
EOF
}

# SKILL.md Step 5(### 5. ~ 다음 ### 헤더 전까지) 추출 — 문서가 SSOT(복사본 아닌 실제 명령 실행).
SKILL_STEP5="$(awk '/^### 5\. /{f=1; next} f&&/^### /{exit} f{print}' "$SKILL")"

# Step 5 안에서 'jq --arg pu' 로 시작하는 멀티라인 명령을 끝(mv "$TEMP")까지 잇는다.
JQ_FILTER="$(printf '%s\n' "$SKILL_STEP5" \
  | awk "/jq --arg pu/{c=1} c{print} c&&/mv \"\\\$TEMP\"/{exit}")"

if [ -z "$JQ_FILTER" ]; then
  fail "(PW-0) SKILL Step 5 에서 parent jq write 명령 추출 — write 단계 부재 의심(#94)"
  echo ""; printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"; exit 1
fi
pass "(PW-0) SKILL Step 5 parent jq write 명령 추출 성공"

# PW-0a STATE_FILE 와이어링 정적 확인 (#94 핵심 회귀 함정) — jq 필터 외 와이어링 갭 메움.
#   functional 테스트는 jq 필터만 떼어 검증하므로 STATE_FILE 경로 치환 누락을 못 잡는다.
#   Step 5 parent write 의 STATE_FILE 대입이 라이브 변수 ${SLUG} 인지(리터럴 <slug> 금지) 막는다.
STATE_ASSIGN="$(printf '%s\n' "$SKILL_STEP5" | grep -E 'STATE_FILE=' | grep -E 'reviews/')"
if printf '%s' "$STATE_ASSIGN" | grep -qF '${SLUG}.json' && ! printf '%s' "$STATE_ASSIGN" | grep -qF '<slug>.json'; then
  pass "(PW-0a) SKILL Step 5 STATE_FILE 라이브 변수 \${SLUG}(리터럴 <slug> 부재)"
else
  fail "(PW-0a) SKILL Step 5 STATE_FILE 라이브 변수 \${SLUG}(리터럴 <slug> 부재)"
fi

# 추출한 명령에서 실제 실행할 jq 필터 본문만 뽑는다(문서의 <placeholder> 변수는 우리가 주입).
JQ_BODY="$(printf '%s\n' "$JQ_FILTER" | sed -n "s/.*jq.*'\(.*\)'.*/\1/p")"
# 멀티라인 형태(필터가 다음 줄에 있는 경우)도 처리: 작은따옴표 사이 전체를 추출.
if [ -z "$JQ_BODY" ]; then
  JQ_BODY="$(printf '%s\n' "$JQ_FILTER" | tr '\n' ' ' | sed -n "s/.*jq[^']*'\([^']*\)'.*/\1/p")"
fi
if [ -z "$JQ_BODY" ]; then
  fail "(PW-0b) jq 필터 본문 추출 — 필터가 .parent 세팅을 포함해야 함"
  echo ""; printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"; exit 1
fi
pass "(PW-0b) jq 필터 본문 추출 성공"

# 추출한 jq 필터가 실제로 .parent 를 채우는지 검증.
run_write() {
  local pu="$1" pn="$2"
  make_state
  jq --arg pu "$pu" --argjson pn "$pn" "$JQ_BODY" "$WORK/state.json" > "$WORK/out.json" \
    && mv "$WORK/out.json" "$WORK/state.json"
}

if run_write "https://github.com/Org/Repo/issues/2" "2"; then
  got_url="$(jq -r '.parent.url' "$WORK/state.json")"
  got_num="$(jq -r '.parent.number' "$WORK/state.json")"
  # number 는 정수 타입까지 잠근다 — jq -r 비교만 하면 --argjson(정수)→--arg(문자열) 회귀를
  # "2"=="2" 로 못 잡는다. state-schema 의 parent.number 타입(number) 보장을 테스트가 지킨다.
  num_is_number="$(jq -r '.parent.number | type' "$WORK/state.json")"
  if [ "$got_url" = "https://github.com/Org/Repo/issues/2" ] && [ "$got_num" = "2" ] && [ "$num_is_number" = "number" ]; then
    pass "(PW-1) parent.url·parent.number 기록됨(null→{$got_url, $got_num}, number 타입=number)"
  else
    fail "(PW-1) parent 기록 불일치(url='$got_url', number='$got_num', type='$num_is_number')"
  fi
else
  fail "(PW-1) parent jq write 실행 실패"
fi

# 레드 입증: write 가 없으면(필터에서 .parent 대입 제거) parent 가 null 로 남는다(critic fail-closed 재현).
BROKEN_BODY="$(printf '%s' "$JQ_BODY" | sed -E 's/\.parent[[:space:]]*=[[:space:]]*\{[^}]*\}/./')"
make_state
jq --arg pu "https://github.com/Org/Repo/issues/2" --argjson pn "2" "$BROKEN_BODY" "$WORK/state.json" > "$WORK/out.json" 2>/dev/null \
  && mv "$WORK/out.json" "$WORK/state.json"
broken_v="$(jq -r '.parent' "$WORK/state.json" 2>/dev/null)"
if [ "$broken_v" = "null" ]; then
  pass "(PW-2) 레드 입증: write 제거 시 parent 가 null 로 남음(critic fail-closed 재현)"
else
  fail "(PW-2) 레드 입증 실패: write 제거했는데 parent='$broken_v'(null 기대)"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
