#!/usr/bin/env bash
# generate_pipeline_config 단위 테스트 (P3.2)
#
# 검증 대상:
#   T-GPC-1: 정상 config → $WORKING_DIR/.claude/pipeline-config.yml 로 복사됨(내용 동일)
#   T-GPC-2: 복사된 config 를 런타임 리더로 다시 읽으면 owner·project-number 가 동일(parity)
#   T-GPC-3: WORKING_DIR 비면 에러(exit≠0), 파일 미생성
#   T-GPC-4: self-check 거부 — owner 빈 config 는 배치 거부(exit≠0), 대상 파일 미생성
#   T-GPC-5: 멱등 — 두 번 실행해도 안전(동일 내용으로 수렴)
#   T-GPC-6: 입력 config 없으면 에러(exit≠0)
#
# setup_install_env 가 install.sh 를 source 하고 CONFIG_FILE 을 세팅한다.
# WORKING_DIR 은 parse_config(eval)로 세팅되거나 테스트에서 직접 지정.
# shellcheck disable=SC2034

# 헬퍼 — 임시 워크스페이스 디렉토리 생성
_mk_workdir() { mktemp -d; }

# T-GPC-1: 정상 config → 복사됨(내용 동일)
it "T-GPC-1 정상 config: .claude/pipeline-config.yml 로 복사(내용 동일)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  generate_pipeline_config >/dev/null 2>&1 || { fail "generate_pipeline_config 가 0 이 아닌 코드로 종료"; return; }
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  assert_file_present "$dest" "config 가 복사되지 않음" || return
  # 내용이 입력과 바이트 동일해야 함(복사 방식 — 재직렬화 금지)
  if ! diff -q "$FIXTURES_DIR/config-basic.yml" "$dest" >/dev/null 2>&1; then
    fail "복사된 config 가 입력과 다름(재직렬화 의심)"; return
  fi
  pass
)

# T-GPC-2: parity — 복사본을 런타임 리더로 읽으면 핵심 5키가 입력값과 일치
it "T-GPC-2 parity: 복사본을 리더로 읽으면 필수 5키 일치"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  generate_pipeline_config >/dev/null 2>&1 || { fail "generate 실패"; return; }
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  reader="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
  owner="$(PIPELINE_CONFIG="$dest" bash "$reader" owner 2>/dev/null)"
  pnum="$(PIPELINE_CONFIG="$dest" bash "$reader" project-number 2>/dev/null)"
  pid="$(PIPELINE_CONFIG="$dest" bash "$reader" project-id 2>/dev/null)"
  sfid="$(PIPELINE_CONFIG="$dest" bash "$reader" status-field-id 2>/dev/null)"
  afid="$(PIPELINE_CONFIG="$dest" bash "$reader" area-field-id 2>/dev/null)"
  assert_eq "test-org" "$owner" "owner parity 깨짐" || return
  assert_eq "1" "$pnum" "project-number parity 깨짐" || return
  assert_eq "PVT_test0000" "$pid" "project-id parity 깨짐" || return
  assert_eq "PVTSSF_teststatus0000" "$sfid" "status-field-id parity 깨짐" || return
  assert_eq "PVTSSF_testarea0000" "$afid" "area-field-id parity 깨짐" && pass
)

# T-GPC-3: WORKING_DIR 비면 에러 + 파일 미생성
it "T-GPC-3 WORKING_DIR 비면 에러(파일 미생성)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR=""
  rc=0
  generate_pipeline_config >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "WORKING_DIR 빈데 0 종료(에러로 막지 못함)" && pass
)

# T-GPC-4: self-check 거부 — owner 빈 config → 배치 거부(대상 미생성)
it "T-GPC-4 self-check 거부: owner 빈 config 는 배치 거부(대상 미생성)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  # owner 가 빈 잘못된 config 를 임시 생성해 입력으로 지정
  bad_config="$(mktemp)"
  cat > "$bad_config" <<'YML'
project:
  owner:
  parent-repository: test-org/parent-repo
  project-numbers: []
  working-directory: /tmp/test-workspace
YML
  CONFIG_FILE="$bad_config"
  rc=0
  generate_pipeline_config >/dev/null 2>&1 || rc=$?
  rm -f "$bad_config"
  assert_ne "0" "$rc" "잘못된 config 인데 0 종료(self-check 미작동)" || return
  # self-check 실패 시 대상 파일이 남으면 안 됨(원자성)
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "거부됐는데 대상 파일이 생성됨(원자성 위반)" && pass
)

