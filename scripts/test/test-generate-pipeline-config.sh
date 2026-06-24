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

# T-GPC-7: self-check 거부 — owner·project-number 는 있지만 GraphQL 식별자(project-id·
#   status-field-id·area-field-id)가 누락된 config → 배치 거부(대상 미생성).
#   (P4 self-check 5키 확장의 실패경로 — 옛 2키 검증으로는 통과하던 불완전 config 를 잡는다.)
it "T-GPC-7 self-check 거부: project-id 등 GraphQL 식별자 누락 config 는 배치 거부(대상 미생성)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
  # owner·project-number 는 채우되 claude-commands 의 GraphQL 식별자 3키는 비운 config.
  #   (옛 2키 self-check 라면 통과하지만, 5키 확장 후엔 거부돼야 한다.)
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
  generate_pipeline_config >/dev/null 2>&1 || rc=$?
  rm -f "$bad_config"
  assert_ne "0" "$rc" "GraphQL 식별자 누락인데 0 종료(5키 self-check 미작동)" || return
  assert_file_absent "$WORKING_DIR/.claude/pipeline-config.yml" "거부됐는데 대상 파일이 생성됨(원자성 위반)" && pass
)

# T-GPC-8: self-check 거부 — status-field-id 만 누락(나머지 4키는 채움) → 배치 거부.
#   (5키 중 어느 하나라도 비면 fail-fast 하는지 — AND 의미론 확인.)
it "T-GPC-8 self-check 거부: status-field-id 단일 누락도 배치 거부"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  WORKING_DIR="$(_mk_workdir)"
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
