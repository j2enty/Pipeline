#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Fix 4 — 상호배타 플래그 조합 거부.

# --reapply + --rotate-webhook-secret → exit 1
it "F4-1 --reapply + --rotate-webhook-secret → exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  code=0
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" \
    --reapply --rotate-webhook-secret --non-interactive >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "reapply+rotate 조합이 exit 1 아님" && pass
)

# --reapply + --update-commands-only → exit 1
it "F4-2 --reapply + --update-commands-only → exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  code=0
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" \
    --reapply --update-commands-only --non-interactive >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "reapply+update-commands-only 조합이 exit 1 아님" && pass
)

# --reapply 단독은 정상(exit 0)
it "F4-3 --reapply 단독은 정상 동작"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  code=0
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" \
    --reapply --non-interactive --env-file "$(mktemp -u)" >/dev/null 2>&1 || code=$?
  assert_eq "0" "$code" "--reapply 단독 실행이 exit 0 아님" && pass
)

# --rotate-webhook-secret 단독은 정상 (check_requirements 에서 막힐 수 있지만 상호배타 검사는 통과)
it "F4-4 --rotate-webhook-secret 단독 — 상호배타 검사 통과(체크리스트 이전 종료 아님)"
(
  export PATH="$STUBS_DIR:$PATH"
  # check_requirements 를 통과하고 진행되는지만 봄(exit 코드 무관 — 단지 exit 1이 배타 검사 전에 발생하지 않아야)
  # 배타 검사가 없으면 즉시 exit 1, 있으면 check_requirements 이후 진행
  # 여기서는 스텁 PATH 라 check_requirements 는 통과. 이후 config 파싱까지 진행.
  out="$(bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" \
    --rotate-webhook-secret --non-interactive --env-file "$(mktemp -u)" 2>&1 || true)"
  # 배타 오류 메시지가 없어야 함
  assert_not_contains "$out" "함께 사용할 수 없습니다" "단독 플래그에 배타 오류 발생" && pass
)
