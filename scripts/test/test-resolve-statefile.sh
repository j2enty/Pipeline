#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# 이슈 #9 — resolve-review-statefile.sh 단위테스트.
#   sentinel 신뢰 + critic/single 폴백 + fail-closed(indeterminate) 검증.
#   종속성 제로: 각 케이스가 임시 디렉토리에 더미 상태파일/sentinel 을 만든다.

RESOLVE_SH="$REPO_ROOT/scripts/resolve-review-statefile.sh"

# 더미 상태파일 한 개 작성 — write_state_json <경로> <parent_url 또는 빈문자열>
# parent_url 이 빈 문자열이면 .parent=null (single 모드 모사).
write_state_json() {
  local path="$1" purl="${2:-}"
  if [ -n "$purl" ]; then
    printf '{"parent":{"url":"%s"},"aggregate":{"verdict":"pass"}}\n' "$purl" > "$path"
  else
    printf '{"parent":null,"aggregate":{"verdict":"pass"}}\n' > "$path"
  fi
}

# RS-1 — sentinel 유효(critic, parent.url 일치) → 그 경로 채택
it "RS-1 sentinel 유효(critic) → 채택"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state_json "$dir/my-slug.json" "$purl"
  # 오답 유도용 다른 parent 상태파일도 둠 — sentinel 이 우선해야 함
  write_state_json "$dir/other.json" "https://github.com/org/Repo/issues/99"
  sentinel="$dir/.sentinel"
  printf '%s\n' "$dir/my-slug.json" > "$sentinel"
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "sentinel 유효인데 exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/my-slug.json" "$out" "sentinel 경로 채택 실패" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-2 — sentinel 의 parent.url 불일치(critic) → indeterminate(폴백 안 함, fail-closed)
it "RS-2 sentinel parent.url 불일치(critic) → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  # sentinel 이 가리키는 파일은 다른 parent — 오염 시나리오
  write_state_json "$dir/wrong.json" "https://github.com/org/Repo/issues/77"
  # 동시에 정답 파일도 존재하지만, sentinel 오염이면 폴백하지 않고 차단해야 함
  write_state_json "$dir/right.json" "$purl"
  sentinel="$dir/.sentinel"
  printf '%s\n' "$dir/wrong.json" > "$sentinel"
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "오염 sentinel 인데 indeterminate(exit 1) 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$out" "오염 sentinel 인데 경로 출력됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-3 — sentinel 없음 + critic 매칭 정확히 1개 → 폴백 성공
it "RS-3 sentinel 없음 + 매칭 1개(critic) → 폴백 성공"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state_json "$dir/slug.json" "$purl"
  write_state_json "$dir/noise.json" "https://github.com/org/Repo/issues/30"
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "매칭 1개인데 폴백 exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/slug.json" "$out" "폴백 매칭 경로 틀림" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-3b — 폴백 부분매칭 금지 검증: issues/3 와 issues/30 공존 시 issues/3 만 정확매칭
it "RS-3b 폴백 정확매칭(issues/3 ≠ issues/30)"
(
  dir="$(mktemp -d)"
  write_state_json "$dir/a.json" "https://github.com/org/Repo/issues/30"
  write_state_json "$dir/b.json" "https://github.com/org/Repo/issues/3"
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="https://github.com/org/Repo/issues/3" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "정확매칭 1개인데 exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/b.json" "$out" "부분매칭으로 잘못된 파일 선택" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-4 — sentinel 없음 + 매칭 0개(critic) → indeterminate
it "RS-4 매칭 0개(critic) → indeterminate"
(
  dir="$(mktemp -d)"
  write_state_json "$dir/other.json" "https://github.com/org/Repo/issues/99"
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="https://github.com/org/Repo/issues/3" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "매칭 0개인데 indeterminate(exit 1) 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$out" "매칭 0개인데 경로 출력됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-5 — sentinel 없음 + 매칭 복수(critic) → indeterminate
it "RS-5 매칭 복수(critic) → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state_json "$dir/dup1.json" "$purl"
  write_state_json "$dir/dup2.json" "$purl"
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "매칭 복수인데 indeterminate(exit 1) 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$out" "매칭 복수인데 경로 출력됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-6 — single 모드 폴백: pr-<repo>-<number>.json 파일명 구성
it "RS-6 single 폴백 → 파일명 구성"
(
  dir="$(mktemp -d)"
  write_state_json "$dir/pr-Backend-42.json" ""
  rc=0
  out="$(MODE=single VERDICT_STATE_DIR="$dir" PR_REPO="org/Backend" PR_NUMBER="42" \
    bash "$RESOLVE_SH" single 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "single 폴백 exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/pr-Backend-42.json" "$out" "single 파일명 구성 틀림" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-7 — single 모드 sentinel basename 일치 → 채택 (수정 3: basename 교차검증)
it "RS-7 single sentinel basename 일치 → 채택"
(
  dir="$(mktemp -d)"
  write_state_json "$dir/pr-Backend-42.json" ""
  sentinel="$dir/.sentinel"
  printf '%s\n' "$dir/pr-Backend-42.json" > "$sentinel"
  rc=0
  out="$(MODE=single VERDICT_STATE_DIR="$dir" PR_REPO="org/Backend" PR_NUMBER="42" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" single 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "single sentinel(basename 일치) exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/pr-Backend-42.json" "$out" "single sentinel 채택 실패" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-7b — single 모드 sentinel 이 다른 PR 파일을 가리킴(basename 불일치) → indeterminate
it "RS-7b single sentinel basename 불일치 → indeterminate"
(
  dir="$(mktemp -d)"
  # sentinel 이 다른 PR(Frontend-99) 의 파일을 가리키는 오염 시나리오
  write_state_json "$dir/pr-Frontend-99.json" ""
  write_state_json "$dir/pr-Backend-42.json" ""
  sentinel="$dir/.sentinel"
  printf '%s\n' "$dir/pr-Frontend-99.json" > "$sentinel"
  rc=0
  out="$(MODE=single VERDICT_STATE_DIR="$dir" PR_REPO="org/Backend" PR_NUMBER="42" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" single 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "오염 single sentinel 인데 indeterminate(exit 1) 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$out" "오염 single sentinel 인데 경로 출력됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-8 — single 모드 파일 부재 → indeterminate
it "RS-8 single 파일 부재 → indeterminate"
(
  dir="$(mktemp -d)"
  rc=0
  out="$(MODE=single VERDICT_STATE_DIR="$dir" PR_REPO="org/Backend" PR_NUMBER="42" \
    bash "$RESOLVE_SH" single 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "파일 부재인데 indeterminate(exit 1) 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$out" "파일 부재인데 경로 출력됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-9 — sentinel 가리킨 파일이 미존재(.json 인데 실파일 없음) → 폴백으로(critic)
it "RS-9 sentinel target 미존재 → 폴백"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state_json "$dir/slug.json" "$purl"
  sentinel="$dir/.sentinel"
  printf '%s\n' "$dir/ghost.json" > "$sentinel"   # 실파일 없음 → 무효 → 폴백
  rc=0
  out="$(MODE=critic VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "sentinel 무효인데 폴백 exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/slug.json" "$out" "폴백 경로 틀림" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-10 — 잘못된 인자/환경: 모드 누락 → exit 2
it "RS-10 모드 누락 → exit 2"
(
  rc=0
  VERDICT_STATE_DIR="/tmp" bash "$RESOLVE_SH" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "모드 누락인데 exit 2 아님" && pass
)

# RS-11 — critic 모드 PARENT_URL 누락 → exit 2
it "RS-11 critic PARENT_URL 누락 → exit 2"
(
  rc=0
  VERDICT_STATE_DIR="/tmp" bash "$RESOLVE_SH" critic >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "PARENT_URL 누락인데 exit 2 아님" && pass
)

# RS-12 — single 모드 sentinel 경로에 공백 포함 → 변형 없이 채택
# xargs 를 쓰면 경로 중간 공백을 토큰 경계로 해석해 경로가 잘리거나 빈 값이 된다.
# IFS= read -r + tr 방식에서는 경로 내부 공백이 보존돼야 한다.
it "RS-12 single sentinel 경로 공백 포함 → 변형 없이 채택"
(
  dir="$(mktemp -d)"
  # 공백이 포함된 하위 디렉토리 생성
  spacedir="$dir/has space"
  mkdir -p "$spacedir"
  write_state_json "$spacedir/pr-Repo-1.json" ""
  sentinel="$dir/.sentinel"
  printf '%s\n' "$spacedir/pr-Repo-1.json" > "$sentinel"
  rc=0
  out="$(VERDICT_STATE_DIR="$dir" PR_REPO="org/Repo" PR_NUMBER="1" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" single 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "공백 경로 sentinel exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$spacedir/pr-Repo-1.json" "$out" "공백 경로가 변형됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# RS-13 — sentinel 파일이 CRLF(\r\n)로 기록됨 → \r 제거 후 정상 채택(critic)
it "RS-13 sentinel CRLF 기록 → CR 제거 후 정상 채택"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/5"
  write_state_json "$dir/slug.json" "$purl"
  sentinel="$dir/.sentinel"
  # printf 로 CRLF(\r\n) 강제 기록
  printf '%s\r\n' "$dir/slug.json" > "$sentinel"
  rc=0
  out="$(VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "CRLF sentinel exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "$dir/slug.json" "$out" "CRLF 후 경로 변형됨" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)
