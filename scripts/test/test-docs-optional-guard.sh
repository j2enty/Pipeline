#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# 로드맵 Phase 4 — /review 의 "Docs 레포 없는 프로젝트 지원" 가드 단위테스트.
#
# 배경:
#   review.md(.tmpl) 의 쓰기-백(section 10-a)은 Context md 를 Docs 레포에 커밋·push 한다.
#   Docs 미사용 프로젝트로 이식하면 `git -C Docs checkout/add/commit/push` 가 하드 실패한다.
#   이를 막기 위해 쓰기-백 앞에 "Docs 독립 레포 루트" 판정 가드를 둔다.
#   초기 가드는 `git -C Docs rev-parse --git-dir` 였으나, 이는 부모 디렉토리로 거슬러
#   올라가 워크스페이스 루트(예: Reclip 자체가 git 레포)의 .git 을 잡아 **오판**했다
#   (Docs 가 빈/일반 dir 인데도 proceed → 부모 레포 브랜치를 건드림). 그래서
#   `rev-parse --show-toplevel` 이 Docs 자신의 실제 경로와 일치할 때만 독립 레포로
#   인정하도록 교체했다. 이 파일은 그 가드의 의미(어떤 입력에 스킵/진행 판정이 나는지)를
#   실제 git 명령으로 고정한다.
#
# anti-drift:
#   DG-DRIFT 케이스가 배포본/템플릿 review.md(.tmpl)에 가드 문자열이 실제로 존재하는지
#   grep 으로 단언해, 가드가 사라지면 fail 하도록 동기화를 강제한다.
#   ⚠️ 가드 표현을 수정하면 아래 docs_guard_decision 본문과 DG-DRIFT needle 을 함께 동기화할 것.
#
# 종속성 제로: 각 케이스가 격리 임시 디렉토리에 빈/일반/git Docs 를 만든다.
#   install.sh 불필요 → setup_install_env 안 씀.

TEMPLATE_REVIEW="$REPO_ROOT/templates/claude-commands/review.md.tmpl"
DEPLOYED_REVIEW="$REPO_ROOT/../.claude/commands/review.md"

# 가드 판정 재현 — review.md 의 "Docs 독립 레포 루트" 가드와 동일 로직.
#   review.md 는 cwd 기준 `Docs`, 테스트는 `$workspace/Docs` — 경로 prefix 만 다르고
#   가드 핵심(rev-parse --show-toplevel + pwd -P 경로 비교)은 문자 그대로 동일.
#   toplevel 이 Docs 자신의 실제 경로와 일치할 때만 "proceed", 아니면 "skip".
# 입력: $1 = 워크스페이스 루트(그 하위의 Docs/ 를 검사)
# 출력: "skip" | "proceed"
docs_guard_decision() {
  local workspace="$1"
  # >>> review.md 가드와 동일 로직 (anti-drift; DG-DRIFT 가 동기화 단언) >>>
  docs_top="$(git -C "$workspace/Docs" rev-parse --show-toplevel 2>/dev/null || true)"
  docs_abs="$(cd "$workspace/Docs" 2>/dev/null && pwd -P || true)"
  if [ -n "$docs_top" ] && [ "$docs_top" = "$docs_abs" ]; then HAS_DOCS=1; else HAS_DOCS=0; fi
  # <<< review.md 동일 구간 끝 <<<
  if [ "$HAS_DOCS" = "1" ]; then
    printf 'proceed\n'
  else
    printf 'skip\n'
  fi
}