# T-GPC-5: 멱등 — 두 번 실행해도 안전, 동일 내용으로 수렴
it "T-GPC-5 멱등: 두 번 실행해도 입력과 동일 내용"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  generate_pipeline_config >/dev/null 2>&1 || { fail "1차 generate 실패"; return; }
  generate_pipeline_config >/dev/null 2>&1 || { fail "2차 generate 실패(멱등 깨짐)"; return; }
  if ! diff -q "$FIXTURES_DIR/config-basic.yml" "$dest" >/dev/null 2>&1; then
    fail "재실행 후 내용이 입력과 다름"; return
  fi
  pass
)

# T-GPC-6: 입력 config 없으면 에러
it "T-GPC-6 입력 config 부재: 에러(파일 미생성)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  CONFIG_FILE="/nonexistent/does-not-exist-$$.yml"
  rc=0
  generate_pipeline_config >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "입력 config 없는데 0 종료" || return
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "입력 없는데 대상 생성됨" && pass
)

# T-GPC-7: self-check 거부 — GraphQL 식별자 3키 누락 + 자동조회도 실패(stub 미설정)
#   → 배치 거부(대상 미생성). A안 "명시 > 자동 > 실패"의 실패경로(둘 다 없으면 fail-fast).
it "T-GPC-7 self-check 거부: GraphQL 식별자 누락 + 자동조회 실패 → 배치 거부(대상 미생성)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  unset GH_STUB_PROJECT_TSV   # 자동조회 실패 시뮬(graphql exit 1)
  # owner·project-number 는 채우되 claude-commands 의 GraphQL 식별자 3키는 비운 config.
  bad_config="$(mktemp)"
  cat > "$bad_config" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
claude-commands:
  enabled: false
YML
  CONFIG_FILE="$bad_config"
  rc=0
  err="$(generate_pipeline_config 2>&1)" || rc=$?
  rm -f "$bad_config"
  assert_ne "0" "$rc" "자동조회 실패 + 식별자 누락인데 0 종료(self-check 미작동)" || return
  # codex Finding 3 — 실패가 어떤 키 때문인지 사용자에게 보여야 함(리더 stderr 노출).
  assert_contains "$err" "project-id" "실패 메시지에 누락 키(project-id) 미노출" || return
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "거부됐는데 대상 파일이 생성됨(원자성 위반)" && pass
)

# T-GPC-8: self-check 거부 — status-field-id 만 누락 + 자동조회 실패 → 배치 거부.
#   (자동조회 실패 시 채워지지 않은 단일 키도 fail-fast — AND 의미론 확인.)
it "T-GPC-8 self-check 거부: status-field-id 단일 누락 + 자동조회 실패도 배치 거부"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  unset GH_STUB_PROJECT_TSV   # 자동조회 실패 시뮬
  bad_config="$(mktemp)"
  cat > "$bad_config" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
claude-commands:
  enabled: false
  project-id: PVT_test0000
  area-field-id: PVTSSF_testarea0000
YML
  CONFIG_FILE="$bad_config"
  rc=0
  generate_pipeline_config >/dev/null 2>&1 || rc=$?
  rm -f "$bad_config"
  assert_ne "0" "$rc" "status-field-id 누락인데 0 종료(단일키 누락 미검출)" || return
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "거부됐는데 대상 파일 생성됨" && pass
)

# ── 자동조회(A안 "명시 > 자동 > 실패") 신규 테스트 ──────────────────────
# 공통: claude-commands 의 GraphQL 식별자 3키가 빈 config 를 만들고 gh stub 의
#   GH_STUB_PROJECT_TSV 로 자동조회 결과를 주입한다. reviewer.enabled=false 로 둬
#   reviewer-* 조건부 require 가 끼어들지 않게 한다.

# 빈 GraphQL 3키 config 생성 헬퍼 — <owner> <project-number> 받아 임시파일 경로 출력.
_mk_empty_ids_config() {
  local cfg; cfg="$(mktemp)"
  cat > "$cfg" <<YML
project:
  owner: ${1:-test-org}
  parent-repository: test-org/parent-repo
  project-numbers: [${2:-1}]
  working-directory: /tmp/test-workspace
reviewer:
  enabled: false
claude-commands:
  enabled: false
  project-id: ""
  status-field-id: ""
  area-field-id: ""
YML
  printf '%s\n' "$cfg"
}

