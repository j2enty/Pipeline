#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# test-gh-app-token-no-leak.sh — #101(감사 scripts-g1) 보안 회귀 그물망.
#
# 검증 대상: gh-app-token.sh 의 실패 경로가 installation token 을 로그(stdout/stderr)로
#   유출하지 않는지. 옛 코드는 파싱 실패 시 `echo "Response: $RESPONSE" >&2` 로 응답 원문을
#   찍었는데, 토큰 발급은 성공했으나 파싱만 실패한 경우 원문에 실토큰이 들어있어 그대로 샜다.
#   GitHub Actions 로그는 이 값을 마스킹하지 않는다.
#
# 테스트 방식(순수 격리 — install.sh 무관):
#   - openssl 로 즉석 RSA 키 생성(JWT 서명 통과용, 실 App 아님).
#   - curl 만 PATH 스텁으로 가로채 임의 응답을 주입(openssl·python3·date 는 실제 사용).
#   - AUTHOR_* 환경변수를 테스트용으로 세팅.
#
# 시나리오:
#   G1-1 (레드 입증): 응답이 절단된 JSON 이라 파싱 실패하지만 원문에 토큰 문자열이 있음
#                     → 실패 종료 + 어떤 출력에도 토큰이 안 보여야 함. (옛 코드면 실패)
#   G1-2 (진단 보존): 정상 에러 응답({"message":...}) → message 는 진단으로 노출, 토큰 없음.
#   G1-3 (무회귀):   정상 토큰 응답 → exit 0 + stdout 이 정확히 토큰.

SCRIPT="$REPO_ROOT/scripts/gh-app-token.sh"

# 격리 환경 준비: 임시 PEM + curl 스텁 디렉토리. 응답 본문은 파일로 주입.
_ght_setup() {
  GHT_TMP="$(mktemp -d)"
  GHT_PEM="$GHT_TMP/key.pem"
  openssl genrsa -out "$GHT_PEM" 2048 >/dev/null 2>&1
  GHT_STUBDIR="$GHT_TMP/bin"
  mkdir -p "$GHT_STUBDIR"
  GHT_RESP_FILE="$GHT_TMP/response.json"
  # curl 스텁 — 인자 무시하고 응답 파일 내용을 그대로 출력(성공 종료).
  cat > "$GHT_STUBDIR/curl" <<STUB
#!/usr/bin/env bash
cat "$GHT_RESP_FILE"
exit 0
STUB
  chmod +x "$GHT_STUBDIR/curl"
}

_ght_teardown() { rm -rf "$GHT_TMP"; }

# 스크립트를 격리 환경에서 실행하고 stdout·stderr·exit 를 캡처.
#   $1: 캡처변수 접두(예: OUT/ERR/RC 는 <prefix>_OUT 등) — 여기선 전역 GHT_OUT/GHT_ERR/GHT_RC 사용.
_ght_run() {
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  PATH="$GHT_STUBDIR:$PATH" \
  AUTHOR_APP_ID="12345" \
  AUTHOR_PEM="$GHT_PEM" \
  AUTHOR_INSTALLATION_ID="67890" \
    bash "$SCRIPT" AUTHOR >"$outf" 2>"$errf"
  GHT_RC=$?
  GHT_OUT="$(cat "$outf")"
  GHT_ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# G1-1 — 파싱 실패 + 원문에 토큰: 어떤 출력에도 토큰이 새면 안 됨.
it "G1-1 파싱 실패해도 토큰이 stdout/stderr 로 유출되지 않음 (레드 입증)"
(
  _ght_setup
  CANARY="ghs_LEAKCANARY_do_not_log_AAA111"
  # 절단된 JSON — python json.load 가 실패한다(토큰 문자열은 원문에 존재).
  printf '{"token":"%s","expires_at":' "$CANARY" > "$GHT_RESP_FILE"
  _ght_run
  assert_ne "0" "$GHT_RC" "파싱 실패 시 비정상 종료여야 함" || { _ght_teardown; return; }
  assert_not_contains "$GHT_OUT" "$CANARY" "토큰이 stdout 으로 유출됨" || { _ght_teardown; return; }
  assert_not_contains "$GHT_ERR" "$CANARY" "토큰이 stderr 로 유출됨" || { _ght_teardown; return; }
  _ght_teardown
  pass
)

# G1-2 — 정상 에러 응답: message 진단은 보존, 토큰은 애초에 없음.
it "G1-2 에러 응답의 message 진단은 stderr 로 보존"
(
  _ght_setup
  printf '{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}' > "$GHT_RESP_FILE"
  _ght_run
  assert_ne "0" "$GHT_RC" "토큰 없음 → 비정상 종료여야 함" || { _ght_teardown; return; }
  assert_contains "$GHT_ERR" "Bad credentials" "message 진단이 stderr 에 없음(과잉 삭제)" || { _ght_teardown; return; }
  _ght_teardown
  pass
)

# G1-3 — 정상 토큰 응답: happy path 무회귀(exit 0 + stdout 이 정확히 토큰).
it "G1-3 정상 응답은 그대로 토큰 출력 (무회귀)"
(
  _ght_setup
  GOOD="ghs_GOODTOKEN_BBB222"
  printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}' "$GOOD" > "$GHT_RESP_FILE"
  _ght_run
  assert_eq "0" "$GHT_RC" "정상 응답인데 실패 종료" || { _ght_teardown; return; }
  assert_eq "$GOOD" "$GHT_OUT" "stdout 이 토큰과 다름" || { _ght_teardown; return; }
  _ght_teardown
  pass
)
