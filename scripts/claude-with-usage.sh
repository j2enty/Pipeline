#!/usr/bin/env bash
# claude-with-usage.sh — claude CLI 호출을 감싸 "시간·토큰·비용"을 이슈/PR 코멘트로
#   박제하는 재사용 래퍼. self-hosted 러너의 자동화 워크플로(kickoff/review/critic/
#   critic-dispatch.yml)가 기존 `claude --dangerously-skip-permissions -p "..."` 호출을
#   이 스크립트 호출로 대체해 쓴다.
#
# ── 왜 composite action 이 아니라 script 인가 ────────────────────────────────
#   claude 호출 중 일부(review.yml)는 `while` 루프 안에서 `$TIMEOUT_CMD 30m claude ...`
#   형태로 "셸 한 줄"로 박혀 있고, 실패 시 `|| { rc=$?; ... }` 로 직접 분기한다.
#   composite action 은 step 단위라 이 루프/타임아웃/에러분기 한복판에 끼워 넣을 수 없다.
#   script 는 기존 `claude ...` 가 있던 바로 그 자리에 `bash claude-with-usage.sh ...` 로
#   1:1 치환되어 루프·`$TIMEOUT_CMD`·`|| {}` 구조를 그대로 보존한다.
#   (ensure-plugin 처럼 step 경계가 분명한 것만 composite action 으로 뺀다 — CLAUDE.md 원칙 4.)
#
# ── 동작 보존 (이 래퍼의 최우선 불변식) ────────────────────────────────────
#   1. exit code: claude 의 종료코드를 그대로 반환한다(PIPESTATUS 로 tee 너머 보존).
#      계측(코멘트 박제) 실패가 claude 실패를 삼키거나 성공을 실패로 바꾸지 않는다.
#   2. timeout: 타임아웃은 이 스크립트 "밖"에서 건다($TIMEOUT_CMD 30m bash 이파일 ...).
#      그래야 124(timeout) 가 호출부의 기존 `|| { rc=$?; [124 분기] }` 로 그대로 전파된다.
#   3. --dangerously-skip-permissions: 그대로 유지(아래 claude 호출에 포함).
#   4. 라이브 로그: --output-format stream-json --verbose 로 실행하고 stdout 을 tee 로
#      "그대로" 흘려 GitHub Actions 라이브 로그를 보존한다(--output-format json 은 스트리밍
#      로그가 사라져 못 씀). 마지막 {"type":"result",...} 이벤트만 따로 파싱해 계측한다.
#
# ── 사용법 ──────────────────────────────────────────────────────────────────
#   bash claude-with-usage.sh "<슬래시커맨드 프롬프트>"
#     예: bash claude-with-usage.sh "/pipeline:kickoff $PARENT_URL --bot"
#
# ── 환경변수(주입) ──────────────────────────────────────────────────────────
#   USAGE_METRICS_TARGET   계측 코멘트를 달 이슈/PR URL 또는 번호(필수는 아님 — 없으면
#                          계측 스킵, claude 는 정상 실행). 워크플로의 PARENT_URL/PR_URL.
#   USAGE_METRICS_ENABLED  'true'/'false' 명시 override. 미설정 시 config 토글
#                          (metrics.usage-tracking-enabled, 기본 false)을 리더로 읽는다.
#   PIPELINE_CONFIG_READER 토글을 읽을 pipeline-config.sh 경로(선택). 미설정 시 이 스크립트
#                          기준 상대경로(plugin/skills/kickoff/scripts/pipeline-config.sh)로
#                          탐색하고, 없으면 계측을 조용히 스킵(claude 는 정상 실행).
#   PIPELINE_CONFIG        리더가 읽을 config 경로(리더 규약 — 미설정 시 CWD 의
#                          .claude/pipeline-config.yml). 워크플로 CWD=working-directory.
#   USAGE_METRICS_LABEL    코멘트에 표기할 단계 라벨(선택. 예: kickoff·review·critic).
#   GH_TOKEN / GITHUB_TOKEN  gh 코멘트용 토큰(워크플로에 이미 존재). 둘 다 없으면 gh 가
#                          자체 처리 — 코멘트 실패는 best-effort 라 exit 에 영향 없음.
#
# ── 종속성 제로 ─────────────────────────────────────────────────────────────
#   레포 owner·App ID·토큰명·모듈명·슬랙 등 프로젝트 식별자를 하드코딩하지 않는다.
#   계측 대상·토글·라벨·config 경로는 전부 위 env 로 주입받는다.

