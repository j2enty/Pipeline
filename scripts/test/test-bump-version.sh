#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다 (it/assert_*/pass 헬퍼 상속).
# shellcheck disable=SC2034
# test-bump-version.sh — bump-version.sh 단위테스트.
#   semver 증가 규칙(patch/minor/major)·리셋·잘못된 인자(exit 2) 검증.
#   실제 plugin.json 은 절대 건드리지 않는다 — 매 케이스가 임시 복사본(mktemp)을
#   만들어 PLUGIN_JSON 으로 주입하고 trap 으로 정리한다.

BUMP_SH="$REPO_ROOT/scripts/bump-version.sh"

# 주어진 version 으로 임시 plugin.json 을 만들고 경로를 stdout 으로 반환.
# 실제 파일과 같은 다중 키·들여쓰기 구조 → version-only 치환 보존 검증용.
make_plugin_json() {
  local version="$1" f
  f="$(mktemp)"
  cat > "$f" <<EOF
{
  "name": "pipeline",
  "version": "$version",
  "description": "테스트용 매니페스트",
  "keywords": ["automation", "pipeline"]
}
EOF
  printf '%s' "$f"
}

# 대상 파일의 현재 version 값 추출 (python3 — 리포 공통 의존).
read_version() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1"
}

# BV-1 — patch: 0.1.0 → 0.1.1
it "BV-1 patch 0.1.0 → 0.1.1"
(
  f="$(make_plugin_json "0.1.0")"; trap 'rm -f "$f"' EXIT
  out="$(PLUGIN_JSON="$f" bash "$BUMP_SH" patch)" || { fail "patch 실행 실패"; return; }
  assert_eq "0.1.1" "$(read_version "$f")" "patch 결과 틀림" || return
  assert_eq "v0.1.0 → v0.1.1" "$out" "patch 출력 틀림" || return
  pass
)

# BV-2 — minor: 0.1.0 → 0.2.0 (patch 0 리셋)
it "BV-2 minor 0.1.0 → 0.2.0"
(
  f="$(make_plugin_json "0.1.0")"; trap 'rm -f "$f"' EXIT
  out="$(PLUGIN_JSON="$f" bash "$BUMP_SH" minor)" || { fail "minor 실행 실패"; return; }
  assert_eq "0.2.0" "$(read_version "$f")" "minor 결과 틀림" || return
  assert_eq "v0.1.0 → v0.2.0" "$out" "minor 출력 틀림" || return
  pass
)

# BV-3 — major: 0.1.0 → 1.0.0 (minor·patch 0 리셋)
it "BV-3 major 0.1.0 → 1.0.0"
(
  f="$(make_plugin_json "0.1.0")"; trap 'rm -f "$f"' EXIT
  out="$(PLUGIN_JSON="$f" bash "$BUMP_SH" major)" || { fail "major 실행 실패"; return; }
  assert_eq "1.0.0" "$(read_version "$f")" "major 결과 틀림" || return
  assert_eq "v0.1.0 → v1.0.0" "$out" "major 출력 틀림" || return
  pass
)

# BV-4 — minor 가 patch 를 0 으로 리셋: 0.1.5 → 0.2.0
it "BV-4 minor 가 patch 리셋 0.1.5 → 0.2.0"
(
  f="$(make_plugin_json "0.1.5")"; trap 'rm -f "$f"' EXIT
  PLUGIN_JSON="$f" bash "$BUMP_SH" minor >/dev/null || { fail "minor 실행 실패"; return; }
  assert_eq "0.2.0" "$(read_version "$f")" "patch 리셋 안 됨" || return
  pass
)

# BV-5 — major 가 minor·patch 를 0 으로 리셋: 0.1.5 → 1.0.0
it "BV-5 major 가 minor·patch 리셋 0.1.5 → 1.0.0"
(
  f="$(make_plugin_json "0.1.5")"; trap 'rm -f "$f"' EXIT
  PLUGIN_JSON="$f" bash "$BUMP_SH" major >/dev/null || { fail "major 실행 실패"; return; }
  assert_eq "1.0.0" "$(read_version "$f")" "minor·patch 리셋 안 됨" || return
  pass
)

# BV-6 — 큰 수에서도 자릿수 올림 정상: 1.9.9 → patch 1.9.10
it "BV-6 patch 자릿수 1.9.9 → 1.9.10"
(
  f="$(make_plugin_json "1.9.9")"; trap 'rm -f "$f"' EXIT
  PLUGIN_JSON="$f" bash "$BUMP_SH" patch >/dev/null || { fail "patch 실행 실패"; return; }
  assert_eq "1.9.10" "$(read_version "$f")" "두 자리 올림 틀림" || return
  pass
)

# BV-7 — version 외 키·구조 보존 (다른 키와 keywords 배열이 그대로인지)
it "BV-7 version 외 키·구조 보존"
(
  f="$(make_plugin_json "0.1.0")"; trap 'rm -f "$f"' EXIT
  PLUGIN_JSON="$f" bash "$BUMP_SH" patch >/dev/null || { fail "patch 실행 실패"; return; }
  content="$(cat "$f")"
  assert_contains "$content" '"name": "pipeline"' "name 키 소실" || return
  assert_contains "$content" '"keywords": ["automation", "pipeline"]' "keywords 형식 변형" || return
  pass
)

# BV-8 — 인자 없음 → exit 2
it "BV-8 인자 없음 → exit 2"
(
  rc=0
  bash "$BUMP_SH" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "인자 없음인데 exit 2 아님" && pass
)

# BV-9 — 잘못된 인자('foo') → exit 2
it "BV-9 잘못된 인자 → exit 2"
(
  rc=0
  bash "$BUMP_SH" foo >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "잘못된 인자인데 exit 2 아님" && pass
)
