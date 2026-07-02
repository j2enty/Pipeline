#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# 이슈 #14-② — critic.yml marker(-nt) stale 검증 시퀀스 단위테스트.
#
# 배경:
#   critic.yml 의 verdict 파싱 step 은 (1) resolve-review-statefile.sh(sentinel 우선)로
#   STATE_FILE 을 식별한 뒤, (2) 그 파일이 "이번 실행이 새로 쓴 것"인지 marker 파일과
#   `-nt`(newer-than) 비교로 검증한다(fail-closed). resolve 스크립트 단위테스트(RS-1~13)는
#   "어느 파일"만 검증할 뿐 이 `-nt` 신선도 경로를 안 탄다.
#   이 파일은 critic.yml 의 결정 시퀀스(식별 → marker -nt → verdict|indeterminate)를
#   그대로 재현해 "sentinel 식별 + stale 파일 → indeterminate" 시나리오를 테스트로 고정한다.
#
# anti-drift:
#   `-nt` 스니펫은 critic.yml 과 문자 그대로 동일하게 작성한다(드리프트 방지).
#   MS-DRIFT 케이스가 critic.yml 에 그 핵심 라인이 실제로 존재하는지 grep 으로 단언한다.
#
# 종속성 제로: 각 케이스가 임시 디렉토리에 더미 상태파일/sentinel/marker 를 만든다.
#   install.sh 불필요 → setup_install_env 안 씀.

RESOLVE_SH="$REPO_ROOT/scripts/resolve-review-statefile.sh"
# #99 — verdict 파싱(marker -nt stale 검증 포함)이 critic.yml 인라인에서
# parse-critic-verdict.sh 로 추출됐다(critic.yml·critic-dispatch.yml 공유 부품).
# anti-drift 가드는 이제 그 추출본을 대상으로 한다.
PARSE_SH="$REPO_ROOT/scripts/parse-critic-verdict.sh"

# 더미 상태파일 작성 — write_state_json <경로> <parent_url> [verdict]
# critic.yml 이 읽는 .parent.url(식별)·.aggregate.verdict(판정) 둘 다 채운다.
write_state_json() {
  local path="$1" purl="$2" verdict="${3:-pass}"
  printf '{"parent":{"url":"%s"},"aggregate":{"verdict":"%s"}}\n' "$purl" "$verdict" > "$path"
}

# critic.yml 의 결정 시퀀스를 그대로 재현해 최종 verdict 를 stdout 1줄로 돌려준다.
#   ① resolve-review-statefile.sh(critic 모드, sentinel 우선)로 STATE_FILE 식별
#   ② marker 파일과 -nt 비교로 fresh/stale 판정 (스니펫은 critic.yml 과 문자 일치)
#   ③ 그 결과로 verdict(.aggregate.verdict) vs indeterminate
# 입력: VERDICT_STATE_DIR / PARENT_URL / REVIEW_STATE_SENTINEL(옵션) / CRITIC_RUN_MARKER
# 출력: pass|concerns|blocker|indeterminate 중 하나
resolve_and_judge() {
  local state_file="" match_count=0 rc=0 critic_verdict=""
  # ── ① 식별 (critic.yml 1순위: resolve 스크립트. sentinel unset 이면 빈값 전달 → 폴백) ──
  if [ -f "$RESOLVE_SH" ]; then
    state_file="$(VERDICT_STATE_DIR="$VERDICT_STATE_DIR" PARENT_URL="$PARENT_URL" \
      REVIEW_STATE_SENTINEL="${REVIEW_STATE_SENTINEL:-}" \
      bash "$RESOLVE_SH" critic 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$state_file" ]; then
      match_count=1
    else
      match_count=0
      state_file=""
    fi
  fi

  # ── ②③ marker(-nt) stale 검증 + verdict 읽기 ──
  # 아래 STATE_FILE 변수명은 critic.yml 스니펫과 문자 일치를 위해 의도적으로 동일하게 쓴다.
  local STATE_FILE="$state_file"
  if [ "$match_count" -eq 1 ]; then
    # >>> parse-critic-verdict.sh 와 문자 그대로 동일 (anti-drift; MS-DRIFT 가 동기화 단언) >>>
    if [ -z "${CRITIC_RUN_MARKER:-}" ] || [ ! -e "$CRITIC_RUN_MARKER" ]; then
      CRITIC_VERDICT="indeterminate"
    elif [ ! "$STATE_FILE" -nt "$CRITIC_RUN_MARKER" ]; then
      CRITIC_VERDICT="indeterminate"
    else
      CRITIC_VERDICT=$(jq -r '.aggregate.verdict // empty' "$STATE_FILE" 2>/dev/null || echo "")
      if [ -z "$CRITIC_VERDICT" ]; then
        CRITIC_VERDICT="indeterminate"
      fi
    fi
    # <<< critic.yml 동일 구간 끝 <<<
  else
    CRITIC_VERDICT="indeterminate"
  fi

  # critic.yml 의 enum allowlist 정규화와 동일.
  case "$CRITIC_VERDICT" in
    pass|concerns|blocker) ;;
    *) CRITIC_VERDICT="indeterminate" ;;
  esac
  critic_verdict="$CRITIC_VERDICT"
  printf '%s\n' "$critic_verdict"
}

