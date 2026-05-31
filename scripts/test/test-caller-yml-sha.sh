#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# #12-1 — install_caller_ymls 의 두 PUT 분기 커버:
#   ① 신규파일(sha 조회 빈값)  → sha 없는 PUT
#   ② 기존파일(sha 조회 값있음) → sha 포함 PUT
# 기존 스텁은 sha 조회에 항상 빈값을 줘 ① 분기만 탐. GH_STUB_EXISTING_SHA 로 ② 분기 검증.
#
# install_caller_ymls 가 요구하는 컨텍스트:
#   - REPO_ROOT (템플릿 소스 base) — 주의: install.sh 를 source 하면 install.sh:53
#     이 자기 기준($0)으로 REPO_ROOT 를 덮어써 잘못된 경로가 된다. 따라서
#     테스트 안에서 FIXTURES_DIR 기준(export 라 안 덮임)으로 Pipeline 루트 복원.
#   - PIPELINE_REPO / PIPELINE_REF (전역)        — placeholder 치환 값
#   - 인자 1: repo (sha 조회·PUT 대상)
#   - 인자 2: mod_ci (auto-merge.yml CI 이름 치환, 옵션)

# C1 — 신규파일: sha 조회 빈값 → PUT 줄에 sha= 없음
it "C1 신규파일 — PUT 호출에 sha= 없음"
(
  setup_install_env
  # install.sh source 가 덮어쓴 REPO_ROOT 를 Pipeline 루트로 복원(템플릿 경로용)
  # FIXTURES_DIR=scripts/test/fixtures → 3단계 상위가 Pipeline 루트
  REPO_ROOT="$(cd "$FIXTURES_DIR/../../.." && pwd)"
  PIPELINE_REPO="test-org/Pipeline"
  PIPELINE_REF="main"
  unset GH_STUB_EXISTING_SHA
  install_caller_ymls "test-org/ModuleA" "ModuleA CI" >/dev/null 2>&1
  # PUT 라인만 추출해 sha= 유무 확인 (sha 조회 줄에도 '.sha' 가 있으니 PUT 한정)
  put_lines="$(grep -- '-X PUT' "$GH_LOG" || true)"
  assert_ne "" "$put_lines" "PUT 호출이 한 건도 없음" || return
  assert_not_contains "$put_lines" "sha=" "신규파일인데 PUT 에 sha= 포함됨" && pass
)

# C2 — 기존파일: sha 조회 값있음 → PUT 줄에 sha=<값> 있음
it "C2 기존파일 — PUT 호출에 sha=<값> 포함"
(
  setup_install_env
  # install.sh source 가 덮어쓴 REPO_ROOT 를 Pipeline 루트로 복원(템플릿 경로용)
  # FIXTURES_DIR=scripts/test/fixtures → 3단계 상위가 Pipeline 루트
  REPO_ROOT="$(cd "$FIXTURES_DIR/../../.." && pwd)"
  PIPELINE_REPO="test-org/Pipeline"
  PIPELINE_REF="main"
  export GH_STUB_EXISTING_SHA="0123456789abcdef0123456789abcdef01234567"
  install_caller_ymls "test-org/ModuleA" "ModuleA CI" >/dev/null 2>&1
  unset GH_STUB_EXISTING_SHA
  put_lines="$(grep -- '-X PUT' "$GH_LOG" || true)"
  assert_ne "" "$put_lines" "PUT 호출이 한 건도 없음" || return
  assert_contains "$put_lines" "sha=0123456789abcdef0123456789abcdef01234567" \
    "기존파일인데 PUT 에 sha=<값> 없음" || return
  # 적대적 강화: 한 줄이라도 sha= 없는 PUT 이 있으면 실패(허위양성 차단).
  # 모든 yml 갱신 PUT 이 sha 분기를 타야 한다.
  no_sha_put="$(printf '%s\n' "$put_lines" | grep -v 'sha=' || true)"
  assert_eq "" "$no_sha_put" "sha= 없는 PUT 라인 존재 — 일부 yml 이 신규 분기로 샘" && pass
)
