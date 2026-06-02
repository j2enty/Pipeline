#!/usr/bin/env bash
# test-plugin-skeleton.sh — Pipeline 플러그인 뼈대 + 에이전트 게이트 (P1)
#
# 검증 대상:
#   1. 매니페스트 2개(.claude-plugin/plugin.json·marketplace.json) 존재 + JSON 유효
#   2. `claude plugin validate .` [--strict] 통과 (claude CLI 있을 때만)
#   3. 에이전트 2개(agents/critic.md·planner.md) 존재
#   4. 에이전트 frontmatter 필수필드(name·description) 보유 + name 일치
#      ← claude plugin validate 는 매니페스트만 보고 에이전트 frontmatter 는
#        검증하지 않으므로(P0 실측), 이 사각지대를 직접 메운다.
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
# 첫 --- --- 블록 안에서 `key:` 값을 추출(없으면 빈 문자열).
# YAML 스칼라/접힘(>-) 모두에서 키 존재만 확인하면 되므로 값 첫 토큰만 본다.
frontmatter_has_key() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR==1 && $0!="---" { exit 1 }      # frontmatter 시작 아니면 실패
    NR==1 { infm=1; next }
    infm && $0=="---" { exit 1 }       # 키 못 찾고 블록 끝 → 실패
    infm && $0 ~ "^"k":" { exit 0 }    # 키 발견 → 성공
  ' "$file"
}

# frontmatter 스칼라 값 추출(한 줄 스칼라용) — <file> <key>
frontmatter_value() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ "^"k":[ \t]" {
      sub("^"k":[ \t]*", ""); gsub(/^[ \t"\x27]+|[ \t"\x27]+$/, ""); print; exit
    }
  ' "$file"
}

echo ""
echo -e "${C_CYAN}══ Pipeline 플러그인 뼈대 테스트 (P1) ══${C_NC}"

# ── 1. 매니페스트 존재 + JSON 유효 ───────────────────────────
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
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

# marketplace.json 이 pipeline 플러그인을 source './' 로 등록했나
if [ -f "$MARKETPLACE_JSON" ]; then
  src="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
ps=[p for p in d.get('plugins',[]) if p.get('name')=='pipeline']
print(ps[0].get('source','') if ps else 'MISSING')
" "$MARKETPLACE_JSON" 2>/dev/null)"
  if [ "$src" = "./" ]; then
    pass "marketplace.json 이 pipeline 을 source './' 로 등록"
  else
    fail "marketplace.json pipeline source == './'" "실제='$src'"
  fi
fi

# ── 2. claude plugin validate (CLI 있을 때만) ────────────────
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$REPO_ROOT" >/dev/null 2>&1; then
    pass "claude plugin validate ."
  else
    fail "claude plugin validate ." "exit != 0"
  fi
  if claude plugin validate "$REPO_ROOT" --strict >/dev/null 2>&1; then
    pass "claude plugin validate . --strict"
  else
    fail "claude plugin validate . --strict" "exit != 0 (미인식 필드·메타 누락 가능)"
  fi
else
  skip "claude plugin validate" "claude CLI 미설치"
fi

# ── 3·4. 에이전트 존재 + frontmatter 필수필드 ────────────────
# 기대: agents/<name>.md 의 frontmatter name 이 <name> 과 일치.
for agent in critic planner; do
  af="$REPO_ROOT/agents/$agent.md"
  rel="agents/$agent.md"
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
CRITIC="$REPO_ROOT/agents/critic.md"
if [ -f "$CRITIC" ]; then
  cm="$(frontmatter_value "$CRITIC" "model")"
  if [ "$cm" = "opus" ]; then
    pass "agents/critic.md model == 'opus'"
  else
    fail "agents/critic.md model == 'opus'" "실제='$cm' (critic 은 모델 민감 — opus 고정 필요)"
  fi
fi

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