# MS-1 — sentinel 식별 + fresh(상태파일이 marker 보다 newer) → verdict=pass 읽힘
it "MS-1 sentinel 식별 + fresh → pass"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  state="$dir/my-slug.json"
  write_state_json "$state" "$purl" "pass"
  sentinel="$dir/.sentinel"
  printf '%s\n' "$state" > "$sentinel"
  marker="$dir/.critic-run-marker"
  # marker 를 먼저 만들고, sleep 1 후 상태파일을 touch → 상태파일 mtime > marker (fresh).
  touch "$marker"
  sleep 1
  touch "$state"
  out="$(VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    CRITIC_RUN_MARKER="$marker" resolve_and_judge)"
  assert_eq "pass" "$out" "fresh 인데 pass 로 안 읽힘" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# MS-2 — sentinel 식별 + stale(상태파일이 marker 보다 older) → indeterminate
# (이슈 #14-② 의 핵심 시나리오)
it "MS-2 sentinel 식별 + stale → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  state="$dir/my-slug.json"
  write_state_json "$state" "$purl" "pass"
  sentinel="$dir/.sentinel"
  printf '%s\n' "$state" > "$sentinel"
  marker="$dir/.critic-run-marker"
  # 상태파일을 먼저 만들고, sleep 1 후 marker 를 touch → 상태파일 mtime < marker (stale).
  touch "$state"
  sleep 1
  touch "$marker"
  out="$(VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    CRITIC_RUN_MARKER="$marker" resolve_and_judge)"
  assert_eq "indeterminate" "$out" "stale 인데 indeterminate 로 강등 안 됨(낡은 pass 오신뢰)" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# MS-3 — marker 부재(CRITIC_RUN_MARKER 가 가리키는 파일 없음) → indeterminate
it "MS-3 marker 부재 → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  state="$dir/my-slug.json"
  write_state_json "$state" "$purl" "pass"
  sentinel="$dir/.sentinel"
  printf '%s\n' "$state" > "$sentinel"
  # marker 파일을 일부러 만들지 않는다 → -e 검사 실패 → indeterminate.
  marker="$dir/.critic-run-marker-absent"
  out="$(VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" REVIEW_STATE_SENTINEL="$sentinel" \
    CRITIC_RUN_MARKER="$marker" resolve_and_judge)"
  assert_eq "indeterminate" "$out" "marker 부재인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# MS-4 — sentinel 없음(resolve 스크립트 내부 폴백) + stale → indeterminate
#   주의: 여기서 "폴백"은 resolve-review-statefile.sh 의 내부 .parent.url 정확매칭
#   폴백이다(RESOLVE_SH 가 repo 에 존재하므로). critic.yml 의 "인라인 폴백"(Pipeline
#   미체크아웃 → RESOLVE_SH 부재 시 yml 안에서 직접 매칭)과는 다른 경로다. 이 케이스
#   목적은 "어느 식별 경로든 그 뒤의 marker -nt stale 검증이 공통 적용됨"을 고정하는 것.
it "MS-4 sentinel 없음(resolve 내부 폴백) + stale → indeterminate"
(
  dir="$(mktemp -d)"
  purl="https://github.com/org/Repo/issues/3"
  state="$dir/slug.json"
  # 정확매칭 1개(폴백 식별 성공) + 오답 파일 1개
  write_state_json "$state" "$purl" "pass"
  write_state_json "$dir/noise.json" "https://github.com/org/Repo/issues/30" "pass"
  marker="$dir/.critic-run-marker"
  # 상태파일 먼저, marker 나중 → stale.
  touch "$state"
  sleep 1
  touch "$marker"
  # REVIEW_STATE_SENTINEL 명시적으로 unset → resolve 스크립트가 폴백 정확매칭 경로를 탐.
  # (resolve_and_judge 는 ${REVIEW_STATE_SENTINEL:-} 로 읽으므로 unset 이면 빈값 전달.)
  unset REVIEW_STATE_SENTINEL
  export VERDICT_STATE_DIR="$dir" PARENT_URL="$purl" CRITIC_RUN_MARKER="$marker"
  out="$(resolve_and_judge)"
  assert_eq "indeterminate" "$out" "폴백 stale 인데 indeterminate 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# MS-DRIFT — anti-drift 가드: parse-critic-verdict.sh 에 stale 검증 핵심 라인이 존재하는지 grep.
# 위 resolve_and_judge 의 -nt 스니펫은 parse-critic-verdict.sh 와 문자 일치를 전제로 한다.
# 그 검증을 바꾸면 이 케이스가 fail 해 동기화를 강제한다(#99 이후 추출본이 SSOT).
it "MS-DRIFT parse-critic-verdict.sh stale 검증 라인 존재(동기화 가드)"
(
  # needle 은 스크립트 raw 텍스트와 매칭할 고정문자열이라 변수 확장을 의도적으로 막는다.
  # shellcheck disable=SC2016
  needle='[ ! "$STATE_FILE" -nt "$CRITIC_RUN_MARKER" ]'
  if [ ! -f "$PARSE_SH" ]; then
    fail "parse-critic-verdict.sh 를 찾을 수 없음: $PARSE_SH"
    return
  fi
  # -F 고정문자열 매칭(정규식 메타문자 회피). 1건 이상이어야 통과.
  if grep -qF -- "$needle" "$PARSE_SH"; then
    pass
  else
    fail "parse-critic-verdict.sh stale 검증 로직이 변경됨 — 이 테스트(resolve_and_judge 의 -nt 스니펫)를 동기화하라"
  fi
)
