#!/usr/bin/env bash
# dry-run-guard.lib.sh — /pipeline:plan 의 --dry-run 안전 가드 정적 분석 라이브러리.
#
# (P3.1) templates/claude-commands/test/dry-run-guard.test.sh 를 plugin 내부로 이식한 사본.
#   배포 SSOT 가 SKILL.md 로 일원화되고(P3.4 에서 templates/claude-commands/ 제거 완료),
#   /pipeline:plan 의 dry-run 안전 가드 검증이 templates/ 디렉토리에 의존하지 않도록 plugin
#   자산으로 자족화했다. TEMPLATE 환경변수로 검사 대상(보통 SKILL.md)을 주입받는 범용 분석기다.
#
# 목적:
#   /pipeline:plan 의 --dry-run 안전 모드가 "실제 GitHub 오염 없이" 작동하도록
#   대상 문서(SKILL.md)에 박힌 가드들이 구조적으로 안전한지 정적으로 단언한다.
#
# 결정적·격리:
#   - 대상 문서(TEMPLATE)에 대해 그대로 돈다 (install 불필요).
#   - gh·git 등 외부 호출 전혀 없음. 순수 텍스트 정적 분석.
#
# 검사 항목:
#   (a) Step 1: DRY_RUN/ISSUE_FIXTURE 변수가 실제 대입 코드로 존재하는지,
#       --issue-fixture 단독 사용 fail-fast 가드가 있는지.
#   (b) 보조 정지선(DRY_RUN if 블록)이 코드펜스 안에 존재하고,
#       if~fi 범위 안에 exit 0 이 있는지 (가독성용).
#   (c-new) R2 self-guard: 원격 쓰기 명령을 포함하는 각 bash/sh/shell 펜스에
#       첫 원격쓰기 줄보다 먼저 '$ARGUMENTS' self-guard 가 있는지 검사.
#       self-guard 시그니처: case " $ARGUMENTS " in *" --dry-run "*) ... exit 0
#       없으면 FAIL + 어느 펜스인지(시작 라인) 출력.
#   (c-old) 보조: 보조 정지선(DRY_RUN 분기) 앞 bash 펜스에 허용 외 gh/git 없는지
#       (G1·G2 화이트리스트, 이제 보조 역할).
#
# 왜 "코드펜스 안"으로 한정하나:
#   SKILL.md 는 마크다운 지시문이라 원격 쓰기 명령의 이름이 산문/백틱 설명에도 등장한다.
#   산문은 실행되지 않으므로 판정은 코드펜스 내부 줄로만 한정한다.
#
# 알려진 한계: 들여쓴 펜스(    ```bash)·인라인 명령은 미탐.

set -uo pipefail

# ── here-string 사용 이유 (#88) ──────────────────────────────────────────────
# 아래에서 BASH_LINES 같은 큰 문자열을 grep 으로 검사할 때 `printf … | grep -q`
# 파이프 대신 here-string(`grep … <<< "$VAR"`)을 쓴다.
# 이유: `grep -q` 는 첫 매칭에서 즉시 종료하며 파이프를 닫는데, 그 순간 아직
# 출력 중이던 `printf` 가 SIGPIPE 로 죽어 exit 141 이 된다. `set -o pipefail`
# 때문에 파이프라인 전체가 실패 처리되어, 매칭이 실재해도 `if` 가 거짓이 되는
# 비결정적 오판(타이밍 레이스)이 발생한다. here-string 은 파이프가 없어 SIGPIPE
# 가 발생하지 않으므로 이 레이스를 원천 차단한다.

# ── 경로 ─────────────────────────────────────────────────────────────────────
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TEMPLATE 은 외부에서 주입받는 검사 대상 — 호출자(structure.test.sh)가 TEMPLATE="$SKILL" 로 넘긴다.
#   기본값은 plugin 내부 SKILL.md(직접 실행·음성 테스트가 임시 사본 경로를 넘길 때 대비).
TEMPLATE="${TEMPLATE:-$TEST_DIR/../SKILL.md}"

# ── 색상 ─────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