set -uo pipefail

# claude 프롬프트는 첫 위치인자. 없으면 사용법 오류(exit 2 — claude 실행 전 설정 오류).
if [ "$#" -lt 1 ]; then
  echo "❌ claude-with-usage.sh: 프롬프트 인자가 필요합니다. 사용법: claude-with-usage.sh \"<슬래시커맨드>\"" >&2
  exit 2
fi
PROMPT="$1"
shift  # 남은 인자는 claude 에 그대로 추가 전달(확장용 — 보통 없음).

# ── 계측 토글 해석 (best-effort, 절대 claude 실행을 막지 않음) ─────────────
# 우선순위: USAGE_METRICS_ENABLED 명시 > config 토글(리더) > false.
METRICS_ENABLED="false"
if [ -n "${USAGE_METRICS_ENABLED:-}" ]; then
  # 명시 override — true 만 켜기로 인정(그 외 전부 off, 안전측).
  [ "${USAGE_METRICS_ENABLED}" = "true" ] && METRICS_ENABLED="true"
else
  # 리더 경로 결정: 명시 > 이 스크립트 기준 상대경로 탐색.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  READER="${PIPELINE_CONFIG_READER:-}"
  if [ -z "$READER" ]; then
    # scripts/ 와 같은 체크아웃 루트의 plugin/skills/*/scripts/pipeline-config.sh.
    # 3개 리더는 metrics 토글에 대해 동일 동작이라 아무거나 OK(kickoff 기준).
    for cand in \
      "$SCRIPT_DIR/../plugin/skills/kickoff/scripts/pipeline-config.sh" \
      "$SCRIPT_DIR/../plugin/skills/review/scripts/pipeline-config.sh" \
      "$SCRIPT_DIR/../plugin/skills/plan/scripts/pipeline-config.sh"; do
      if [ -f "$cand" ]; then READER="$cand"; break; fi
    done
  fi
  if [ -n "$READER" ] && [ -f "$READER" ]; then
    # 리더는 fail-soft — config 부재·키 부재 시 'false' 반환(metrics 기본 OFF).
    toggle="$(bash "$READER" metrics.usage-tracking-enabled 2>/dev/null || true)"
    [ "$toggle" = "true" ] && METRICS_ENABLED="true"
  fi
  # 리더를 못 찾으면 계측 스킵(METRICS_ENABLED=false 유지) — claude 는 정상 실행.
fi

# ── claude 실행 (stream-json + verbose, 라이브 로그 tee 보존) ───────────────
# result 이벤트 캡처용 임시 파일. 캡처 실패가 claude 실행을 막지 않도록 mktemp 실패도 fail-soft.
RESULT_CAPTURE="$(mktemp 2>/dev/null || echo "")"
# 스크립트 종료 시 정리(성공/실패/시그널 무관). RETURN 이 아니라 EXIT — 이 파일은 최상위 스크립트.
# (trap 으로 간접 호출 — shellcheck 가 직접 호출을 못 봐 SC2329 오탐.)
# shellcheck disable=SC2329
cleanup_capture() { [ -n "${RESULT_CAPTURE:-}" ] && rm -f "$RESULT_CAPTURE"; }
trap cleanup_capture EXIT

# claude stdout 을 tee 로 라이브 로그(터미널)에 흘리면서, 동시에 capture_result_line 로
# "마지막 {"type":"result"} 한 줄"만 RESULT_CAPTURE 에 남긴다(전체 트랜스크립트를 파일에
# 쌓지 않아 메모리/디스크 절약 + 파싱 단순화). capture 가 비활성(파일 없음)이면 그냥 cat.
capture_result_line() {
  if [ -n "${RESULT_CAPTURE:-}" ]; then
    # 각 줄을 통과시키면서 result 이벤트면 RESULT_CAPTURE 를 갱신(마지막 것이 최종 남음).
    while IFS= read -r line; do
      printf '%s\n' "$line"
      case "$line" in
        *'"type":"result"'*) printf '%s\n' "$line" > "$RESULT_CAPTURE" ;;
      esac
    done
  else
    cat
  fi
}