# T-GPC-9: 자동조회 성공 — 빈 3키 + GH_STUB_PROJECT_TSV → dest 의 claude-commands 에 3키 채워짐.
it "T-GPC-9 자동조회 성공: 빈 3키가 자동조회값으로 채워져 배치됨"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export GH_STUB_PROJECT_TSV=$'PVT_auto0001\tPVTSSF_autostatus\tPVTSSF_autoarea'
  cfg="$(_mk_empty_ids_config test-org 7)"
  CONFIG_FILE="$cfg"
  generate_pipeline_config >/dev/null 2>&1 || { fail "자동조회 성공인데 generate 실패"; rm -f "$cfg"; return; }
  rm -f "$cfg"
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  assert_file_present "$dest" "자동조회 후 dest 미생성" || return
  reader="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
  assert_eq "PVT_auto0001"      "$(PIPELINE_CONFIG="$dest" bash "$reader" project-id 2>/dev/null)"      "project-id 자동주입 실패" || return
  assert_eq "PVTSSF_autostatus" "$(PIPELINE_CONFIG="$dest" bash "$reader" status-field-id 2>/dev/null)" "status-field-id 자동주입 실패" || return
  assert_eq "PVTSSF_autoarea"   "$(PIPELINE_CONFIG="$dest" bash "$reader" area-field-id 2>/dev/null)"   "area-field-id 자동주입 실패" && pass
)

# T-GPC-10: 명시 우선 — 3키가 이미 명시된 config + stub → 자동조회 호출 안 함 + 명시값 보존.
it "T-GPC-10 명시 우선: 3키 명시 config 는 자동조회 안 함(명시값 보존)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  # stub 이 설정돼 있어도 명시값이 있으면 graphql 을 호출하면 안 됨.
  export GH_STUB_PROJECT_TSV=$'PVT_should_not_use\tPVTSSF_x\tPVTSSF_y'
  : > "$GH_LOG"   # 로그 초기화
  cfg="$(mktemp)"
  cat > "$cfg" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
reviewer:
  enabled: false
claude-commands:
  enabled: false
  project-id: PVT_explicit
  status-field-id: PVTSSF_explicit_s
  area-field-id: PVTSSF_explicit_a
YML
  CONFIG_FILE="$cfg"
  generate_pipeline_config >/dev/null 2>&1 || { fail "명시 config generate 실패"; rm -f "$cfg"; return; }
  rm -f "$cfg"
  # graphql 호출이 없어야 함(명시값이라 자동조회 스킵)
  assert_eq "0" "$(count_gh_log 'api graphql')" "명시값인데 자동조회(graphql) 호출됨" || return
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  reader="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
  assert_eq "PVT_explicit" "$(PIPELINE_CONFIG="$dest" bash "$reader" project-id 2>/dev/null)" "명시 project-id 가 덮어써짐" && pass
)

# T-GPC-11: 부분 자동조회(Area 못 찾음) — area 칸 빈 tsv → area-field-id 비어 self-check fail-fast.
#   (Status·project-id 는 채워지지만 area 누락으로 거부 — 명시 폴백 필요함을 검증.)
it "T-GPC-11 부분 자동조회: Area 못 찾으면 area-field-id 누락으로 배치 거부"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export GH_STUB_PROJECT_TSV=$'PVT_auto\tPVTSSF_s\t'   # area 칸 빈값
  cfg="$(_mk_empty_ids_config test-org 1)"
  CONFIG_FILE="$cfg"
  rc=0
  err="$(generate_pipeline_config 2>&1)" || rc=$?
  rm -f "$cfg"
  assert_ne "0" "$rc" "area 미발견인데 0 종료(부분조회 후 fail-fast 미작동)" || return
  assert_contains "$err" "area-field-id" "실패 메시지에 누락 키(area-field-id) 미노출" || return
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "거부됐는데 대상 생성됨" && pass
)

# T-GPC-12: reviewer 조건부 require — reviewer.enabled=true + reviewer 키 누락 → fail-fast.
it "T-GPC-12 reviewer 조건부: enabled=true + reviewer 키 누락 → 배치 거부"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export REVIEWER_ENABLED=true   # parse_config 가 emit 하는 변수 — 메인흐름 모사
  export GH_STUB_PROJECT_TSV=$'PVT_x\tPVTSSF_s\tPVTSSF_a'   # 5키는 채워지게
  cfg="$(mktemp)"
  cat > "$cfg" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
reviewer:
  enabled: true
