#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# 러너 격리 세팅(install.sh) 단위테스트 — 이슈 #96.
#   방향 A(러너에 전용 CLAUDE_CONFIG_DIR): install.sh 가 러너 .env 에 CLAUDE_CONFIG_DIR 를
#   멱등 기록하고, 격리 config dir 에 credentials 심링크 + oauthAccount(.claude.json)를
#   프로비저닝하며, 인터랙티브 기본 ~/.claude 를 개발 레포로 재배선(ensure 재사용)하는지
#   검증한다. 실제 OAuth 토큰 없이 "경로/링크/파일 상태·병합·멱등·실패경로"만 단언한다
#   (인증 동작 자체는 실 러너에서만 최종 검증 가능 — PR 본문에 명시).
#
# setup_install_env 가 install.sh 를 source 해 함수를 로드한다(main 가드로 부작용 없음).
# 러너 격리 함수는 모듈 변수 RUNNER_ROOT·RUNNER_CONFIG_DIR·HOME 를 읽으므로 서브셸에서 override.

# ── write_runner_env ────────────────────────────────────────────────────────

# RI-1 — 새 .env: CLAUDE_CONFIG_DIR 추가 + 기존 라인 보존
it "RI-1 write_runner_env: 기존 라인 보존하며 CLAUDE_CONFIG_DIR 추가"
(
  setup_install_env
  envf="$(mktemp)"; printf 'FOO=bar\nBAZ=qux\n' > "$envf"
  write_runner_env "$envf" "/tmp/rcfg" || { fail "write_runner_env 비-0 종료"; return; }
  assert_contains "$(cat "$envf")" "FOO=bar" "기존 라인 유실" || return
  assert_contains "$(cat "$envf")" "BAZ=qux" "기존 라인 유실" || return
  assert_contains "$(cat "$envf")" "CLAUDE_CONFIG_DIR=/tmp/rcfg" "CLAUDE_CONFIG_DIR 미기록" && pass
)

# RI-2 — 멱등: 두 번 실행해도 CLAUDE_CONFIG_DIR 라인은 정확히 1개, 값은 갱신
it "RI-2 write_runner_env: 멱등(라인 1개) + 값 갱신"
(
  setup_install_env
  envf="$(mktemp)"; printf 'KEEP=1\n' > "$envf"
  write_runner_env "$envf" "/tmp/old" || { fail "1차 실패"; return; }
  write_runner_env "$envf" "/tmp/new" || { fail "2차 실패"; return; }
  n="$(grep -c '^CLAUDE_CONFIG_DIR=' "$envf" 2>/dev/null || true)"; n="${n:-0}"
  assert_eq "1" "$n" "CLAUDE_CONFIG_DIR 라인이 중복됨(${n}개)" || return
  assert_contains "$(cat "$envf")" "CLAUDE_CONFIG_DIR=/tmp/new" "값 미갱신" || return
  assert_not_contains "$(cat "$envf")" "/tmp/old" "옛 값 잔존" || return
  assert_contains "$(cat "$envf")" "KEEP=1" "무관 라인 유실" && pass
)

# ── provision_runner_claude_json ────────────────────────────────────────────

# RI-3 — 새 파일에 oauthAccount 복사(status ok)
it "RI-3 provision .claude.json: oauthAccount 복사(status ok)"
(
  setup_install_env
  src="$(mktemp)"; printf '{"oauthAccount":{"emailAddress":"probe@ex.com"},"extra":"z"}' > "$src"
  dst="$(mktemp -d)/.claude.json"
  st="$(provision_runner_claude_json "$src" "$dst")"
  assert_eq "ok" "$st" "status 가 ok 아님" || return
  assert_contains "$(cat "$dst")" "probe@ex.com" "oauthAccount 미복사" || return
  # extra 는 src 의 다른 키 — 복사 대상 아님(oauthAccount 만)
  assert_not_contains "$(cat "$dst")" "\"extra\"" "oauthAccount 외 키까지 복사됨" && pass
)

