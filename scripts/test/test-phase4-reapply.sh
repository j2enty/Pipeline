#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Phase 4 — --reapply 부분 모드 (gh 스텁으로 end-to-end).
# T6 secret set 0회 + variable/label/api PUT 모듈수만큼
# T7 ENV_FILE 미생성·미변경 / T8 tracking.enabled=false면 label 안함
# T9 PIPELINE_REPO 없으면 exit1
#
# install.sh 를 bash 로 직접 실행(main 작동) + PATH 로 gh 스텁 가로채기.
# config-basic: 모듈 2개(ModuleA, ModuleB), tracking enabled, parent 있음.

# 공통 실행 헬퍼 — 분리된 GH_LOG·ENV_FILE 로 install.sh --reapply 실행
run_reapply() {
  local config="$1"; shift
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  REAPPLY_ENV="$(mktemp -u)"   # 존재하지 않는 .env 경로 (생성 여부 관찰용)
  bash "$INSTALL_SH" "$config" --reapply --non-interactive \
    --env-file "$REAPPLY_ENV" "$@" >/dev/null 2>&1
  return $?
}

# T6 — secret set 0회, variable/label/caller-yml 모듈수만큼
it "T6 --reapply: secret set 0회 + variables/labels/caller-yml 호출됨"
(
  run_reapply "$FIXTURES_DIR/config-basic.yml"
  sec="$(count_gh_log 'secret set')"
  assert_eq "0" "$sec" "reapply 인데 secret set 발생" || return
  # variable set — 모듈당 다수 호출. 2개 모듈 모두 처리됐는지: ModuleA·ModuleB variable 등장
  vars="$(count_gh_log 'variable set')"
  [ "$vars" -gt 0 ] || { fail "variable set 0회"; return; }
  # caller-yml: gh api PUT 가 모듈당 6개 yml(존재시). 최소 1회 이상
  puts="$(count_gh_log 'api -X PUT')"
  [ "$puts" -gt 0 ] || { fail "caller-yml api PUT 0회"; return; }
  # 라벨 (tracking enabled): label create 호출
  labels="$(count_gh_log 'label create')"
  [ "$labels" -gt 0 ] || { fail "label create 0회"; return; }
  pass
)

# T6b — 두 모듈 + parent 모두 처리 (레포명 등장 확인)
it "T6b --reapply: 두 모듈 + parent 레포 모두 등장"
(
  run_reapply "$FIXTURES_DIR/config-basic.yml"
  log="$(cat "$GH_LOG")"
  assert_contains "$log" "test-org/ModuleA" "ModuleA 미처리" || return
  assert_contains "$log" "test-org/ModuleB" "ModuleB 미처리" || return
  assert_contains "$log" "test-org/parent-repo" "parent 미처리" && pass
)

# T7 — ENV_FILE 미생성 (reapply 는 .env 안 건드림)
it "T7 --reapply: ENV_FILE 생성 안 됨"
(
  run_reapply "$FIXTURES_DIR/config-basic.yml"
  assert_file_absent "$REAPPLY_ENV" "reapply 가 .env 생성함" && pass
)

# T7b — 기존 .env 가 있으면 그대로 불변 (mtime·내용)
it "T7b --reapply: 기존 .env 내용 불변"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  existing_env="$(mktemp)"
  printf 'WEBHOOK_SECRET=operational_secret\nPORT=3000\n' > "$existing_env"
  before="$(cat "$existing_env")"
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" --reapply --non-interactive \
    --env-file "$existing_env" >/dev/null 2>&1
  after="$(cat "$existing_env")"
  assert_eq "$before" "$after" "reapply 가 기존 .env 변경함" && pass
  rm -f "$existing_env"
)

# T8 — tracking.enabled=false 면 label create 안 함
it "T8 --reapply + tracking=false: label create 0회"
(
  run_reapply "$FIXTURES_DIR/config-no-tracking.yml"
  labels="$(count_gh_log 'label create')"
  assert_eq "0" "$labels" "tracking=false 인데 label create 발생" || return
  # variables 는 여전히 등록됨 (tracking enabled var 도 false 값으로)
  vars="$(count_gh_log 'variable set')"
  [ "$vars" -gt 0 ] && pass || fail "variable set 0회"
)

# T9 — PIPELINE_REPO 없으면 exit 1
it "T9 --reapply + pipeline.repo 없음: exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  # pipeline 섹션 없는 임시 config
  bad_config="$(mktemp)"
  cat > "$bad_config" <<'YML'
project:
  owner: test-org
  parent-repository: test-org/parent-repo
  project-numbers: [1]
  working-directory: /tmp/x
modules:
  - name: ModuleA
    ci-workflow-name: ModuleA CI
reviewer:
  enabled: false
claude-commands:
  enabled: false
tracking:
  enabled: false
YML
  code=0
  bash "$INSTALL_SH" "$bad_config" --reapply --non-interactive >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "pipeline.repo 없음인데 exit 1 아님" || { rm -f "$bad_config"; return; }
  # secret/variable 부작용 없이 차단됐는지
  sec="$(count_gh_log 'secret set')"
  assert_eq "0" "$sec" "차단 전 secret set 발생" && pass
  rm -f "$bad_config"
)