claude-commands:
  enabled: false
  project-id: PVT_x
  status-field-id: PVTSSF_s
  area-field-id: PVTSSF_a
YML
  CONFIG_FILE="$cfg"
  rc=0
  err="$(generate_pipeline_config 2>&1)" || rc=$?
  rm -f "$cfg"
  assert_ne "0" "$rc" "reviewer.enabled=true + reviewer 키 누락인데 0 종료(조건부 require 미작동)" || return
  assert_contains "$err" "reviewer-app-id" "실패 메시지에 reviewer 누락 키 미노출" && pass
)

# T-GPC-13: reviewer 조건부 — reviewer.enabled=false + reviewer 키 누락 → 통과(3키 충족 전제).
it "T-GPC-13 reviewer 조건부: enabled=false 면 reviewer 키 없어도 통과"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export REVIEWER_ENABLED=false
  cfg="$(mktemp)"
  cat > "$cfg" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
reviewer:
  enabled: false
claude-commands:
  enabled: false
  project-id: PVT_x
  status-field-id: PVTSSF_s
  area-field-id: PVTSSF_a
YML
  CONFIG_FILE="$cfg"
  generate_pipeline_config >/dev/null 2>&1 || { fail "enabled=false 인데 reviewer 키 누락으로 거부됨"; rm -f "$cfg"; return; }
  rm -f "$cfg"
  assert_file_present "$WORKING_DIR/.claude/pipeline-config.yml" "통과해야 하는데 대상 미생성" && pass
)

# ── 적대적 코드리뷰 CONFIRMED 버그 회귀 테스트 (A~E) ──────────────────────

# T-GPC-14 (버그 D): org NOT_FOUND + user 응답 → user 폴백으로 채워져 배치(개인계정 시나리오).
#   org env 미설정(=org 쿼리 NOT_FOUND→exit1) + GH_STUB_PROJECT_TSV_USER 만 설정.
it "T-GPC-14 (D) org NOT_FOUND + user 응답: user 폴백으로 자동조회 성공"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  unset GH_STUB_PROJECT_TSV GH_STUB_PROJECT_TSV_ORG   # org 쿼리는 NOT_FOUND
  export GH_STUB_PROJECT_TSV_USER=$'PVT_useracct\tPVTSSF_us\tPVTSSF_ua'
  cfg="$(_mk_empty_ids_config myuser 5)"
  CONFIG_FILE="$cfg"
  generate_pipeline_config >/dev/null 2>&1 || { fail "user 폴백 가능한데 generate 실패"; rm -f "$cfg"; return; }
  rm -f "$cfg"; unset GH_STUB_PROJECT_TSV_USER
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  reader="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
  assert_eq "PVT_useracct" "$(PIPELINE_CONFIG="$dest" bash "$reader" project-id 2>/dev/null)" "user 폴백 project-id 미주입" || return
  assert_eq "PVTSSF_ua"    "$(PIPELINE_CONFIG="$dest" bash "$reader" area-field-id 2>/dev/null)" "user 폴백 area-field-id 미주입" && pass
)

# T-GPC-15 (버그 D): org/user 둘 다 NOT_FOUND → 자동조회 실패 → self-check fail-fast(배치 거부).
it "T-GPC-15 (D) org/user 둘 다 실패: 자동조회 실패 → 배치 거부"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  unset GH_STUB_PROJECT_TSV GH_STUB_PROJECT_TSV_ORG GH_STUB_PROJECT_TSV_USER   # 둘 다 NOT_FOUND
  cfg="$(_mk_empty_ids_config nobody 9)"
  CONFIG_FILE="$cfg"
  rc=0
  generate_pipeline_config >/dev/null 2>&1 || rc=$?
  rm -f "$cfg"
  assert_ne "0" "$rc" "org/user 둘 다 실패인데 0 종료(fail-fast 미작동)" || return
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "거부됐는데 대상 생성됨" && pass
)

# T-GPC-16 (버그 A): 인라인 주석 헤더(`claude-commands:  # x`) → upsert 가 리더 parity 헤더로
#   복구해 self-check 통과(방금 채운 키를 리더가 읽음). parity 깨졌으면 거부됐을 것.
it "T-GPC-16 (A) 인라인 주석 헤더: upsert↔reader 헤더 parity 로 self-check 통과"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export GH_STUB_PROJECT_TSV=$'PVT_hdr\tPVTSSF_hs\tPVTSSF_ha'   # org 응답(별칭)
  cfg="$(mktemp)"
  # 헤더에 인라인 주석 — 리더 section() 은 이 헤더를 섹션으로 못 읽는다.
  cat > "$cfg" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