# RI-4 — 병합: 대상의 기존 키 보존하며 oauthAccount 추가
it "RI-4 provision .claude.json: 대상 기존 키 보존(병합)"
(
  setup_install_env
  src="$(mktemp)"; printf '{"oauthAccount":{"emailAddress":"probe@ex.com"}}' > "$src"
  dst="$(mktemp -d)/.claude.json"; printf '{"projects":{"/x":{"hasTrustDialogAccepted":true}}}' > "$dst"
  st="$(provision_runner_claude_json "$src" "$dst")"
  assert_eq "ok" "$st" "status ok 아님" || return
  assert_contains "$(cat "$dst")" "hasTrustDialogAccepted" "기존 projects 키 유실" || return
  assert_contains "$(cat "$dst")" "probe@ex.com" "oauthAccount 미추가" && pass
)

# RI-5 — oauthAccount 없으면 status missing, 대상은 여전히 유효 json(기존 보존)
it "RI-5 provision .claude.json: oauthAccount 부재 → missing + 기존 보존"
(
  setup_install_env
  src="$(mktemp)"; printf '{"somethingElse":1}' > "$src"
  dst="$(mktemp -d)/.claude.json"; printf '{"projects":{"/y":{}}}' > "$dst"
  st="$(provision_runner_claude_json "$src" "$dst")"
  assert_eq "missing" "$st" "oauthAccount 없는데 missing 아님" || return
  assert_contains "$(cat "$dst")" "projects" "기존 키 유실" || return
  # 유효 json 인지 확인
  python3 -c "import json,sys;json.load(open('$dst'))" 2>/dev/null || { fail "대상이 유효 json 아님"; return; }
  pass
)

# ── setup_runner_isolation (end-to-end, 가짜 HOME) ───────────────────────────

# 가짜 홈·러너 트리 구성 헬퍼 — echo "<home> <runner> <cfg>"
_mk_runner_fixture() {
  local home cred_present="${1:-yes}"
  home="$(mktemp -d)"; mkdir -p "$home/.claude"
  [ "$cred_present" = "yes" ] && printf '{"claudeAiOauth":{"accessToken":"dummy"}}' > "$home/.claude/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"probe@ex.com"}}' > "$home/.claude.json"
  local runner; runner="$(mktemp -d)"
  local cfg; cfg="$(mktemp -d)/runner-cfg"   # 미리 생성 안 함 — 함수가 mkdir 하는지 확인
  echo "$home $runner $cfg"
}

# RI-6 — 격리 세팅: 심링크 + .claude.json + .env 전부 배선
it "RI-6 setup_runner_isolation: 심링크·oauthAccount·.env 배선"
(
  setup_install_env
  read -r HOME RUNNER_ROOT RUNNER_CONFIG_DIR <<<"$(_mk_runner_fixture)"
  export HOME
  setup_runner_isolation >/dev/null 2>&1 || { fail "setup_runner_isolation 비-0 종료"; return; }
  # config dir 는 함수가 생성
  assert_file_present "$RUNNER_CONFIG_DIR" "config dir 미생성" || return
  # credentials 는 심링크여야 하고 원본을 가리켜야 함
  [ -L "$RUNNER_CONFIG_DIR/.credentials.json" ] || { fail "credentials 가 심링크 아님"; return; }
  assert_eq "$HOME/.claude/.credentials.json" "$(readlink "$RUNNER_CONFIG_DIR/.credentials.json")" "심링크 타깃 불일치" || return
  assert_contains "$(cat "$RUNNER_CONFIG_DIR/.claude.json")" "probe@ex.com" "oauthAccount 미프로비저닝" || return
  # .env 에 CLAUDE_CONFIG_DIR 기록(정규화된 절대경로)
  cfg_abs="$(cd "$RUNNER_CONFIG_DIR" && pwd)"
  assert_contains "$(cat "$RUNNER_ROOT/.env")" "CLAUDE_CONFIG_DIR=$cfg_abs" ".env 미기록" && pass
)

