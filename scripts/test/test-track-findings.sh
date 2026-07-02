#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# 각 테스트는 서브셸(...)이고 GH_LOG 를 export 해 gh stub 자식이 읽게 한다 —
# SC2030/2031(서브셸 지역화)은 의도된 격리라 무시(같은 서브셸 안에서만 읽고 쓴다).
# shellcheck disable=SC2034,SC2030,SC2031
# track-findings.sh 오케스트레이션 단위테스트 (#104 M9).
#   action.yml 에서 추출한 셸 로직(파일부재 graceful·finding 추출·intra/cross-run dedup·
#   대상 레포 라우팅·라벨 멱등생성·라벨 미존재 폴백)을 gh stub 으로 고정한다.
#   render-finding.py(순수 렌더)는 test-render-finding.sh 가 담당 — 여기선 "몇 개를 어디에
#   만드느냐/거르느냐"(dedup·라우팅·graceful)를 검증한다.

TF_SH="$REPO_ROOT/scripts/track-findings.sh"

# gh stub 을 임시 PATH 에 깔고 track-findings.sh 를 실행한다.
#   - gh label create → 성공(로그)
#   - gh issue list ... --jq length → GH_STUB_LIST_COUNT(기본 0) 출력 → cross-run dedup 제어
#   - gh issue create → 성공. 단 GH_STUB_LABEL_FAIL=1 이면 '--label' 붙은 생성은 실패(#5 폴백 유발)
# 모든 gh 호출은 GH_LOG 에 'gh <args>' 로 기록.
run_tf() {
  local bindir; bindir="$(mktemp -d)"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
if [ "$1" = "label" ] && [ "$2" = "create" ]; then exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${GH_STUB_LIST_COUNT:-0}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  case " $* " in
    *" --label "*) [ "${GH_STUB_LABEL_FAIL:-0}" = "1" ] && exit 1 ;;
  esac
  exit 0
fi
exit 0
STUB
  chmod +x "$bindir/gh"
  GH_LOG="${GH_LOG}" PATH="$bindir:$PATH" bash "$TF_SH"
}

# 상태파일 생성 헬퍼 — JSON 문자열을 임시파일에 쓰고 경로 반환.
write_state() {
  local f; f="$(mktemp)"
  printf '%s' "$1" > "$f"
  printf '%s' "$f"
}

# code-review 상태파일: area 아래 codeReview 배열.
cr_state() {
  # $1: area, $2: findings JSON 배열
  write_state "{\"prs\":{\"$1\":{\"findings\":{\"codeReview\":$2}}}}"
}

# TF-1 — 상태파일 부재 → graceful(exit 0), 이슈 생성 시도 없음
it "TF-1 상태파일 부재 → graceful, 생성 없음"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  out="$(STATE_FILE_PATH="/no/such/file.json" FINDING_SOURCE=code-review \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x run_tf 2>&1)" || { fail "graceful exit 아님"; exit 0; }
  assert_contains "$out" "상태파일 없음" "부재 경고 누락" || exit 0
  assert_eq 0 "$(count_gh_log 'issue create')" "부재인데 이슈 생성 시도함" || exit 0
  pass
)

# TF-2 — major/minor 만 추적, 그 외(nit)는 걸러진다
it "TF-2 nit 만 있으면 추적할 finding 없음"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(cr_state Backend '[{"severity":"nit","file":"a.ts","title":"t","description":"d"}]')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=code-review \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "추적할 finding 없음" "nit 가 안 걸러짐" || exit 0
  assert_eq 0 "$(count_gh_log 'issue create')" "nit 인데 이슈 생성됨" || exit 0
  pass
)

# TF-3 — code-review 정상: major 1건 → 대상 AREA_REPO 에 이슈 1건 생성 + 라벨 멱등생성
it "TF-3 code-review 1건 → AREA_REPO 에 생성, 라벨 멱등"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(cr_state Backend '[{"severity":"major","file":"a.ts","line":3,"title":"버그","description":"원인"}]')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=code-review \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x GH_STUB_LIST_COUNT=0 run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "완료 — 생성 1, 스킵 0" "생성 카운트 불일치" || exit 0
  # 대상 레포 라우팅 — AREA_REPO 로 생성
  assert_eq 1 "$(count_gh_log 'issue create --repo acme/Backend')" "AREA_REPO 라우팅 실패" || exit 0
  # 라벨 멱등생성 — major/minor 둘 다 시도
  assert_eq 1 "$(count_gh_log 'label create maj --repo acme/Backend')" "major 라벨 생성 누락" || exit 0
  assert_eq 1 "$(count_gh_log 'label create min --repo acme/Backend')" "minor 라벨 생성 누락" || exit 0
  pass
)

