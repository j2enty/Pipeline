#!/usr/bin/env bash
# 이 파일은 scripts/test/run-tests.sh 에서 source 된다(it/assert_* 헬퍼 사용).
# SC2016: 스텁 파일에 쓸 리터럴 $FIX·기대 문자열 'cost $0.18' 등 — 의도적 미확장.
# shellcheck disable=SC2034,SC2016
# claude-with-usage.sh 단위테스트 — stream-json result 파싱 + 동작 보존(exit/토글/best-effort).
#
# 종속성 제로: 각 케이스가 임시 디렉토리에 가짜 claude·gh 스텁을 만들어 PATH 로 주입한다.
#   · claude 스텁: 픽스처(stream-json)를 stdout 으로 흘리고 지정 exit code 로 종료.
#   · gh 스텁: `gh issue comment <target> --body <body>` 호출을 GH_LOG 에 기록(코멘트 박제 확인).
# 실제 claude/네트워크 호출 없음. PIPELINE_CONFIG 토글 파일로 on/off 를 검증한다.

WRAPPER="$REPO_ROOT/scripts/claude-with-usage.sh"
SUCCESS_FIXTURE="$REPO_ROOT/scripts/test/fixtures/claude-stream-json-success.txt"

# 가짜 claude·gh 스텁 + 토글 config 를 갖춘 격리 환경을 만들어 echo 한다.
#   인자: <claude_exit_code> <emit_result: yes|no>
#   출력(stdout): 임시 디렉토리 경로. 호출부가 BIN/GH_LOG/CONFIG 를 그 안에서 참조.
make_env() {
  local claude_exit="$1" emit_result="$2"
  local dir; dir="$(mktemp -d)"
  local bin="$dir/bin"; mkdir -p "$bin"

  # 가짜 claude — 픽스처를 흘리고(emit_result=no 면 result 줄 제거) 지정 코드로 종료.
  local emit_cmd='cat "$FIX"'
  if [ "$emit_result" = "no" ]; then
    # result 이벤트를 뺀 출력(중도 실패 모사) — grep -v 로 result 줄 제거.
    emit_cmd='grep -v '\''"type":"result"'\'' "$FIX"'
  fi
  cat > "$bin/claude" <<EOF
#!/usr/bin/env bash
FIX='$SUCCESS_FIXTURE'
$emit_cmd
exit $claude_exit
EOF
  chmod +x "$bin/claude"

  # 가짜 gh — issue comment 호출을 GH_LOG 에 한 줄로 기록. GH_STUB_GH_FAIL=1 이면 exit 1.
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${GH_STUB_GH_FAIL:-}" = "1" ]; then echo "gh fail" >&2; exit 1; fi
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
EOF
  chmod +x "$bin/gh"

  echo "$dir"
}

# 토글 config 작성 — <dir> <true|false|absent>
write_toggle() {
  local dir="$1" state="$2"
  local cfg="$dir/.pipeline-config.yml"
  if [ "$state" = "absent" ]; then
    printf 'project:\n  owner: x\nclaude-commands:\n  project-name: y\n' > "$cfg"
  else
    printf 'project:\n  owner: x\nclaude-commands:\n  metrics:\n    usage-tracking-enabled: %s\n' "$state" > "$cfg"
  fi
  echo "$cfg"
}