# [동작 보존 핵심] claude | capture 파이프라인에서 claude 의 exit code 를 PIPESTATUS[0]
# 으로 보존한다. set -o pipefail 이 켜져 있어도 capture(우측)의 exit 가 0 이라 그대로 두면
# 파이프 종료코드가 claude 코드가 되지만, capture 가 비정상 종료할 가능성을 배제하려
# 명시적으로 PIPESTATUS[0] 을 읽는다(가장 방어적).
set +e
claude --dangerously-skip-permissions --output-format stream-json --verbose \
  -p "$PROMPT" "$@" 2>&1 | capture_result_line
CLAUDE_RC="${PIPESTATUS[0]}"
set -e

# ── 계측 코멘트 박제 (토글 ON + 대상 + 캡처 성공일 때만, best-effort) ───────
# 이 블록의 어떤 실패도 claude 의 exit code 를 바꾸지 않는다(아래에서 CLAUDE_RC 로 exit).
if [ "$METRICS_ENABLED" = "true" ] && [ -n "${USAGE_METRICS_TARGET:-}" ] \
   && [ -n "${RESULT_CAPTURE:-}" ] && [ -s "$RESULT_CAPTURE" ]; then
  # result 이벤트에서 필드 추출 — python3 로 안전 파싱(jq 미설치 러너 대비 + 견고).
  # 파싱/코멘트 실패는 경고만 하고 넘어간다(|| true 와 서브셸 격리).
  COMMENT_BODY="$(
    python3 - "$RESULT_CAPTURE" "${USAGE_METRICS_LABEL:-}" 2>/dev/null <<'PYEOF' || true
import json, sys

result_path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else ''

try:
    with open(result_path) as f:
        line = f.read().strip()
    ev = json.loads(line)
except Exception:
    sys.exit(1)  # 파싱 실패 → 빈 출력(호출부가 코멘트 스킵)

if ev.get('type') != 'result':
    sys.exit(1)

def fmt_num(n):
    try:
        return f"{int(n):,}"
    except Exception:
        return str(n)

cost = ev.get('total_cost_usd')
usage = ev.get('usage') or {}
in_tok = usage.get('input_tokens', 0) or 0
out_tok = usage.get('output_tokens', 0) or 0
cache_read = usage.get('cache_read_input_tokens', 0) or 0
cache_create = usage.get('cache_creation_input_tokens', 0) or 0
dur_ms = ev.get('duration_ms')
turns = ev.get('num_turns')

parts = []
if cost is not None:
    try:
        parts.append(f"cost ${float(cost):.4f}")
    except Exception:
        parts.append(f"cost {cost}")
parts.append(f"in {fmt_num(in_tok)}·out {fmt_num(out_tok)} tok")
if cache_read or cache_create:
    parts.append(f"cache r{fmt_num(cache_read)}·w{fmt_num(cache_create)}")
if dur_ms is not None:
    try:
        parts.append(f"{float(dur_ms)/1000:.1f}s")
    except Exception:
        parts.append(f"{dur_ms}ms")
if turns is not None:
    parts.append(f"{turns} turns")

# modelUsage 가 있으면 모델명만 간결히(여러 모델이면 콤마).
models = ev.get('modelUsage') or {}
if isinstance(models, dict) and models:
    parts.append("model " + ", ".join(sorted(models.keys())))

head = "📊 usage"
if label:
    head += f" ({label})"
print(head + " — " + " / ".join(parts))
PYEOF
  )"
  if [ -n "$COMMENT_BODY" ]; then
    # 이슈/PR 공용 — gh issue comment 가 PR URL/번호도 처리한다(둘 다 동일 코멘트 API).
    # 실패해도 best-effort(|| true) — 토큰 없음·네트워크 등으로 exit 가 바뀌면 안 됨.
    if command -v gh >/dev/null 2>&1; then
      gh issue comment "$USAGE_METRICS_TARGET" --body "$COMMENT_BODY" >/dev/null 2>&1 \
        || echo "⚠️  claude-with-usage: 계측 코멘트 박제 실패(best-effort 스킵): $USAGE_METRICS_TARGET" >&2
    else
      echo "⚠️  claude-with-usage: gh 미설치 — 계측 코멘트 스킵" >&2
    fi
  else
    echo "⚠️  claude-with-usage: result 이벤트 파싱 실패 — 계측 코멘트 스킵" >&2
  fi
fi

# [동작 보존] claude 의 종료코드를 그대로 전파. 위 계측은 exit 에 영향 없음.
exit "$CLAUDE_RC"