reviewer:
  enabled: false
claude-commands:  # 인라인 주석 헤더 — 리더 parity 깨짐 재현
  project-id: ""
  status-field-id: ""
  area-field-id: ""
YML
  CONFIG_FILE="$cfg"
  generate_pipeline_config >/dev/null 2>&1 || { fail "인라인 주석 헤더 — upsert 가 parity 복구 못 해 self-check 실패"; rm -f "$cfg"; return; }
  rm -f "$cfg"
  dest="$WORKING_DIR/.claude/pipeline-config.yml"
  reader="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
  assert_eq "PVT_hdr" "$(PIPELINE_CONFIG="$dest" bash "$reader" project-id 2>/dev/null)" "parity 복구 후 project-id 미읽힘" && pass
)

# T-GPC-17 (버그 B): claude-commands.plan 서브블록에 동명 project-id 가 먼저 있어도
#   upsert 는 직속 키만 채우고 서브블록 키는 보존한다(임의 들여쓰기 첫 매칭 오작동 방지).
it "T-GPC-17 (B) 중첩키: upsert 가 claude-commands 직속 키만 채움(plan 서브블록 보존)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"   # install.sh source — upsert 함수 로드됨
  cfg="$(mktemp)"
  cat > "$cfg" <<'YML'
claude-commands:
  enabled: false
  plan:
    project-id: NESTED_KEEP
  project-id: ""
YML
  upsert_claude_command_key "$cfg" project-id AUTO_DIRECT
  # 서브블록 값 보존 + 직속만 채워졌는지 확인
  nested="$(grep -c 'project-id: NESTED_KEEP' "$cfg")"
  direct="$(grep -c 'project-id: "AUTO_DIRECT"' "$cfg")"
  rm -f "$cfg"
  assert_eq "1" "$nested" "plan 서브블록 project-id 가 변형됨(직속만 건드려야 함)" || return
  assert_eq "1" "$direct" "직속 project-id 가 자동조회값으로 안 채워짐" && pass
)

# T-GPC-18 (버그 E): 부분 자동조회(area 칸 빔)면 "자동조회 성공" 대신 못 채운 키 알리는
#   중립 경고 — 직후 self-check 실패와 모순되는 "성공" 메시지를 내지 않는다.
it "T-GPC-18 (E) 부분 자동조회: '성공' 대신 못 채운 키 안내(area-field-id)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export GH_STUB_PROJECT_TSV=$'PVT_part\tPVTSSF_ps\t'   # area 칸 빈값(부분조회)
  cfg="$(_mk_empty_ids_config test-org 1)"
  CONFIG_FILE="$cfg"
  out="$(generate_pipeline_config 2>&1 || true)"
  rm -f "$cfg"
  assert_contains "$out" "일부만 채움" "부분조회인데 성공/중립 메시지 미출력" || return
  assert_not_contains "$out" "자동조회 성공" "부분조회인데 '자동조회 성공' 오출력(모순)" && pass
)

# T-GPC-19 (버그 C): reviewer.enabled 판정이 tmp_file 출처여야 함 — 전역 REVIEWER_ENABLED 가
#   엇갈려도(=true) tmp_file 이 enabled:false 면 reviewer 키 require 가 끼지 않아 통과.
it "T-GPC-19 (C) reviewer.enabled 판정 출처 = tmp_file (전역 변수 비의존)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  export REVIEWER_ENABLED=true   # 전역은 true 로 엇갈리게 — 그래도 tmp_file(false)이 출처여야
  cfg="$(mktemp)"
  cat > "$cfg" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/test-workspace
reviewer:
  enabled: false
claude-commands:
  enabled: false
  project-id: PVT_x
  status-field-id: PVTSSF_s
  area-field-id: PVTSSF_a
YML
  CONFIG_FILE="$cfg"
  generate_pipeline_config >/dev/null 2>&1 || { fail "tmp_file enabled=false 인데 전역 true 로 reviewer require 끼어 거부됨"; rm -f "$cfg"; unset REVIEWER_ENABLED; return; }
  rm -f "$cfg"; unset REVIEWER_ENABLED
  assert_file_present "$WORKING_DIR/.claude/pipeline-config.yml" "tmp_file 출처 판정 실패(통과해야 함)" && pass
)