FAILED=0
pass() { printf "${C_GREEN}✓ PASS${C_NC} %s\n" "$1"; }
fail() { printf "${C_RED}✗ FAIL${C_NC} %s\n" "$1"; FAILED=1; }

if [ ! -f "$TEMPLATE" ]; then
  printf "${C_RED}✗ 템플릿 파일 없음: %s${C_NC}\n" "$TEMPLATE"
  exit 1
fi

printf "${C_CYAN}══ dry-run 가드 정적 분석 (%s) ══${C_NC}\n\n" "$(basename "$TEMPLATE")"

# ── 코드펜스(```bash / ```sh / ```shell) 내부 줄 추출 ────────────────────────
# G2 수정: ```sh / ```shell 펜스도 인식. markdown/text/plain 제외.
# 결과 형태: "원본라인번호:내용"
# FENCES: 각 펜스를 "시작라인|종료라인|내용목록" 으로도 분리 (c-new 에서 사용)
BASH_LINES="$(awk '
  /^```(bash|sh|shell)[[:space:]]*$/ { inbash=1; next }
  /^```/ && inbash { inbash=0; next }
  inbash { print NR":"$0 }
' "$TEMPLATE")"

# 펜스 경계 정보: "펜스시작라인 펜스종료라인" 쌍 (c-new 에서 사용)
# 주의: 열기 패턴에 next 필수 — 없으면 /^```/ 가 열기도 닫기로 매칭해 start==end 버그 발생.
FENCE_RANGES="$(awk '
  /^```(bash|sh|shell)[[:space:]]*$/ { start=NR; next }
  /^```/ && start>0 { print start" "NR; start=0; next }
' "$TEMPLATE")"

# ── (a-1) Step 1: DRY_RUN 실제 대입 코드 존재 검사 ───────────────────────────
if grep -qE 'DRY_RUN=(false|true)' <<< "$BASH_LINES"; then
  pass "(a-1) Step 1: DRY_RUN 변수 대입 코드 존재"
else
  fail "(a-1) Step 1: DRY_RUN 변수 대입 코드 없음 (DRY_RUN=false 또는 DRY_RUN=true 필요)"
fi

# ── (a-2) Step 1: ISSUE_FIXTURE 실제 대입 코드 존재 검사 ─────────────────────
if grep -qE 'ISSUE_FIXTURE=' <<< "$BASH_LINES"; then
  pass "(a-2) Step 1: ISSUE_FIXTURE 변수 대입 코드 존재"
else
  fail "(a-2) Step 1: ISSUE_FIXTURE 변수 대입 코드 없음"
fi

# ── (a-3) Step 1: --issue-fixture 파싱 분기 존재 검사 ────────────────────────
if grep -qF -- '--issue-fixture)' <<< "$BASH_LINES"; then
  pass "(a-3) Step 1: --issue-fixture 파싱 분기 존재"
else
  fail "(a-3) Step 1: --issue-fixture 파싱 분기 없음 (case '--issue-fixture)' 필요)"
fi

# ── (a-4) F3 가드: --issue-fixture 단독 사용 fail-fast 존재 검사 ─────────────
if grep -qF '[ -n "$ISSUE_FIXTURE" ] && [ "$DRY_RUN" != true ]' <<< "$BASH_LINES"; then
  pass "(a-4) F3 가드: --issue-fixture 단독 사용 fail-fast 존재"
else
  fail "(a-4) F3 가드: --issue-fixture 단독 사용 fail-fast 없음"
fi

# ── (b-1) 보조 정지선 라인번호 찾기 (코드펜스 내부) ──────────────────────────
# 정지선 시그니처: if [ "$DRY_RUN" = true ]; then
STOP_LINE="$(grep -F 'if [ "$DRY_RUN" = true ]; then' <<< "$BASH_LINES" \
  | head -n1 | cut -d: -f1)"

if [ -z "$STOP_LINE" ]; then
  fail "(b-1) 보조 정지선(if [ \"\$DRY_RUN\" = true ]; then)이 코드펜스 안에 없음"
  STOP_LINE=0
