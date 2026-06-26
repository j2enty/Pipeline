#!/usr/bin/env bash
# plan-metrics.sh — /pipeline:plan 단계별 소요시간(+토큰) 계측 헬퍼.
#
# 무엇인가:
#   /plan 은 여러 무거운 AI 단계(planner·완결성 critic·정합성 critic·codex 교차검증)를
#   직렬로 돈다. "어느 단계가 ~20분의 범인인가"를 데이터로 드러내기 위해, 각 단계의
#   시작·종료 시각(epoch 초)을 상태 파일(TSV)에 append 하고, 끝에서 단계별 소요시간을
#   사람이 읽는 표로 집계한다.
#
#   SKILL.md 의 코드펜스는 "각각 별도 Bash 실행"이라 셸 변수가 펜스 간 전파되지 않는다.
#   따라서 단계 경계 시각은 **반드시 상태 파일**에 기록해야 한다(이 스크립트가 그 I/O 담당).
#   시각은 LLM 추정이 아니라 shell `date +%s` 로만 기록한다(deterministic).
#
# ── 상태 파일(TSV) 스키마 ────────────────────────────────────────────────────
#   탭 구분, 헤더 없음. 한 줄 = 한 이벤트. 컬럼:
#     1) kind   : "time" | "token"
#     2) label  : 단계 라벨 (interview·planner·completeness-critic·consistency-critic·codex-crosscheck)
#     3) phase  : kind=time 일 때 "start"|"end" / kind=token 일 때 토큰 종류("in"|"out"|"total" 등 자유)
#     4) value  : kind=time 이면 epoch 초(date +%s) / kind=token 이면 정수 토큰 수
#   예)
#     time	planner	start	1719300000
#     time	planner	end	1719300192
#     token	planner	in	53120
#     token	planner	out	8400
#
# ── 사용법 ──────────────────────────────────────────────────────────────────
#   plan-metrics.sh mark   <tsv> <label> start|end     # 단계 경계 시각 기록(date +%s)
#   plan-metrics.sh token  <tsv> <label> <kind> <n>    # 단계 토큰 수 기록(best-effort, 정수만)
#   plan-metrics.sh report <tsv>                       # 단계별 소요시간(+토큰) 표를 stdout 으로
#   plan-metrics.sh report-comment <tsv>               # parent 코멘트용 마크다운 표를 stdout 으로
#   plan-metrics.sh report-file <tsv> <out-path>       # report-comment 와 동일한 표를 파일로(데이터 없으면 미생성)
#   plan-metrics.sh fmt-duration <start-epoch> <end-epoch>   # epoch 쌍 → "3m12s" (단위 테스트용)
#
# ── 종속성 제로 ─────────────────────────────────────────────────────────────
#   순수 bash(3.2 호환 지향) + date 만. 프로젝트 식별자(owner·모듈명 등) 하드코딩 없음.
#   상태 파일 경로는 호출자가 인자로 주입한다(이 스크립트는 경로를 만들지 않는다).
#
# 종료코드: 정상 0, 인자/사용 오류 2. (계측 보조 도구라 report 는 데이터가 부실해도 0.)

set -uo pipefail

err() { printf "plan-metrics: %s\n" "$1" >&2; }

# ── fmt_duration: 초(정수) → "Xm Ys" / "Xs" / "Xh Ym Zs" 사람용 포맷 ──────────
#   음수·비정수 방어: 0 미만이거나 숫자가 아니면 "?" 를 돌려준다(누락/시계역행 방어).
fmt_duration_seconds() {
  local secs="$1"
  # 정수(부호 없는 0 이상)만 인정. 그 외 — 누락·역행·파싱오류 → "?"
  case "$secs" in
    ''|*[!0-9]*) printf '?'; return 0 ;;
  esac
  local h=$(( secs / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  local s=$(( secs % 60 ))
  if [ "$h" -gt 0 ]; then
    printf '%dh%02dm%02ds' "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then
    printf '%dm%02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# epoch 쌍(start,end) → 사람용 소요시간. end<start(시계 역행)·비정수 → "?".
fmt_duration_pair() {
  local start="$1" end="$2"
  case "$start" in ''|*[!0-9]*) printf '?'; return 0 ;; esac
  case "$end"   in ''|*[!0-9]*) printf '?'; return 0 ;; esac
  if [ "$end" -lt "$start" ]; then printf '?'; return 0; fi
  fmt_duration_seconds $(( end - start ))
}

