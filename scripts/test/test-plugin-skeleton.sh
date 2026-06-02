#!/usr/bin/env bash
# test-plugin-skeleton.sh — Pipeline 플러그인 뼈대 + 에이전트 게이트 (P1)
#
# 검증 대상:
#   1. 매니페스트 2개(.claude-plugin/plugin.json·marketplace.json) 존재 + JSON 유효
#   2. claude plugin validate (claude CLI 있을 때만):
#        - marketplace(레포 루트): 비-strict + --strict 둘 다 통과
#        - plugin(plugin/ 서브디렉토리): 비-strict + --strict 둘 다 통과
#          (플러그인 루트가 레포 루트 밖이라 CLAUDE.md 경고 없음 → strict 깨끗)
#   3. 에이전트 2개(plugin/agents/critic.md·planner.md) 존재
#   4. 에이전트 frontmatter 필수필드(name·description) 보유 + name 일치
#      ← claude plugin validate 는 매니페스트만 보고 에이전트 frontmatter 는
#        검증하지 않으므로(실측), 이 사각지대를 직접 메운다.
#   5. 파서 음성 self-test — frontmatter 파서가 깨진 에이전트를 실제로 떨어뜨리는지.
#
# 설계: 독립 실행 스크립트(install.sh source 모델이 아님 — 순수 파일·CLI 검증).
#   claude CLI 가 없으면 validate 항목만 SKIP 하고 나머지는 그대로 검사
#   (CI 에 claude 미설치여도 파일·frontmatter 게이트는 작동).
#
# 사용법: scripts/test/test-plugin-skeleton.sh
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

# ── 색상 ─────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_NC=''
fi

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "${C_RED}✗${C_NC} %s\n    %s\n" "$1" "${2:-}" >&2; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf "${C_YELLOW}–${C_NC} %s (SKIP: %s)\n" "$1" "${2:-}"; }

# ── frontmatter 필드 추출 — <file> <key> ─────────────────────
# 첫 `---` … `---` 블록 안에서만 `key:` 를 찾는다.
# 닫는 `---` 가 없는(깨진) frontmatter 는 키를 못 찾은 것으로 간주해 실패시킨다.
#   ← awk 가 매치 없이 끝까지 가면 기본 exit 0(=성공)이 되어, 닫는 `---` 없는
#     파일이 "키 있음"으로 거짓 통과하던 버그를 END 블록으로 차단(Codex 지적).
frontmatter_has_key() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR==1 && $0!="---" { exit 1 }      # frontmatter 시작(--- ) 아니면 실패
    NR==1 { infm=1; next }
    infm && $0=="---" { exit 1 }       # 닫는 --- 도달, 키 못 찾음 → 실패
    infm && $0 ~ "^"k":" { found=1; exit 0 }  # 키 발견 → 성공
    END { if (!found) exit 1 }         # EOF(닫는 --- 부재 포함) → 실패
  ' "$file"
}

# frontmatter 스칼라 값 추출(한 줄 스칼라 전용) — <file> <key>
#   - 매칭 앵커는 has_key 와 동일(`^key:`)하게 맞춰 둘의 판정이 어긋나지 않게 한다.
#   - 값이 접힘/블록 스칼라 지시자(`>-` `>` `|` `|-` 등)면 실제 값은 다음 줄들에
#     있으므로 한 줄 스칼라가 아니다 → 지시자 리터럴을 반환하지 않고 빈 문자열 반환.
#   - 닫는 --- 부재/키 부재면 빈 문자열(awk 기본). 값 비교 측에서 불일치로 잡힘.
frontmatter_value() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ "^"k":" {
      sub("^"k":[ \t]*", "")
      if ($0 ~ /^[>|][+-]?[ \t]*$/) { print ""; exit }   # 접힘/블록 스칼라 → 빈 값
      gsub(/^[ \t"\x27]+|[ \t"\x27]+$/, ""); print; exit
    }
  ' "$file"
}

echo ""
echo -e "${C_CYAN}══ Pipeline 플러그인 뼈대 테스트 (P1) ══${C_NC}"

# ── 1. 매니페스트 존재 + JSON 유효 ───────────────────────────
# 격리 구조: 마켓플레이스는 레포 루트, 플러그인은 plugin/ 서브디렉토리.
PLUGIN_DIR="$REPO_ROOT/plugin"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

for f in "$PLUGIN_JSON" "$MARKETPLACE_JSON"; do
  name="${f#"$REPO_ROOT"/}"
  if [ ! -f "$f" ]; then
    fail "$name 존재" "파일 없음"
  elif ! python3 -m json.tool "$f" >/dev/null 2>&1; then
    fail "$name JSON 유효" "JSON 파싱 실패"
  else
    pass "$name 존재 + JSON 유효"
  fi
done

# plugin.json name == "pipeline" (프레임워크명 — 프로젝트 식별자 아님)
if [ -f "$PLUGIN_JSON" ]; then
  pname="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('name',''))" "$PLUGIN_JSON" 2>/dev/null)"
  if [ "$pname" = "pipeline" ]; then
    pass "plugin.json name == 'pipeline'"
  else
    fail "plugin.json name == 'pipeline'" "실제='$pname'"
  fi
fi

# marketplace.json 이 pipeline 플러그인을 source './plugin' 으로 등록했나
if [ -f "$MARKETPLACE_JSON" ]; then
  src="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