else
  pass "(b-1) 보조 정지선 발견 — 라인 $STOP_LINE (가독성·참고용)"
fi

# ── (b-2) 보조 정지선 if~fi 범위 안에 exit 0 존재 검사 ──────────────────────
if [ "$STOP_LINE" -gt 0 ]; then
  FI_BLOCK_HAS_EXIT=$(printf '%s\n' "$BASH_LINES" \
    | awk -F: -v stop="$STOP_LINE" '
        { ln=$1; rest=substr($0, index($0,":")+1) }
        ln >= stop && !found_stop { found_stop=1 }
        found_stop && rest ~ /^[[:space:]]*fi[[:space:]]*$/ { exit }
        found_stop && rest ~ /exit 0/ { print "yes"; exit }
      ')
  if [ "$FI_BLOCK_HAS_EXIT" = "yes" ]; then
    pass "(b-2) 보조 정지선 if~fi 블록 안에 exit 0 존재"
  else
    fail "(b-2) 보조 정지선 if~fi 블록 안에 exit 0 없음"
  fi
fi

# ── (c-new) R2 self-guard 검사: 원격쓰기 펜스에 $ARGUMENTS 가드 있는지 ────────
#
# 원격 쓰기 명령 패턴(코드펜스 내부 비주석 줄에서 검출):
#   gh pr create, gh issue create, gh issue edit, gh label create
#   git push, git commit, git checkout -b
#   gh api --method POST|DELETE|PATCH|PUT
#   gh api graphql -f (addProjectV2ItemById·updateProjectV2ItemFieldValue 포함)
#   gh api ... -f ... (암묵 POST, G1)
#
# self-guard 시그니처(펜스 안 어떤 줄에든):
#   case " $ARGUMENTS " in *" --dry-run "*) ... exit 0
#
# 알고리즘:
#   각 펜스(시작라인~종료라인)를 순회.
#   펜스 안에 원격 쓰기 명령이 있으면 → 그 펜스 안에 self-guard 도 있어야 함.
#   self-guard 가 원격 쓰기 첫 줄보다 앞에 있어야 함.

# 원격 쓰기 패턴을 줄 단위로 판정하는 함수 (R4: 시작 게이트 → 부분일치로 확장)
# 래핑 형태 SUB_URL=$(gh issue create …)·if gh·( gh·파이프 등을 포함.
is_remote_write() {
  local line="$1"
  # 좌측 공백 제거
  local t="${line#"${line%%[![:space:]]*}"}"
  # 주석 줄 스킵 (# 로 시작하는 줄은 실행 안 됨)
  case "$t" in \#*) return 1 ;; esac
  [ -n "$t" ] || return 1

  # ── git 쓰기 동사 부분일치 ───────────────────────────────────────────────
  # git push / git commit / git checkout -b 가 줄 어디에든 있으면 쓰기
  case "$t" in
    *git\ push*|*git\ commit*|*git\ checkout\ -b*|\
    *git\ -C\ *\ push*|*git\ -C\ *\ commit*|*git\ -C\ *\ checkout\ -b*) return 0 ;;
  esac

  # ── gh 쓰기 동사 부분일치 ───────────────────────────────────────────────
  # gh pr create / gh issue create / gh issue edit / gh label create
  case "$t" in
    *gh\ pr\ create*|\
    *gh\ issue\ create*|\
    *gh\ issue\ edit*|\
    *gh\ label\ create*) return 0 ;;
  esac

  # gh api --method POST|DELETE|PATCH|PUT (명시적 쓰기 메서드)
  case "$t" in
    *--method\ POST*|*--method\ DELETE*|*--method\ PATCH*|*--method\ PUT*) return 0 ;;
  esac

  # gh api graphql -f (Project mutation: addProjectV2ItemById 등)
  case "$t" in
    *gh\ api\ graphql\ -f*) return 0 ;;
  esac

  # gh api -f/-F/-–field/--raw-field/--input (암묵 POST, G1)
  # gh api 가 줄 어딘가에 있고 쓰기 플래그도 있으면 쓰기로 판정.
  case "$t" in
    *gh\ api\ *)
      case "$t" in
        *\ -f\ *|*\ -F\ *|*\ --field\ *|*\ --raw-field\ *|*\ --input\ *) return 0 ;;
      esac
      ;;
  esac

  return 1
}

