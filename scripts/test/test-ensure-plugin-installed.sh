#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# ensure-plugin-installed.sh 단위테스트 (이슈 #31 P3.3).
#   claude 를 stub 으로 가로채 plugin 설치 시퀀스(add→update→uninstall→install)와
#   소스 경로 주입을 검증한다. "왜 이 4단계인가(install/update 단독이 왜 부족한가)"는
#   스크립트 주석의 실측 근거 참조 — 테스트는 그 계약(순서·멱등 uninstall 무시·인자
#   누락 fail)을 회귀 그물로 고정한다. 시퀀스가 깨지면 "코드 고쳤는데 러너는 옛 버전"
#   유령버그가 되살아나므로 의미 있는 게이트다.

ENSURE_SH="$REPO_ROOT/scripts/ensure-plugin-installed.sh"

# claude stub 을 임시 PATH 에 깔고 ensure 스크립트를 실행한다.
# stub 은 호출 인자를 한 줄씩 CLAUDE_LOG 에 기록하고, plugin uninstall 은
# "미설치" 상황 모사로 exit 1 → 스크립트의 `|| true` 폴백 경로까지 검증한다.
run_ensure() {
  local src="$1" logf="$2" bindir
  bindir="$(mktemp -d)"
  cat > "$bindir/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_LOG"
# uninstall 은 미설치 상황 모사 — 비-0 종료해도 ensure 가 || true 로 넘어가야 한다.
if [ "$1" = "plugin" ] && [ "$2" = "uninstall" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$bindir/claude"
  CLAUDE_LOG="$logf" PATH="$bindir:$PATH" bash "$ENSURE_SH" "$src"
}

# EP-1 — 4단계가 올바른 순서로 호출된다(add→update→uninstall→install)
it "EP-1 설치 시퀀스 add→update→uninstall→install 순서"
(
  log="$(mktemp)"
  run_ensure "/tmp/some-source" "$log" >/dev/null 2>&1 || { fail "ensure 실행이 비-0 종료"; exit 0; }
  seq="$(tr '\n' '|' < "$log")"
  assert_contains "$seq" \
    "plugin marketplace add /tmp/some-source|plugin marketplace update pipeline|plugin uninstall pipeline@pipeline|plugin install pipeline@pipeline" \
    "시퀀스 불일치: $seq" || exit 0
  pass
)

# EP-2 — uninstall 이 실패(미설치)해도 install 까지 도달한다(|| true 폴백)
it "EP-2 uninstall 실패해도 install 도달"
(
  log="$(mktemp)"
  run_ensure "/tmp/src2" "$log" >/dev/null 2>&1 || { fail "ensure 가 uninstall 실패에 죽음(|| true 미동작)"; exit 0; }
  assert_contains "$(cat "$log")" "plugin install pipeline@pipeline" "install 미도달" || exit 0
  pass
)

# EP-3 — 마켓플레이스 소스 경로가 add 에 그대로 주입된다(종속성 제로 — 식별자 주입)
it "EP-3 소스 경로 인자 주입"
(
  log="$(mktemp)"
  run_ensure "/custom/checkout/root" "$log" >/dev/null 2>&1 || { fail "ensure 실행이 비-0 종료"; exit 0; }
  assert_contains "$(cat "$log")" "plugin marketplace add /custom/checkout/root" "소스 경로 미주입" || exit 0
  pass
)

# EP-4 — 소스 경로 인자 누락 시 즉시 실패(:? 가드, fail-fast)
it "EP-4 인자 누락 시 비-0 종료"
(
  bindir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bindir/claude"; chmod +x "$bindir/claude"
  rc=0
  CLAUDE_LOG=/dev/null PATH="$bindir:$PATH" bash "$ENSURE_SH" >/dev/null 2>&1 || rc=$?
  assert_ne 0 "$rc" "인자 없이도 성공함(:? 가드 미동작)" || exit 0
  pass
)