# ── WU-1: 토글 ON + claude 성공 → 계측 코멘트 박제 + exit 0 ──
it "WU-1 토글 ON·성공 → 코멘트 박제 + exit 0"
(
  dir="$(make_env 0 yes)"
  cfg="$(write_toggle "$dir" true)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  out="$(PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" USAGE_METRICS_LABEL="kickoff" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "성공인데 exit 0 아님" || { rm -rf "$dir"; return; }
  body="$(cat "$ghlog")"
  assert_contains "$body" "issue comment https://github.com/org/Repo/issues/3" "코멘트 대상 누락" || { rm -rf "$dir"; return; }
  assert_contains "$body" "📊 usage (kickoff)" "라벨 헤더 누락" || { rm -rf "$dir"; return; }
  assert_contains "$body" 'cost $0.1834' "비용 누락/오포맷" || { rm -rf "$dir"; return; }
  assert_contains "$body" "in 1,234·out 5,678 tok" "토큰 누락/오포맷" || { rm -rf "$dir"; return; }
  assert_contains "$body" "42.3s" "duration 누락/오포맷" || { rm -rf "$dir"; return; }
  assert_contains "$body" "7 turns" "turns 누락" || { rm -rf "$dir"; return; }
  assert_contains "$body" "claude-opus-4-8" "모델명 누락" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-2: 토글 OFF → 코멘트 없음 + claude 정상 실행(라이브 로그 보존) + exit 0 ──
it "WU-2 토글 OFF → 코멘트 없음 + 라이브로그 보존 + exit 0"
(
  dir="$(make_env 0 yes)"
  cfg="$(write_toggle "$dir" false)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  out="$(PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "exit 0 아님" || { rm -rf "$dir"; return; }
  ghbody="$(cat "$ghlog")"
  assert_eq "" "$ghbody" "토글 OFF 인데 코멘트 발생" || { rm -rf "$dir"; return; }
  # 라이브 로그(tee) 보존 — claude stdout 의 result 줄이 그대로 흘렀는지.
  assert_contains "$out" '"type":"result"' "라이브 로그(stream-json) 미보존" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-3: 토글 ON + claude 실패(exit 7) → exit 7 그대로 전파 ──
# (계측은 best-effort — 실패해도 exit 코드는 claude 것. result 가 있으면 코멘트는 시도될 수 있음.)
it "WU-3 claude 실패(7) → exit 7 전파(계측이 삼키지 않음)"
(
  dir="$(make_env 7 yes)"
  cfg="$(write_toggle "$dir" true)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "7" "$rc" "claude 실패코드 7 이 전파되지 않음" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-4: 토글 ON + claude 실패 + result 이벤트 없음 → exit 코드 전파 + 코멘트 없음(크래시 없음) ──
it "WU-4 result 없는 실패 → exit 전파 + 코멘트 스킵"
(
  dir="$(make_env 5 no)"
  cfg="$(write_toggle "$dir" true)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "5" "$rc" "exit 5 전파 안 됨" || { rm -rf "$dir"; return; }
  assert_eq "" "$(cat "$ghlog")" "result 없는데 코멘트 발생" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-5: gh 코멘트 실패 → best-effort, exit 0 유지(코멘트 실패가 exit 를 바꾸지 않음) ──
it "WU-5 gh 코멘트 실패 → best-effort, exit 0 유지"
(
  dir="$(make_env 0 yes)"
  cfg="$(write_toggle "$dir" true)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$dir/bin:$PATH" GH_LOG="$ghlog" GH_STUB_GH_FAIL=1 PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "gh 실패가 exit 를 오염시킴" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-6: 명시 USAGE_METRICS_ENABLED=true 가 config OFF 를 override ──
it "WU-6 USAGE_METRICS_ENABLED=true override → config OFF 여도 코멘트"
(
  dir="$(make_env 0 yes)"
  cfg="$(write_toggle "$dir" false)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_ENABLED="true" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "exit 0 아님" || { rm -rf "$dir"; return; }
  assert_contains "$(cat "$ghlog")" "issue comment" "override 했는데 코멘트 없음" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-7: 토글 ON 이지만 계측 대상(TARGET) 없음 → 코멘트 스킵 + claude 정상 + exit 0 ──
it "WU-7 대상 없음 → 코멘트 스킵 + exit 0"
(
  dir="$(make_env 0 yes)"
  cfg="$(write_toggle "$dir" true)"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$(cat "$ghlog")" "대상 없는데 코멘트 발생" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-8: 프롬프트 인자 누락 → exit 2(설정 오류, claude 실행 전) ──
it "WU-8 프롬프트 누락 → exit 2"
(
  dir="$(make_env 0 yes)"
  rc=0
  PATH="$dir/bin:$PATH" bash "$WRAPPER" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "프롬프트 누락인데 exit 2 아님" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-9: cache 토큰 표기 + config 부재 시 기본 OFF(코멘트 없음) ──
it "WU-9 config 부재(키 없음) → 기본 OFF, 코멘트 없음"
(
  dir="$(make_env 0 yes)"
  cfg="$(write_toggle "$dir" absent)"   # metrics 키 자체가 없는 config
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$dir/bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:kickoff X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "exit 0 아님" || { rm -rf "$dir"; return; }
  assert_eq "" "$(cat "$ghlog")" "키 부재(기본 OFF)인데 코멘트 발생" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-10: SIGTERM(timeout 모사) → 자식 claude 에 시그널 forward(고아 미발생) ──
# 회귀 방어(코드리뷰 blocker): 래퍼를 `timeout bash 래퍼` 로 감쌌을 때 timeout 이 보내는
# SIGTERM 이 손자 claude 까지 전파돼야 한다. 안 그러면 claude 가 고아로 살아남아 다음
# attempt 와 동시 실행된다. 느린 claude 스텁이 "지연 후 alive 마커"를 남기게 하고, 래퍼에
# SIGTERM 을 보낸 뒤 마커가 "안 생겼는지"로 자식이 죽었음을 검증한다.
it "WU-10 SIGTERM → 자식 claude forward(고아 방지)"
(
  dir="$(mktemp -d)"; bin="$dir/bin"; mkdir -p "$bin"
  marker="$dir/claude-still-alive"
  # 느린 claude — 2초 자고 나서 alive 마커를 쓴다. SIGTERM 으로 죽으면 마커가 안 생긴다.
  # (trap 미설정 → 기본 SIGTERM 동작으로 죽음. 시그널이 도달하는지가 검증 포인트.)
  cat > "$bin/claude" <<EOF
#!/usr/bin/env bash
sleep 2
echo alive > "$marker"
echo '{"type":"result","total_cost_usd":0.1,"usage":{"input_tokens":1,"output_tokens":1},"num_turns":1,"duration_ms":2000}'
EOF
  chmod +x "$bin/claude"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
EOF
  chmod +x "$bin/gh"
  cfg="$dir/cfg.yml"; printf 'project:\n  owner: x\nclaude-commands:\n  metrics:\n    usage-tracking-enabled: true\n' > "$cfg"

  # 래퍼를 백그라운드로 띄우고 0.5초 뒤 SIGTERM(timeout 발화 모사) 전송.
  PATH="$bin:$PATH" GH_LOG="$dir/gh.log" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    bash "$WRAPPER" "/pipeline:review X --bot" >/dev/null 2>&1 &
  wpid=$!
  sleep 0.5
  kill -TERM "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  # claude 가 forward 받아 죽었다면(2초 sleep 도달 전 0.5초 시점 SIGTERM) 마커가 없어야 한다.
  sleep 2  # claude 가 살아있었다면 이 사이 마커를 썼을 것.
  assert_file_absent "$marker" "SIGTERM 이 자식 claude 로 forward 되지 않아 고아가 살아남음" \
    || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-11: stderr 잡음이 result 캡처를 오염시키지 않음(stdout 전용 캡처) ──
# 회귀 방어(코드리뷰 minor): claude 가 정상 result 를 stdout 에 낸 "뒤" stderr 에
# `"type":"result"` 부분문자열을 포함한 비-JSON 잡음 줄을 뱉어도, 그게 RESULT_CAPTURE 를
# 덮어쓰면 안 된다(예전 2>&1 합류 버그). 그래도 코멘트가 진짜 usage 로 박제돼야 한다.
it "WU-11 stderr 잡음 → 캡처 미오염, 진짜 usage 박제"
(
  dir="$(mktemp -d)"; bin="$dir/bin"; mkdir -p "$bin"
  # stdout: 정상 result. stderr: result 부분문자열을 가진 비-JSON 잡음.
  cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
{"type":"system","subtype":"init"}
{"type":"result","subtype":"success","total_cost_usd":0.18342,"usage":{"input_tokens":1234,"output_tokens":5678},"num_turns":7,"duration_ms":42337}
OUT
# stderr 잡음 — result 부분문자열 포함하지만 JSON 아님. 캡처에 새면 json.loads 실패.
echo 'noise "type":"result" noise not-json' >&2
exit 0
EOF
  chmod +x "$bin/claude"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
EOF
  chmod +x "$bin/gh"
  cfg="$dir/cfg.yml"; printf 'project:\n  owner: x\nclaude-commands:\n  metrics:\n    usage-tracking-enabled: true\n' > "$cfg"
  ghlog="$dir/gh.log"; : > "$ghlog"
  rc=0
  PATH="$bin:$PATH" GH_LOG="$ghlog" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/pull/9" USAGE_METRICS_LABEL="review" \
    bash "$WRAPPER" "/pipeline:review X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "exit 0 아님" || { rm -rf "$dir"; return; }
  body="$(cat "$ghlog")"
  # 캡처가 오염됐다면 json.loads 실패 → 코멘트 없음. 미오염이면 진짜 usage 박제.
  assert_contains "$body" 'cost $0.1834' "stderr 잡음이 캡처를 오염시켜 코멘트 누락" || { rm -rf "$dir"; return; }
  assert_contains "$body" "in 1,234·out 5,678 tok" "토큰 누락(캡처 오염 의심)" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)

# ── WU-12: timeout 발화 시 124 전파 + 자식 claude 고아 미발생 ──
# 회귀 방어(Codex 지적): review.yml 은 `$TIMEOUT_CMD 30m bash 래퍼` 로 감싸 timeout 발화
# 시 124 가 호출부 `[ "$rc" -eq 124 ]` 분기로 가야 한다. gtimeout/timeout 으로 래퍼를 짧게
# 감싸고 claude 를 오래 sleep 시켜 (a)종료코드 124 (b)고아 마커 미생성 둘 다 검증.
# 둘 다 없는 환경이면 skip(이식성 — 실패로 만들지 않음).
it "WU-12 timeout 발화 → 124 전파 + 자식 고아 방지"
(
  TIMEOUT_CMD="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
  if [ -z "$TIMEOUT_CMD" ]; then
    echo "    (skip) gtimeout/timeout 없음 — 이식성 스킵"
    pass; exit 0
  fi
  dir="$(mktemp -d)"; bin="$dir/bin"; mkdir -p "$bin"
  marker="$dir/claude-still-alive"
  # 오래 자는 claude — timeout(1s) 발화로 죽어야 마커가 안 생긴다.
  cat > "$bin/claude" <<EOF
#!/usr/bin/env bash
sleep 10
echo alive > "$marker"
echo '{"type":"result","total_cost_usd":0.1,"usage":{"input_tokens":1,"output_tokens":1},"num_turns":1,"duration_ms":10000}'
EOF
  chmod +x "$bin/claude"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
EOF
  chmod +x "$bin/gh"
  cfg="$dir/cfg.yml"; printf 'project:\n  owner: x\nclaude-commands:\n  metrics:\n    usage-tracking-enabled: true\n' > "$cfg"
  rc=0
  # 호출부 모사: timeout 1s 로 래퍼를 감싼다. 래퍼 밖 timeout → 124 가 그대로 와야 한다.
  PATH="$bin:$PATH" GH_LOG="$dir/gh.log" PIPELINE_CONFIG="$cfg" \
    USAGE_METRICS_TARGET="https://github.com/org/Repo/issues/3" \
    "$TIMEOUT_CMD" 1s bash "$WRAPPER" "/pipeline:review X --bot" >/dev/null 2>&1 || rc=$?
  assert_eq "124" "$rc" "timeout 발화인데 124 미전파(rc=$rc)" || { rm -rf "$dir"; return; }
  # 자식 claude 가 forward 받아 죽었는지 — 10초 sleep 도달 전 죽으면 마커 없음.
  sleep 2
  assert_file_absent "$marker" "timeout 후 자식 claude 가 고아로 살아남음" || { rm -rf "$dir"; return; }
  rm -rf "$dir"; pass
)