# TF-4 — intra-run dedup: 같은 finding 2건(같은 fp) → 1건만 생성, 1건 스킵
it "TF-4 intra-run 중복 → 1건만 생성"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  dup='{"severity":"major","file":"a.ts","title":"동일","description":"동일설명"}'
  sf="$(cr_state Backend "[$dup,$dup]")"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=code-review \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x GH_STUB_LIST_COUNT=0 run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "intra-run 중복" "intra dedup 미동작" || exit 0
  assert_contains "$out" "완료 — 생성 1, 스킵 1" "intra dedup 카운트 불일치" || exit 0
  assert_eq 1 "$(count_gh_log 'issue create --repo')" "intra 중복인데 2건 생성됨" || exit 0
  pass
)

# TF-5 — cross-run dedup: 이미 오픈 이슈 존재(list count>0) → 생성 안 함
it "TF-5 cross-run 기존 이슈 존재 → 생성 안 함"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(cr_state Backend '[{"severity":"major","file":"a.ts","title":"버그","description":"원인"}]')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=code-review \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x GH_STUB_LIST_COUNT=1 run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "이미 오픈 이슈 존재" "cross-run dedup 미동작" || exit 0
  assert_contains "$out" "완료 — 생성 0, 스킵 1" "cross-run dedup 카운트 불일치" || exit 0
  assert_eq 0 "$(count_gh_log 'issue create --repo')" "기존 존재인데 생성됨" || exit 0
  pass
)

# TF-6 — critic 모드: PARENT_REPO 로 라우팅, 서로 다른 area 2건 모두 생성(#1 소실 방지)
it "TF-6 critic — PARENT_REPO 라우팅 + area 다르면 2건 다 생성"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(write_state '{"aggregate":{"criticFindings":[
    {"severity":"major","area":"Backend","title":"동일 제목","description":"d"},
    {"severity":"major","area":"iOS","title":"동일 제목","description":"d"}
  ]}}')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=critic \
    OWNER=acme AREA='' AREA_REPO='' PARENT_REPO=acme/parent \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x GH_STUB_LIST_COUNT=0 run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "완료 — 생성 2, 스킵 0" "area 다른 2건이 다 안 생성됨(#1)" || exit 0
  assert_eq 2 "$(count_gh_log 'issue create --repo acme/parent')" "PARENT_REPO 라우팅/건수 불일치" || exit 0
  pass
)

# TF-7 — critic 모드에 parent-repo 없으면 스킵(graceful)
it "TF-7 critic — parent-repo 없으면 스킵"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(write_state '{"aggregate":{"criticFindings":[{"severity":"major","area":"Backend","title":"t","description":"d"}]}}')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=critic \
    OWNER=acme AREA='' AREA_REPO='' PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "critic 모드엔 parent-repo 필요" "parent-repo 가드 미동작" || exit 0
  assert_eq 0 "$(count_gh_log 'issue create')" "parent-repo 없는데 생성됨" || exit 0
  pass
)

# TF-8 — 알 수 없는 finding-source → 스킵(graceful)
it "TF-8 알 수 없는 finding-source → 스킵"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(cr_state Backend '[{"severity":"major","file":"a.ts","title":"t","description":"d"}]')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=bogus \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "알 수 없는 finding-source" "source 가드 미동작" || exit 0
  assert_eq 0 "$(count_gh_log 'issue create')" "잘못된 source 인데 생성됨" || exit 0
  pass
)

# TF-9 — 라벨 미존재 폴백(#5): --label 생성이 실패해도 라벨 없이 재시도해 이슈는 만든다
it "TF-9 라벨 실패 시 라벨 없이 재시도 생성(#5)"
(
  export GH_LOG; GH_LOG="$(mktemp)"
  sf="$(cr_state Backend '[{"severity":"major","file":"a.ts","title":"버그","description":"원인"}]')"
  out="$(STATE_FILE_PATH="$sf" FINDING_SOURCE=code-review \
    OWNER=acme AREA=Backend AREA_REPO=acme/Backend PARENT_REPO='' \
    MAJOR_LABEL=maj MINOR_LABEL=min GH_TOKEN=x GH_STUB_LIST_COUNT=0 GH_STUB_LABEL_FAIL=1 run_tf 2>&1)" || { fail "exit 비0"; exit 0; }
  assert_contains "$out" "라벨(maj) 없이 이슈 생성" "라벨 폴백 미동작(#5)" || exit 0
  assert_contains "$out" "완료 — 생성 1" "폴백 경로에서 생성 카운트 누락" || exit 0
  pass
)