# self-guard 시그니처 존재 판정
has_self_guard_line() {
  local line="$1"
  case "$line" in
    *'case " $ARGUMENTS " in'*'--dry-run'*'exit 0'*) return 0 ;;
  esac
  return 1
}

violations_c_new=0

while IFS=' ' read -r fence_start fence_end; do
  [ -n "$fence_start" ] || continue

  # 이 펜스의 줄들을 추출
  fence_lines="$(printf '%s\n' "$BASH_LINES" \
    | awk -F: -v s="$fence_start" -v e="$fence_end" \
        '$1 > s && $1 < e { print }')"

  [ -n "$fence_lines" ] || continue

  # 이 펜스에 원격 쓰기 명령이 있는지, 있다면 첫 줄 번호
  first_write_ln=0
  while IFS= read -r fentry; do
    [ -n "$fentry" ] || continue
    fln="${fentry%%:*}"
    fcontent="${fentry#*:}"
    if is_remote_write "$fcontent"; then
      first_write_ln="$fln"
      break
    fi
  done <<FEOF
$fence_lines
FEOF

  # 원격 쓰기 없으면 이 펜스는 검사 불필요
  [ "$first_write_ln" -gt 0 ] || continue

  # self-guard 가 있는지, 있다면 첫 번째 라인번호
  guard_ln=0
  while IFS= read -r fentry; do
    [ -n "$fentry" ] || continue
    fln="${fentry%%:*}"
    fcontent="${fentry#*:}"
    if has_self_guard_line "$fcontent"; then
      guard_ln="$fln"
      break
    fi
  done <<FEOF
$fence_lines
FEOF

  if [ "$guard_ln" -eq 0 ]; then
    fail "(c-new) 펜스(시작 라인 $fence_start)에 원격 쓰기(첫 발견: L$first_write_ln)가 있지만 \$ARGUMENTS self-guard 없음"
    violations_c_new=$((violations_c_new + 1))
  elif [ "$guard_ln" -gt "$first_write_ln" ]; then
    fail "(c-new) 펜스(시작 라인 $fence_start): self-guard(L$guard_ln)가 첫 원격쓰기(L$first_write_ln)보다 뒤에 있음"
    violations_c_new=$((violations_c_new + 1))
  fi

done <<FEOF
$FENCE_RANGES
FEOF

if [ "$violations_c_new" -eq 0 ]; then
  pass "(c-new) 원격 쓰기 펜스 전체에 \$ARGUMENTS self-guard 존재 + 원격쓰기 앞에 위치"
fi

# ── (c-old) 보조: 보조 정지선 앞 bash 펜스에 허용 외 gh/git 없는지 ───────────
# G1·G2 화이트리스트 — 이제 보조 역할 (self-guard 가 1차 방어선)
if [ "$STOP_LINE" -gt 0 ]; then
  BEFORE_STOP="$(printf '%s\n' "$BASH_LINES" \
    | awk -F: -v stop="$STOP_LINE" '$1 < stop { print }')"

  violations_c_old=0

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    ln="${entry%%:*}"
    content="${entry#*:}"
    trimmed="${content#"${content%%[![:space:]]*}"}"
    case "$trimmed" in \#*) continue ;; esac
    [ -n "$trimmed" ] || continue
    case "$trimmed" in gh\ *|git\ *) ;; *) continue ;; esac

    allowed=false

    # gh 허용: gh issue view (읽기)
    case "$trimmed" in gh\ issue\ view\ *) allowed=true ;; esac

    # gh 허용: gh api — --jq 있고 쓰기 플래그 전무 (G1 수정)
    case "$trimmed" in
      gh\ api\ *)
        has_write_flag=false
        case "$trimmed" in
          *--method\ POST*|*--method\ DELETE*|*--method\ PATCH*|*--method\ PUT*) has_write_flag=true ;;
        esac
        case "$trimmed" in
          *\ -f\ *|*\ -F\ *|*\ --field\ *|*\ --raw-field\ *|*\ --input\ *) has_write_flag=true ;;
        esac
        if [ "$has_write_flag" = false ]; then
          case "$trimmed" in *--jq\ *) allowed=true ;; esac
        fi
        ;;
    esac

    # gh 허용: gh project field-list (읽기)
    case "$trimmed" in gh\ project\ field-list\ *) allowed=true ;; esac

    # git 허용: git rev-parse, git ls-remote (읽기)
    case "$trimmed" in
      git\ rev-parse\ *|git\ ls-remote\ *) allowed=true ;;
    esac

    # git 허용: git -C ... rev-parse / ls-remote
    case "$trimmed" in
      git\ -C\ *\ rev-parse\ *|git\ -C\ *\ ls-remote\ *) allowed=true ;;
    esac

    if [ "$allowed" = false ]; then
      fail "(c-old) 보조 정지선(L$STOP_LINE)보다 앞 bash 펜스에 비허용 gh/git 명령 발견 (L$ln): $trimmed"
      violations_c_old=$((violations_c_old + 1))
    fi
  done <<EOF