# ── 상태 파일 초기화(truncate) ───────────────────────────────────────────────
#   왜: mark/token 은 append(>>) 만 한다. TSV 경로는 parent·slug 로만 결정돼 실행 간
#   동일하므로, 이전 실행이 §9.7 정리(rm) 전에 중단되면 잔여 TSV 가 남고, 같은 parent
#   재실행 시 _aggregate 의 토큰 합산(intok[label]+=val)이 옛 값까지 더해 실측이 부풀려진다.
#   → 첫 계측 펜스(§0 planner start 직전)에서 reset 으로 truncate 해 누적 오염을 차단한다.
#   (best-effort — truncate 실패해도 plan 흐름을 막지 않는다.)
cmd_reset() {
  local tsv="$1"
  [ -n "$tsv" ] || { err "reset: tsv 경로가 필요합니다"; return 2; }
  mkdir -p "$(dirname "$tsv")" 2>/dev/null || true
  : > "$tsv" 2>/dev/null || true
}

# ── 단계 경계 시각 기록 ──────────────────────────────────────────────────────
cmd_mark() {
  local tsv="$1" label="$2" phase="$3"
  case "$phase" in
    start|end) ;;
    *) err "mark phase 는 start|end 여야 합니다: '$phase'"; return 2 ;;
  esac
  [ -n "$tsv" ]   || { err "mark: tsv 경로가 필요합니다"; return 2; }
  [ -n "$label" ] || { err "mark: label 이 필요합니다"; return 2; }
  # 디렉토리 보장(없으면 만든다). append 실패는 best-effort — 계측이 plan 을 막지 않는다.
  mkdir -p "$(dirname "$tsv")" 2>/dev/null || true
  printf 'time\t%s\t%s\t%s\n' "$label" "$phase" "$(date +%s)" >> "$tsv" 2>/dev/null || true
}

# ── 단계 토큰 수 기록(best-effort) ───────────────────────────────────────────
#   value 가 정수가 아니면(추정·미표기) 조용히 스킵 — "추정 금지, 표기된 값만".
cmd_token() {
  local tsv="$1" label="$2" kind="$3" value="$4"
  [ -n "$tsv" ]   || { err "token: tsv 경로가 필요합니다"; return 2; }
  [ -n "$label" ] || { err "token: label 이 필요합니다"; return 2; }
  case "$value" in
    ''|*[!0-9]*)
      # 정수 아님(미표기·추정값) → 기록하지 않음(시간만 남는다). 실패 아님.
      return 0 ;;
  esac
  mkdir -p "$(dirname "$tsv")" 2>/dev/null || true
  printf 'token\t%s\t%s\t%s\n' "$label" "$kind" "$value" >> "$tsv" 2>/dev/null || true
}

# ── 집계 코어 ────────────────────────────────────────────────────────────────
# TSV 를 읽어 "label<TAB>seconds<TAB>in_tok<TAB>out_tok" 행을 라벨 등장순으로 stdout.
#   - 시간: 같은 label 의 마지막 start 와 마지막 end 로 구간 계산(펜스 재실행 대비 last-wins).
#   - 토큰: 같은 label·kind 합산. kind 가 in/out 이면 그 컬럼에, total 등은 in 에 합산.
#   - 누락(start 만/ end 만/ 역행)은 seconds="" 로 두고 report 가 "?" 로 표시.
# 순수 awk(이식성) — bash 연관배열(4+)·mapfile 회피.
_aggregate() {
  local tsv="$1"
  [ -f "$tsv" ] || return 0
  awk -F'\t' '
    {
      kind=$1; label=$2; ph=$3; val=$4;
      if (!(label in seen)) { seen[label]=1; order[++n]=label; }
      if (kind=="time") {
        if (ph=="start") start[label]=val;
        else if (ph=="end") end[label]=val;
      } else if (kind=="token") {
        if (val ~ /^[0-9]+$/) {
          if (ph=="in") intok[label]+=val;
          else if (ph=="out") outtok[label]+=val;
          else intok[label]+=val;   # total 등 기타 종류는 in 에 누적(근사)
        }
      }
    }
    END {
      for (i=1;i<=n;i++) {
        L=order[i];
        s="";
        if ((L in start) && (L in end) && end[L] ~ /^[0-9]+$/ && start[L] ~ /^[0-9]+$/ && end[L]>=start[L])
          s=end[L]-start[L];
        it=(L in intok)?intok[L]:"";
        ot=(L in outtok)?outtok[L]:"";
        printf "%s\t%s\t%s\t%s\n", L, s, it, ot;
      }
    }
  ' "$tsv"
}

