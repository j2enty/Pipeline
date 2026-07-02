#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# #99 — parse-critic-verdict.sh 단위테스트.
#   추출된 verdict 파싱의 fail-closed 방어(#9 식별·#B marker stale·#A allowlist·0/복수 매칭)를
#   실제 동작으로 검증한다. 껍데기 금지 — 각 케이스가 임시 디렉토리에 실제 상태파일·marker 를
#   만들어 fail-closed 결과(indeterminate)를 강제한다.
#   종속성 제로: 실제 resolve-review-statefile.sh 를 RESOLVE_SH 로 물려 통합 경로까지 검증한다.

PARSE_SH="$REPO_ROOT/scripts/parse-critic-verdict.sh"
RESOLVE_SH_REAL="$REPO_ROOT/scripts/resolve-review-statefile.sh"

# 상태파일 작성 — write_state <경로> <parent_url> <verdict>
# verdict 가 빈 문자열이면 .aggregate.verdict 를 아예 넣지 않는다(스키마 손상 모사).
write_state() {
  local path="$1" purl="$2" verdict="${3:-}"
  if [ -n "$verdict" ]; then
    printf '{"parent":{"url":"%s"},"aggregate":{"verdict":"%s"}}\n' "$purl" "$verdict" > "$path"
  else
    printf '{"parent":{"url":"%s"},"aggregate":{}}\n' "$purl" > "$path"
  fi
}

# stdout 두 줄 계약에서 verdict/state_file 추출
verdict_of() { printf '%s\n' "$1" | grep '^verdict=' | head -1 | cut -d= -f2-; }
statefile_of() { printf '%s\n' "$1" | grep '^state_file=' | head -1 | cut -d= -f2-; }

# parse 호출 — 공통 env 를 세팅해 stdout 을 반환. marker 는 인자로 받는다.
# 인자: <dir> <parent_url> <marker_path> [sentinel_path]
run_parse() {
  local dir="$1" purl="$2" marker="$3" sentinel="${4:-}"
  RESOLVE_SH="$RESOLVE_SH_REAL" \
  VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" \
  CRITIC_RUN_MARKER="$marker" REVIEW_STATE_SENTINEL="$sentinel" \
    bash "$PARSE_SH" 2>/dev/null
}

# PV-1 — 정상: 매칭 1개 + 파일이 marker 보다 newer + verdict=pass → pass
it "PV-1 정상 상태파일(pass, marker 보다 newer) → pass"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"  # marker 를 아주 과거로
  write_state "$dir/slug.json" "$purl" "pass"                              # 파일은 방금 생성(=newer)
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "pass" "$(verdict_of "$out")" "정상 pass 아님" || { rm -rf "$dir"; return; }
  # state_file 은 절대경로로 식별돼야 함
  assert_contains "$(statefile_of "$out")" "slug.json" "state_file 미식별" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-2 — stale: 매칭 파일이 marker 보다 older → indeterminate (fail-closed)
it "PV-2 stale(파일이 marker 보다 older) → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state "$dir/slug.json" "$purl" "pass"
  touch -t 200001010000 "$dir/slug.json"   # 파일을 아주 과거로(=stale)
  marker="$dir/.marker"; touch "$marker"    # marker 는 지금(=newer than file)
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "indeterminate" "$(verdict_of "$out")" "stale 인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-3 — marker 없음 → indeterminate (fail-closed)
it "PV-3 marker 파일 없음 → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state "$dir/slug.json" "$purl" "pass"
  out="$(run_parse "$dir" "$purl" "$dir/.nonexistent-marker")"
  assert_eq "indeterminate" "$(verdict_of "$out")" "marker 없음인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-4 — 매칭 0개(다른 parent 만 존재) → indeterminate
it "PV-4 매칭 0개 → indeterminate"
(
  dir="$(mktemp -d)"
  write_state "$dir/other.json" "https://github.com/org/Repo/issues/99" "pass"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  out="$(run_parse "$dir" "https://github.com/org/Repo/issues/3" "$marker")"
  assert_eq "indeterminate" "$(verdict_of "$out")" "0개 매칭인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$(statefile_of "$out")" "0개 매칭인데 state_file 비어있지 않음" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-5 — 매칭 2개(같은 parent 두 파일) → indeterminate
it "PV-5 매칭 2개 → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  write_state "$dir/dup1.json" "$purl" "pass"
  write_state "$dir/dup2.json" "$purl" "pass"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "indeterminate" "$(verdict_of "$out")" "2개 매칭인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-6 — .aggregate.verdict 빈값/스키마 손상(매칭 1개·newer) → indeterminate
it "PV-6 verdict 빈값/스키마 손상 → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  write_state "$dir/slug.json" "$purl" ""   # aggregate.verdict 없음
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "indeterminate" "$(verdict_of "$out")" "verdict 빈값인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-7 — allowlist 밖 값(인젝션 시도) → indeterminate
it "PV-7 allowlist 밖 verdict(pass; rm -rf) → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  write_state "$dir/slug.json" "$purl" "pass; rm -rf /"
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "indeterminate" "$(verdict_of "$out")" "allowlist 밖인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-8a — concerns 정상 통과
it "PV-8a concerns → concerns"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  write_state "$dir/slug.json" "$purl" "concerns"
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "concerns" "$(verdict_of "$out")" "concerns 통과 실패" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-8b — blocker 정상 통과
it "PV-8b blocker → blocker"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  write_state "$dir/slug.json" "$purl" "blocker"
  out="$(run_parse "$dir" "$purl" "$marker")"
  assert_eq "blocker" "$(verdict_of "$out")" "blocker 통과 실패" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-9 — resolve 스크립트 미존재 시 인라인 폴백 경로도 동일 결과(회귀 0)
it "PV-9 resolve 스크립트 미존재 → 인라인 폴백으로 pass"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  write_state "$dir/slug.json" "$purl" "pass"
  write_state "$dir/noise.json" "https://github.com/org/Repo/issues/30" "blocker"  # 부분매칭 유도용
  out="$(RESOLVE_SH="$dir/.no-such-resolve.sh" \
    VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" \
    CRITIC_RUN_MARKER="$marker" REVIEW_STATE_SENTINEL="" \
    bash "$PARSE_SH" 2>/dev/null)"
  assert_eq "pass" "$(verdict_of "$out")" "인라인 폴백 pass 아님" || { rm -rf "$dir"; return; }
  assert_contains "$(statefile_of "$out")" "slug.json" "인라인 폴백 state_file 틀림" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# PV-10 — sentinel 로 결정적 식별(다른 parent 파일이 섞여 있어도 sentinel 우선)
it "PV-10 sentinel 결정적 식별 → pass"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  marker="$dir/.marker"; touch "$marker"; touch -t 200001010000 "$marker"
  write_state "$dir/mine.json" "$purl" "pass"
  write_state "$dir/other.json" "https://github.com/org/Repo/issues/99" "blocker"
  sentinel="$dir/.sentinel"; printf '%s\n' "$dir/mine.json" > "$sentinel"
  out="$(run_parse "$dir" "$purl" "$marker" "$sentinel")"
  assert_eq "pass" "$(verdict_of "$out")" "sentinel 식별 pass 아님" || { rm -rf "$dir"; return; }
  assert_contains "$(statefile_of "$out")" "mine.json" "sentinel 식별 경로 틀림" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)