$BEFORE_STOP
EOF

  if [ "$violations_c_old" -eq 0 ]; then
    pass "(c-old) 보조 정지선 앞 bash 펜스에 허용목록 외 gh/git 없음 (G1·G2 클린)"
  fi
fi

# ── F8: 서브셸 exit 전파 가드 확인 ───────────────────────────────────────────
# 3.5-b·3.5-c 서브셸 뒤에 || exit 1 이 있어야 한다.
if grep -qF ') || exit 1' <<< "$BASH_LINES"; then
  pass "(F8) 3.5-b/3.5-c 서브셸 뒤 || exit 1 전파 가드 존재"
else
  fail "(F8) 3.5-b/3.5-c 서브셸 뒤 || exit 1 전파 가드 없음 — 서브셸 실패가 부모로 전파 안 됨"
fi

# ── F9: 사용법 예시 상대경로 주석 존재 확인 ──────────────────────────────────
if grep -qF 'test/fixtures/' "$TEMPLATE" && grep -qF '테스트 하니스' "$TEMPLATE"; then
  pass "(F9) 사용법 예시의 --issue-fixture 상대경로에 테스트 하니스 전용 주석 존재"
else
  fail "(F9) 사용법 예시의 --issue-fixture 상대경로에 '테스트 하니스 전용' 주석 없음"
fi

# ── (G-2) 파일명·브랜치명에 <slug> 단독 잔존 없는지 ─────────────────────────────
# Phase A1 보장: 파일경로/브랜치명의 모든 <slug> 는 <parent-N>-<slug> 형식이어야 함.
# 검사 패턴: /<slug>  →  requirements/<slug>, plans/<slug>, plan/<slug> 모두 포착.
# 올바른 형식(/<parent-N>-<slug>)은 슬래시 바로 뒤가 <parent-N> 이므로 이 패턴에 안 걸림.
G2_HITS="$(grep -n '/<slug>' "$TEMPLATE")"
if [ -n "$G2_HITS" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    fail "(G-2) 파일경로·브랜치명에 번호 없는 /<slug> 잔존: $hit"
  done <<EOF
$G2_HITS
EOF
else
  pass "(G-2) 파일경로·브랜치명 전체에 번호 없는 /<slug> 없음 (모두 <parent-N>-<slug> 형식)"
fi

# ── 집계 ─────────────────────────────────────────────────────────────────────
# (P3.1) printf 포맷 문자열에 변수를 직접 넣지 않는다(SC2059) — 색상은 %s 인자로 전달.
printf '\n%s══════════════════════════════%s\n' "$C_CYAN" "$C_NC"
if [ "$FAILED" -eq 0 ]; then
  printf '%s전체 PASS — dry-run 가드 안전 보장 확인%s\n' "$C_GREEN" "$C_NC"
  exit 0
else
  printf '%sFAIL — 위 항목을 수정할 것%s\n' "$C_RED" "$C_NC"
  exit 1
fi