# 사람용 라벨 — 내부 식별자 → 읽기 좋은 이름(없으면 원본 그대로).
#   동그라미 번호는 일부러 빼 둔다: report 는 라벨을 TSV 등장순으로 출력하므로, 원본 /plan
#   섹션번호(③·⑤ 등)를 붙이면 표가 '⑤ planner → ③ 완결성 → ⑤ 정합성' 처럼 뒤죽박죽 보이고
#   ⑤ 가 중복돼 단계 순서를 오해시킨다. 단계명만 두는 게 읽기 명확하다.
#   (interview 는 §0 가 '선택적'이라 명시한 라벨 — 현재 1단계 SKILL.md 펜스에선 emit 하지
#    않으나, --deep 인터뷰 계측을 후속에서 켤 때를 위해 매핑은 남겨 둔다.)
_pretty_label() {
  case "$1" in
    interview)            printf '인터뷰(선택)' ;;
    planner)              printf 'planner(영역 플래닝)' ;;
    completeness-critic)  printf '완결성 critic' ;;
    consistency-critic)   printf '정합성 critic' ;;
    codex-crosscheck)     printf '교차검증(codex 등)' ;;
    *)                    printf '%s' "$1" ;;
  esac
}

# ── report: 사람용 콘솔 표 ───────────────────────────────────────────────────
cmd_report() {
  local tsv="$1"
  [ -n "$tsv" ] || { err "report: tsv 경로가 필요합니다"; return 2; }
  printf '📊 plan 단계별 소요시간\n'
  if [ ! -f "$tsv" ] || [ ! -s "$tsv" ]; then
    printf '  (계측 데이터 없음)\n'
    return 0
  fi
  local total=0 any_time=0
  local label secs intok outtok dur tokstr
  while IFS=$'\t' read -r label secs intok outtok; do
    [ -n "$label" ] || continue
    if [ -n "$secs" ]; then
      dur="$(fmt_duration_seconds "$secs")"
      total=$(( total + secs )); any_time=1
    else
      dur='(미측정)'
    fi
    tokstr=''
    if [ -n "$intok" ] || [ -n "$outtok" ]; then
      tokstr="  ·  토큰 in ${intok:-0}·out ${outtok:-0}"
    fi
    printf '  %-26s %s%s\n' "$(_pretty_label "$label")" "$dur" "$tokstr"
  done < <(_aggregate "$tsv")
  if [ "$any_time" -eq 1 ]; then
    printf '  %-26s %s\n' '합계(측정 구간)' "$(fmt_duration_seconds "$total")"
  fi
}

# ── report-comment: parent 이슈 코멘트용 마크다운 ────────────────────────────
cmd_report_comment() {
  local tsv="$1"
  [ -n "$tsv" ] || { err "report-comment: tsv 경로가 필요합니다"; return 2; }
  if [ ! -f "$tsv" ] || [ ! -s "$tsv" ]; then
    # 데이터 없으면 빈 출력 — 호출자가 빈 코멘트를 스킵.
    return 0
  fi
  local total=0 any_time=0
  local label secs intok outtok dur
  printf '📊 plan timing\n\n'
  printf '| 단계 | 소요 | in tok | out tok |\n'
  printf '|---|---|---|---|\n'
  while IFS=$'\t' read -r label secs intok outtok; do
    [ -n "$label" ] || continue
    if [ -n "$secs" ]; then
      dur="$(fmt_duration_seconds "$secs")"
      total=$(( total + secs )); any_time=1
    else
      dur='(미측정)'
    fi
    printf '| %s | %s | %s | %s |\n' \
      "$(_pretty_label "$label")" "$dur" "${intok:-—}" "${outtok:-—}"
  done < <(_aggregate "$tsv")
  if [ "$any_time" -eq 1 ]; then
    printf '| **합계(측정 구간)** | **%s** | | |\n' "$(fmt_duration_seconds "$total")"
  fi
}