ps=[p for p in d.get('plugins',[]) if p.get('name')=='pipeline']
print(ps[0].get('source','') if ps else 'MISSING')
" "$MARKETPLACE_JSON" 2>/dev/null)"
  if [ "$src" = "./plugin" ]; then
    pass "marketplace.json 이 pipeline 을 source './plugin' 으로 등록"
  else
    fail "marketplace.json pipeline source == './plugin'" "실제='$src'"
  fi
fi

# ── 2. claude plugin validate (CLI 있을 때만) ────────────────
# 격리 구조: 마켓플레이스(레포 루트)와 플러그인(plugin/)을 각각 검증한다.
#   `claude plugin validate <레포>` 는 매니페스트가 둘 다 있으면 marketplace.json
#   만 검증하므로(plugin.json·컴포넌트 안 봄), 플러그인은 plugin/ 경로로 따로 본다.
#   플러그인 루트가 레포 루트 밖이라 CLAUDE.md 경고가 없어 --strict 까지 깨끗하다.
if command -v claude >/dev/null 2>&1; then
  # marketplace (레포 루트) — 비-strict + --strict 둘 다 깨끗
  if claude plugin validate "$REPO_ROOT" >/dev/null 2>&1; then
    pass "claude plugin validate . (marketplace)"
  else
    fail "claude plugin validate . (marketplace)" "exit != 0"
  fi
  if claude plugin validate "$REPO_ROOT" --strict >/dev/null 2>&1; then
    pass "claude plugin validate . --strict (marketplace)"
  else
    fail "claude plugin validate . --strict (marketplace)" "exit != 0 (미인식 필드·메타 누락)"
  fi
  # plugin (plugin/) — 비-strict + --strict 둘 다 깨끗(격리로 CLAUDE.md 경고 제거).
  #   컴포넌트 frontmatter 는 validate 가 안 보므로 아래 3·4 항목이 보완.
  if claude plugin validate "$PLUGIN_DIR" >/dev/null 2>&1; then
    pass "claude plugin validate plugin/ (plugin)"
  else
    fail "claude plugin validate plugin/ (plugin)" "exit != 0"
  fi
  if claude plugin validate "$PLUGIN_DIR" --strict >/dev/null 2>&1; then
    pass "claude plugin validate plugin/ --strict (plugin)"
  else
    fail "claude plugin validate plugin/ --strict (plugin)" "exit != 0 (격리 후엔 경고 없어야 함)"
  fi
else
  skip "claude plugin validate" "claude CLI 미설치"
fi

# ── 3·4. 에이전트 존재 + frontmatter 필수필드 ────────────────
# 기대: plugin/agents/<name>.md 의 frontmatter name 이 <name> 과 일치.
for agent in critic planner; do
  af="$PLUGIN_DIR/agents/$agent.md"
  rel="plugin/agents/$agent.md"
  if [ ! -f "$af" ]; then
    fail "$rel 존재" "파일 없음"
    continue
  fi
  pass "$rel 존재"

  if frontmatter_has_key "$af" "name"; then
    nm="$(frontmatter_value "$af" "name")"
    if [ "$nm" = "$agent" ]; then
      pass "$rel frontmatter name == '$agent'"
    else
      fail "$rel frontmatter name == '$agent'" "실제='$nm'"
    fi
  else
    fail "$rel frontmatter 에 name 필드" "누락"
  fi

  if frontmatter_has_key "$af" "description"; then
    pass "$rel frontmatter 에 description"
  else
    fail "$rel frontmatter 에 description" "누락"
  fi
done

# critic 은 model: opus 로 박제됐나 (골든픽스처 근거 — 약한 모델은 핵심 누락 놓침)
CRITIC="$PLUGIN_DIR/agents/critic.md"
if [ -f "$CRITIC" ]; then
  cm="$(frontmatter_value "$CRITIC" "model")"
  if [ "$cm" = "opus" ]; then
    pass "plugin/agents/critic.md model == 'opus'"
  else
    fail "plugin/agents/critic.md model == 'opus'" "실제='$cm' (critic 은 모델 민감 — opus 고정 필요)"
  fi
fi

# ── 5. 파서 음성 self-test (게이트 실효성 증명) ──────────────
# claude CLI 가 없는 CI 에서는 위 3·4 frontmatter 검사가 유일한 에이전트 게이트다.
# 그 파서가 "깨진 에이전트를 실제로 떨어뜨리는지" 직접 증명한다.
SELFTEST_TMP="$(mktemp)"
# 닫는 --- 없고 description 도 없는 깨진 frontmatter
printf -- '---\nname: probe\nmodel: opus\n본문(닫는 펜스 없음)\n' > "$SELFTEST_TMP"
if frontmatter_has_key "$SELFTEST_TMP" "description"; then
  fail "파서 self-test: 깨진 frontmatter 의 누락 키" "has_key 가 거짓 통과(EOF 버그)"
else
  pass "파서 self-test: 깨진 frontmatter(닫는 --- 부재)의 누락 키를 실패 처리"
fi
# 정상 키는 여전히 잡혀야 함(거짓 음성 방지)
if frontmatter_has_key "$SELFTEST_TMP" "name"; then
  pass "파서 self-test: 존재하는 키는 정상 탐지"
else
  fail "파서 self-test: 존재하는 키 탐지" "has_key 가 정상 키를 놓침"
fi
rm -f "$SELFTEST_TMP"

# ── 집계 ─────────────────────────────────────────────────────
echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d · 스킵 %d\n" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${C_RED}실패 있음${C_NC}" >&2
  exit 1
fi
echo -e "${C_GREEN}전부 통과${C_NC}"
exit 0
