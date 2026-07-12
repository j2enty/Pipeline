#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# test-script-parity.sh — #105(감사 cross-p0·scripts-p0) 복제 드리프트 CI 가드.
#
# 배경: "재사용 자산" 프레임워크인데 정작 공통 스크립트가 여러 곳에 물리 복사돼 있다.
#   플러그인은 user-scope 로 설치돼(각 skill 이 자기 scripts/ 를 통째로 들고 감) 런타임에
#   본체 scripts/ 를 참조할 수 없다 → 물리 복제가 불가피하다. 그래서 "단일 소스 파일"은
#   불가능하고, 대신 복사본들이 서로 바이트 동일함을 CI 에서 강제(cmp -s)해 조용한 드리프트를
#   즉시 실패로 만든다. (이 테스트가 scripts-test 잡에서 돌아 그 역할을 한다.)
#
# 잠그는 복제군(각 군은 서로 바이트 동일해야 함):
#   - gh-app-token.sh      : scripts/ ↔ plugin/skills/review/scripts/
#   - slack-notify.sh      : scripts/ ↔ plugin/skills/kickoff/scripts/ ↔ plugin/skills/review/scripts/
#   - janus-notify.sh      : scripts/ ↔ plugin/skills/plan/scripts/
#     (지금은 plan 만 발사측(/plan Step 9.8). kickoff/review 복제는 후속(#37 PR3) 몫.)
#   - pipeline-config.sh   : plugin/skills/kickoff/scripts/ ↔ plugin/skills/review/scripts/
#     (plan 사본은 의도적으로 다르다 — reviewer 전용 4키 없음 + cross-check-tool 있음.
#      plan 의 "공유 파싱 코어" 드리프트는 test-reader-core-parity.sh 가 동작 기준으로 잡는다.)
#
# 새 복제가 생기면 아래 배열에 군을 추가한다.

# 한 군(파일들이 서로 바이트 동일해야 함)을 검사하는 헬퍼.
#   $1: 군 이름(메시지용)  이후 인자: 비교할 파일들(2개 이상, 첫 파일이 기준)
_assert_group_identical() {
  local name="$1"; shift
  local base="$1"; shift
  if [ ! -f "$REPO_ROOT/$base" ]; then
    fail "[$name] 기준 파일 없음: $base"
    return 1
  fi
  local f
  for f in "$@"; do
    if [ ! -f "$REPO_ROOT/$f" ]; then
      fail "[$name] 사본 없음: $f"
      return 1
    fi
    if ! cmp -s "$REPO_ROOT/$base" "$REPO_ROOT/$f"; then
      fail "[$name] 복제 드리프트: '$base' ↔ '$f' 가 다름 (동기화 필요)"
      return 1
    fi
  done
  return 0
}

it "SP-1 gh-app-token.sh 복제본 바이트 동일 (본체 ↔ review 플러그인)"
(
  _assert_group_identical "gh-app-token" \
    "scripts/gh-app-token.sh" \
    "plugin/skills/review/scripts/gh-app-token.sh" && pass
)

it "SP-2 slack-notify.sh 복제본 바이트 동일 (본체 ↔ kickoff ↔ review)"
(
  _assert_group_identical "slack-notify" \
    "scripts/slack-notify.sh" \
    "plugin/skills/kickoff/scripts/slack-notify.sh" \
    "plugin/skills/review/scripts/slack-notify.sh" && pass
)

it "SP-3 pipeline-config.sh 복제본 바이트 동일 (kickoff ↔ review)"
(
  _assert_group_identical "pipeline-config(kickoff/review)" \
    "plugin/skills/kickoff/scripts/pipeline-config.sh" \
    "plugin/skills/review/scripts/pipeline-config.sh" && pass
)

it "SP-4 janus-notify.sh 복제본 바이트 동일 (본체 ↔ plan 플러그인)"
(
  _assert_group_identical "janus-notify" \
    "scripts/janus-notify.sh" \
    "plugin/skills/plan/scripts/janus-notify.sh" && pass
)