# ── report-file: report-comment 와 동일한 마크다운을 파일로 영구 보존 ─────────
#   왜: 계측 결과의 영구 보존을 §9.7(에필로그 코멘트 박제)에만 의존하면, 에필로그를
#   건너뛰면 데이터가 전량 소실된다. plan PR 에 파일로 커밋해 두면 §6b(반드시 도는 산출물)에
#   묻어가 보존이 보장된다. 렌더 로직은 중복 구현하지 않고 cmd_report_comment 를 그대로 재사용.
#   데이터가 없으면(렌더가 빈 출력) 파일을 만들지 않는다 — 빈 timing.md 커밋 방지.
#   (이미 같은 경로에 파일이 있어도 데이터 없으면 손대지 않는다.)
#   쓰기는 **원자적**: 임시파일에 먼저 쓰고 성공해야 mv -f 로 교체한다 → 부분쓰기로 깨진
#   timing.md 가 git add 글롭에 잡혀 커밋되는 것을 원천 차단. 쓰기·이동 실패는 silent 가
#   아니라 err 로 경고하되 return 0 유지 — 계측은 보조 산출물이라 실패가 호출자(/plan 본체)를
#   막으면 안 된다(silent 가 문제였지 비차단이 문제가 아니다).
cmd_report_file() {
  local tsv="$1" out="$2"
  [ -n "$tsv" ] || { err "report-file: tsv 경로가 필요합니다"; return 2; }
  [ -n "$out" ] || { err "report-file: out 경로가 필요합니다"; return 2; }
  local body
  body="$(cmd_report_comment "$tsv")"   # 동일 렌더러 재사용. 데이터 없으면 빈 문자열.
  [ -n "$body" ] || return 0            # 데이터 없음 → 파일 생성/수정 안 함(빈 표 방지·정상 경로).
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  local tmp="$out.tmp.$$"
  if printf '%s\n' "$body" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null; then
    return 0
  fi
  # 부분쓰기 흔적(임시파일) 제거 — 깨진/잔여 파일이 남지 않게 한 뒤 실패를 보이게 경고.
  rm -f "$tmp" 2>/dev/null || true
  err "report-file: '$out' 쓰기 실패(best-effort 스킵)"
  return 0
}

# ── 사용법(usage) — 헤더 docblock 통째 긁기(shebang·내부주석 노이즈) 대신 간결 요약 ──
usage() {
  cat <<'USAGE'
plan-metrics.sh — /plan 단계별 소요시간·토큰 계측 헬퍼

사용법:
  plan-metrics.sh reset  <tsv>                       # 상태파일 초기화(첫 펜스에서 1회 — 누적 오염 차단)
  plan-metrics.sh mark   <tsv> <label> start|end     # 단계 경계 시각 기록(date +%s)
  plan-metrics.sh token  <tsv> <label> <kind> <n>    # 단계 토큰 수 기록(정수만 — 추정 금지)
  plan-metrics.sh report <tsv>                       # 단계별 소요시간(+토큰) 콘솔 표
  plan-metrics.sh report-comment <tsv>               # parent 코멘트용 마크다운 표
  plan-metrics.sh report-file <tsv> <out-path>       # 마크다운 표를 파일로(데이터 없으면 미생성)
  plan-metrics.sh fmt-duration <start-epoch> <end-epoch>   # epoch 쌍 → "3m12s"
  plan-metrics.sh fmt-seconds  <seconds>                   # 초 → "3m12s"

라벨: planner · completeness-critic · consistency-critic · codex-crosscheck (선택: interview)
USAGE
}

# ── 디스패치 ─────────────────────────────────────────────────────────────────
SUB="${1:-}"
case "$SUB" in
  reset)           shift; cmd_reset "${1:-}" ;;
  mark)            shift; cmd_mark "${1:-}" "${2:-}" "${3:-}" ;;
  token)           shift; cmd_token "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  report)          shift; cmd_report "${1:-}" ;;
  report-comment)  shift; cmd_report_comment "${1:-}" ;;
  report-file)     shift; cmd_report_file "${1:-}" "${2:-}" ;;
  fmt-duration)    shift; fmt_duration_pair "${1:-}" "${2:-}"; printf '\n' ;;
  fmt-seconds)     shift; fmt_duration_seconds "${1:-}"; printf '\n' ;;
  -h|--help)       usage; exit 0 ;;
  '')              usage >&2; exit 2 ;;
  *)
    err "알 수 없는 서브커맨드 '$SUB'. 사용: reset|mark|token|report|report-comment|report-file|fmt-duration|fmt-seconds"
    exit 2 ;;
esac
