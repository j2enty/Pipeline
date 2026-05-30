#!/usr/bin/env bash
# Phase 1 — main 호출 가드 검증.
# install.sh 를 source 하면 main 미실행(부작용 없음) + 함수만 로드되는지.

it "source 시 main 미실행 + 핵심 함수 로드됨"
(
  setup_install_env
  ok=1
  for fn in generate_env register_variables register_secrets \
            register_labels install_caller_ymls load_credentials_from_env; do
    declare -F "$fn" >/dev/null 2>&1 || { fail "함수 미로드: $fn"; ok=0; }
  done
  [ "$ok" = 1 ] && pass
)

it "source 가 부작용(gh 호출) 없이 끝남"
(
  setup_install_env
  # source 직후 GH_LOG 비어있어야 함 (main 미실행 = gh 호출 0)
  lines="$(wc -l < "$GH_LOG" | tr -d ' ')"
  assert_eq "0" "$lines" "source 만으로 gh 호출 발생" && pass
)