# DG-1 — Docs 디렉토리 자체가 없음 → 스킵 판정
it "DG-1 Docs 미존재 → skip"
(
  dir="$(mktemp -d)"
  # Docs/ 를 일부러 만들지 않는다.
  out="$(docs_guard_decision "$dir")"
  assert_eq "skip" "$out" "Docs 없음인데 skip 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# DG-2 — Docs 가 git 레포로 존재 → 진행 판정
it "DG-2 Docs 가 git 레포 → proceed"
(
  dir="$(mktemp -d)"
  git init "$dir/Docs" >/dev/null 2>&1
  out="$(docs_guard_decision "$dir")"
  assert_eq "proceed" "$out" "git 레포인데 proceed 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# DG-3 — Docs 가 git 아닌 일반 디렉토리(상위에도 git 없음) → 스킵 판정
#   ([ -d Docs ] 단순 검사보다 정확함을 검증: 디렉토리는 있어도 git 레포가 아니면 커밋 불가.)
it "DG-3 Docs 가 일반 dir(non-git, 상위 git 없음) → skip"
(
  dir="$(mktemp -d)"
  mkdir "$dir/Docs"   # git init 안 함 — 그냥 빈 디렉토리. dir 자체도 git 아님.
  out="$(docs_guard_decision "$dir")"
  assert_eq "skip" "$out" "non-git 디렉토리인데 skip 아님([ -d ] 보다 정확해야 함)" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# DG-4 — 상위가 git 레포 + Docs 가 일반 dir(미클론) → 스킵 판정
#   핵심 회귀: 옛 가드 `rev-parse --git-dir` 은 부모로 거슬러 올라가 상위 .git 을 잡아
#   proceed 로 오판했다(→ 부모 레포 브랜치를 건드리는 CRITICAL 버그). 새 가드는 toplevel 이
#   Docs 자신과 불일치하므로 skip 해야 한다.
it "DG-4 상위 git + Docs 일반dir(미클론) → skip (옛 rev-parse --git-dir 오판 회귀)"
(
  dir="$(mktemp -d)"; git init "$dir" >/dev/null 2>&1; mkdir "$dir/Docs"
  out="$(docs_guard_decision "$dir")"
  assert_eq "skip" "$out" "상위 git 있는데 일반 Docs 를 proceed 로 오판" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# DG-5 — 상위가 git 레포 + Docs 가 독립 clone → 진행 판정 (Reclip 실제 구조)
#   Docs 가 자체 .git 을 가지면 toplevel 이 Docs 자신과 일치 → proceed.
it "DG-5 상위 git + Docs 독립 clone → proceed (Reclip 실제 구조)"
(
  dir="$(mktemp -d)"; git init "$dir" >/dev/null 2>&1; git init "$dir/Docs" >/dev/null 2>&1
  out="$(docs_guard_decision "$dir")"
  assert_eq "proceed" "$out" "Docs 독립 clone 인데 skip" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# DG-DRIFT — anti-drift 가드: 배포본/템플릿 review.md(.tmpl)에 가드 문자열 존재 확인.
#   위 docs_guard_decision 의 rev-parse 가드는 review.md 와 문자 일치를 전제로 한다.
#   review.md 가 가드를 제거/변경하면 이 케이스가 fail 해 동기화를 강제한다.
it "DG-DRIFT review.md(.tmpl)에 Docs 독립레포 가드(show-toplevel + pwd -P) 존재(동기화 가드)"
(
  # 가드는 두 축으로 성립한다: ① toplevel 조회(rev-parse --show-toplevel)
  # ② Docs 실경로(pwd -P) 와의 비교. 한쪽만 보면 비교부 드리프트를 놓치므로 둘 다 요구.
  # ⚠️ docs_guard_decision 의 가드 핵심 표현을 바꾸면 두 needle 도 함께 동기화할 것.
  needle_top='git -C Docs rev-parse --show-toplevel'
  needle_abs='pwd -P'
  found=0
  for f in "$TEMPLATE_REVIEW" "$DEPLOYED_REVIEW"; do
    [ -f "$f" ] || continue
    if grep -qF -- "$needle_top" "$f" && grep -qF -- "$needle_abs" "$f"; then
      found=$((found + 1))
    fi
  done
  if [ "$found" -ge 1 ]; then
    pass
  else
    fail "review.md(.tmpl)에 Docs 독립 레포 가드(show-toplevel + pwd -P) 미존재 — 가드가 제거/변경됨"
  fi
)