# RI-7 — 격리 세팅 멱등: 두 번 실행해도 심링크 유효 + .env 라인 1개
it "RI-7 setup_runner_isolation: 멱등(심링크 유효 · .env 라인 1개)"
(
  setup_install_env
  read -r HOME RUNNER_ROOT RUNNER_CONFIG_DIR <<<"$(_mk_runner_fixture)"
  export HOME
  setup_runner_isolation >/dev/null 2>&1 || { fail "1차 실패"; return; }
  setup_runner_isolation >/dev/null 2>&1 || { fail "2차 실패(멱등 아님)"; return; }
  [ -L "$RUNNER_CONFIG_DIR/.credentials.json" ] || { fail "2차 후 심링크 깨짐"; return; }
  n="$(grep -c '^CLAUDE_CONFIG_DIR=' "$RUNNER_ROOT/.env" 2>/dev/null || true)"; n="${n:-0}"
  assert_eq "1" "$n" "CLAUDE_CONFIG_DIR 라인 중복(${n}개)" && pass
)

# RI-8 — 러너 루트 없으면 에러(exit≠0)
it "RI-8 setup_runner_isolation: 러너 루트 부재 → 에러"
(
  setup_install_env
  rc=0
  ( HOME="$(mktemp -d)"; RUNNER_ROOT="/nonexistent-$$-xyz"; RUNNER_CONFIG_DIR="$(mktemp -d)"; setup_runner_isolation ) >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "러너 루트 부재인데 0 종료" && pass
)

# RI-9 — credentials 원본 부재: 경고만, 심링크 없음, 하지만 .env 는 기록(중단 안 함)
it "RI-9 setup_runner_isolation: credentials 부재 → 경고·심링크없음·.env 기록"
(
  setup_install_env
  read -r HOME RUNNER_ROOT RUNNER_CONFIG_DIR <<<"$(_mk_runner_fixture no)"
  export HOME
  setup_runner_isolation >/dev/null 2>&1 || { fail "credentials 부재에 중단됨(경고만 해야 함)"; return; }
  [ -e "$RUNNER_CONFIG_DIR/.credentials.json" ] && { fail "원본 없는데 심링크 생성됨"; return; }
  cfg_abs="$(cd "$RUNNER_CONFIG_DIR" && pwd)"
  assert_contains "$(cat "$RUNNER_ROOT/.env")" "CLAUDE_CONFIG_DIR=$cfg_abs" ".env 미기록" && pass
)

# ── install_local_plugin (ensure 재사용) ────────────────────────────────────

# RI-10 — 인터랙티브 재배선: ensure-plugin-installed 를 REPO_ROOT 소스로 호출
it "RI-10 install_local_plugin: 소스=REPO_ROOT 로 ensure 호출"
(
  setup_install_env
  SCRIPT_DIR="$REPO_ROOT/scripts"
  bindir="$(mktemp -d)"
  cat > "$bindir/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_LOG"
if [ "$1" = "plugin" ] && [ "$2" = "uninstall" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$bindir/claude"
  log="$(mktemp)"
  CLAUDE_LOG="$log" PATH="$bindir:$PATH" install_local_plugin >/dev/null 2>&1 || { fail "install_local_plugin 비-0 종료"; return; }
  assert_contains "$(cat "$log")" "plugin marketplace add $REPO_ROOT" "REPO_ROOT 소스로 마켓플레이스 등록 안 함" || return
  assert_contains "$(cat "$log")" "plugin install pipeline@pipeline" "설치 미도달" && pass
)

# RI-11 — claude CLI 없으면 에러(exit≠0)
it "RI-11 install_local_plugin: claude 부재 → 에러"
(
  setup_install_env
  SCRIPT_DIR="$REPO_ROOT/scripts"
  # claude 를 못 찾도록 PATH 를 최소화(coreutils 만) — command -v claude 실패 유도
  emptybin="$(mktemp -d)"
  rc=0
  ( PATH="$emptybin"; install_local_plugin ) >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "claude 없는데 0 종료" && pass
)
