#!/usr/bin/env bash
# pipeline-config.sh — /pipeline:plan 런타임 config 리더.
#
# 슬래시커맨드가 "설치시 placeholder 치환" 대신 "실행시 config 읽기"로 전환하기 위한
# 도구. SKILL.md 의 코드펜스가 프로젝트값(owner·project-id·토글 등)을 이 스크립트로
# 실행시 읽어 주입한다. 값 추출 규칙은 본체 scripts/install.sh 의 parse_config() 와
# 동일하게 맞춰, 런타임 값이 install.sh 가 치환했을 값과 일치(parity)하도록 했다.
#
# 사용법:
#   pipeline-config.sh <key>          # 값을 stdout 으로 출력 (없으면 빈 줄)
#   pipeline-config.sh --dump         # 핵심값 요약 (사람·LLM 컨텍스트용)
#   pipeline-config.sh --keys         # 지원 키 목록
#   pipeline-config.sh --require <key>...   # 필수 키 검증 — 하나라도 비면 exit 1
#                                           # (원격쓰기 전 fail-fast 게이트. dry-run 은 호출 안 함)
#
# config 경로 결정: 환경변수 PIPELINE_CONFIG > CWD 의 .claude/pipeline-config.yml
#
# 지원 키 (friendly key → config 내 위치):
#   owner                          project.owner
#   parent-repository              project.parent-repository
#   parent-repo-name               (파생: parent-repository 의 repo 부분 a/b→b)
#   project-number                 (파생: project.project-numbers[0])
#   slack-channel                  project.slack-channel (옵션)
#   project-name                   claude-commands.project-name
#   project-id                     claude-commands.project-id
#   status-field-id                claude-commands.status-field-id
#   area-field-id                  claude-commands.area-field-id
#   author-login                   claude-commands.author-login
#   local-account                  claude-commands.local-account
#   docs-context-dir               claude-commands.docs-context-dir
#   base-branch                    claude-commands.base-branch (기본 develop — kickoff PR/rebase 대상 base 브랜치)
#   status-trigger-kickoff         project.status-triggers.kickoff (기본 In Progress — 폴러/SKILL kickoff 트리거 컬럼)
#   status-trigger-review          project.status-triggers.review  (기본 Bot Review — 폴러/SKILL review 트리거 컬럼)
#   status-column-in-review        project.status-columns.in-review (기본 In Review — /review 7-h APPROVE 도착 컬럼, SKILL 전용)
#   status-column-ready            project.status-columns.ready     (기본 Ready — kickoff skip 분류·lead 게이트, SKILL 전용)
#   status-column-backlog          project.status-columns.backlog   (기본 Backlog — kickoff skip 분류, SKILL 전용)
#   status-column-done             project.status-columns.done      (기본 Done — 머지 완료 skip, SKILL 전용)
#   cross-check-tool               claude-commands.cross-check-tool (기본 codex — plan 교차검증용 외부 도구, 범용 pipeline:ask 에이전트에 전달됨)
#   codex-model                    claude-commands.codex-model (기본 빈값 — plan codex exec 교차검증 + review codex review 두 경로 공통 모델명, 빈값이면 미주입=codex 기본)
#   codex-reasoning-effort         claude-commands.codex-reasoning-effort (기본 빈값 — 위 모델 reasoning effort, 빈값이면 미주입)
#   area-id.<Name>                 modules[Name].area-id 우선 → legacy claude-commands.area-ids.<Name> 폴백
#   module.<Name>.<flag>           modules[Name].<flag> (flag: role·ci-workflow-name·area-id·
#                                  planner·review·kickoff·lead·default-status·cross-area-group)
#   --list-modules                 모듈명을 정의순으로 1줄씩
#   --modules-where <flag>=<val>   조건 매칭 모듈명 1줄씩(정의순). 예: --modules-where lead=true
#   --modules-table                TSV 표(헤더행 포함): name⇥role⇥planner⇥review⇥kickoff⇥lead⇥
#                                  default-status⇥cross-area-group⇥area-id⇥ci-workflow-name
#   plan.completeness-critic-enabled       claude-commands.plan.* (기본 true)
#   plan.consistency-critic-enabled        (기본 true)
#   plan.consistency-critic-dual-model     (기본 true)
#   plan.contract-doc-enabled              (기본 true)
#   metrics.usage-tracking-enabled         claude-commands.metrics.* (기본 false — opt-in)
#   janus.notify-enabled                   claude-commands.janus.notify-enabled (기본 false — opt-in, /plan Step 9.8 버튼 알림)
#   janus.base-url-key                     claude-commands.janus.base-url-key (Janus base URL 담은 env 이름표, 기본 빈값)
#   janus.token-key                        claude-commands.janus.token-key (Janus 토큰 담은 env 이름표, 기본 빈값)
#
# fail-soft: config 부재·키 부재 시 빈 값(토글은 기본 true) + stderr 경고, exit 0.
#   (dry-run/플랜 흐름이 config 없다고 중단되지 않도록 — 호출부가 빈 값 처리.)

set -uo pipefail

CONFIG_PATH="${PIPELINE_CONFIG:-.claude/pipeline-config.yml}"

if [ $# -lt 1 ]; then
  echo "❌ 키가 필요합니다. 사용법: pipeline-config.sh <key>|--dump|--keys" >&2
  exit 2
fi

# config 부재 — fail-soft. 토글 키는 기본 true, 나머지는 빈 값.
# 단 --require(필수 키 검증)는 config 부재 자체가 실패 → exit 1 (원격쓰기 전 게이트).
if [ ! -f "$CONFIG_PATH" ]; then
  if [ "${1:-}" = "--require" ]; then
    echo "❌ pipeline-config: config 파일 없음 — 필수 키 검증 실패: $CONFIG_PATH" >&2
    exit 1
  fi
  echo "⚠️  pipeline-config: config 파일 없음: $CONFIG_PATH (빈 값 반환)" >&2
  case "${1:-}" in
    plan.*-enabled|plan.*-dual-model) printf 'true\n' ;;  # 토글 기본 ON (install.sh 기본과 일치)
    metrics.*-enabled) printf 'false\n' ;;  # 계측 토글 기본 OFF — opt-in (이식 안전)
    janus.notify-enabled) printf 'false\n' ;;  # Janus 버튼 알림 토글 기본 OFF — opt-in
    base-branch) printf 'develop\n' ;;  # kickoff PR/rebase base 브랜치 — 기본 develop (다른 스칼라와 달리 빈값 아님)
    status-trigger-kickoff) printf 'In Progress\n' ;;  # 폴러/SKILL kickoff 트리거 컬럼 — 기본 In Progress
    status-trigger-review) printf 'Bot Review\n' ;;     # 폴러/SKILL review 트리거 컬럼 — 기본 Bot Review
    status-column-in-review) printf 'In Review\n' ;;  # /review 7-h APPROVE 도착 컬럼 — 기본 In Review (SKILL 전용)
    status-column-ready) printf 'Ready\n' ;;          # kickoff skip 분류·lead 게이트 — 기본 Ready (SKILL 전용)
    status-column-backlog) printf 'Backlog\n' ;;      # kickoff skip 분류 — 기본 Backlog (SKILL 전용)
    status-column-done) printf 'Done\n' ;;            # 머지 완료 skip — 기본 Done (SKILL 전용)
    cross-check-tool) printf 'codex\n' ;;  # 외부 2차 의견 도구 — 기본 codex (다른 스칼라와 달리 빈값 아님)
    # --keys 는 정적 지원키 카탈로그라 config 유무와 무관하게 항상 동일 출력
    # (아래 python 블록의 --keys 분기와 동일 목록). --dump 는 config 내용 요약이라 부재 시 빈 게 맞음.
    --keys) printf '%s\n' \
      'owner' 'parent-repository' 'parent-repo-name' 'project-number' 'slack-channel' \
      'project-name' 'project-id' 'status-field-id' 'area-field-id' \
      'author-login' 'local-account' 'docs-context-dir' 'base-branch' \
      'status-trigger-kickoff' 'status-trigger-review' 'cross-check-tool' \
      'codex-model' 'codex-reasoning-effort' \
      'status-column-in-review' 'status-column-ready' 'status-column-backlog' 'status-column-done' \
      'area-id.<Name>' \
      'plan.completeness-critic-enabled' 'plan.consistency-critic-enabled' \
      'plan.consistency-critic-dual-model' 'plan.contract-doc-enabled' \
      'metrics.usage-tracking-enabled' \
      'janus.notify-enabled' 'janus.base-url-key' 'janus.token-key' \
      '--list-modules' 'module.<Name>.<flag>' '--modules-where <flag>=<val>' '--modules-table' ;;
    --dump) : ;;
    # modules 인터페이스 — config 부재 시 모듈 없음(빈 출력). 단 표는 헤더행만.
    --list-modules|--modules-where) : ;;
    --modules-table) printf 'name\trole\tplanner\treview\tkickoff\tlead\tdefault-status\tcross-area-group\tarea-id\tci-workflow-name\n' ;;
    *) printf '\n' ;;
  esac
  exit 0
fi

python3 - "$CONFIG_PATH" "$@" <<'PYEOF'
import sys, re

config_path = sys.argv[1]
arg = sys.argv[2] if len(sys.argv) > 2 else ''
with open(config_path) as f:
    content = f.read()

# ── install.sh parse_config() 와 동일한 추출 헬퍼 ──────────────────────
def section(text, name):
    """최상위 키 `name:` 블록을 다음 최상위 키 직전까지 슬라이스."""
    m = re.search(rf'^{re.escape(name)}:\s*\n(.*?)(?=^\S|\Z)', text, re.MULTILINE | re.DOTALL)
    return m.group(1) if m else ''

def get_scalar_in(block, key, default=''):
    """따옴표 우선(내부 # 허용) → 무따옴표 폴백(인라인 주석 제거). install.sh 와 동일."""
    # 값 앞 공백은 [ \t]* (개행 비흡수). \s* 는 python 에서 개행을 포함해, 값이 비면
    # 다음 줄 키를 빨아들이는 버그가 있다(예: area-id 빈 필드가 다음 줄 planner: 를 흡수).
    # 닫는 따옴표 뒤 줄끝에 선택적 인라인 주석((?:#.*)?$) 허용 — `key: "X CI"  # 주석` 에서
    # 따옴표 분기가 매칭 실패해 무따옴표 폴백이 첫 글자 `"` 로 빈 캡처되는 값 소실 방지(#52).
    # 따옴표 안쪽 # 은 그대로 보존([^"\n]* 가 닫는 따옴표까지 캡처 — slack-channel: "#x" 등).
    mq = re.search(rf'^\s+{re.escape(key)}:[ \t]*"([^"\n]*)"\s*(?:#.*)?$', block, re.MULTILINE)
    if not mq:
        mq = re.search(rf"^\s+{re.escape(key)}:[ \t]*'([^'\n]*)'\s*(?:#.*)?$", block, re.MULTILINE)
    if mq:
        return mq.group(1).strip()
    m = re.search(rf'^\s+{re.escape(key)}:[ \t]*([^"#\n]*)', block, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m and m.group(1).strip() else default

# 따옴표 분기 우선 값 캡처 조각 — 따옴표 안 # 보존(#57). get_scalar_in 과 동일 철학:
#   "..."  → 그룹1(닫는 따옴표까지, # 포함. * 라 빈 따옴표 ""→빈문자열)
#   '...'  → 그룹2(동일. ''→빈문자열)
#   무따옴표 → 그룹3([^"#\n]+? 비탐욕, # 이후는 인라인 주석으로 폴백)
# 줄끝 선택적 인라인 주석((?:#.*)?$)은 호출부 패턴이 붙인다. pick_quoted_value() 로 그룹 선택.
# 빈 따옴표 처리(#57 후속): 두 따옴표 분기를 * 로 둬 ""/'' 가 빈 문자열로 캡처되게 한다.
#   (+ 였으면 빈 따옴표가 분기 미매치 → 무따옴표 폴백이 두 따옴표 `''` 자체를 캡처해 리터럴
#    '' 가 새고 install↔reader parity 가 깨졌다. is not None 기준이라 빈 문자열도 반환됨.)
QUOTED_VALUE = r'''(?:"([^"\n]*)"|'([^'\n]*)'|([^"#\n]+?))'''

def pick_quoted_value(m):
    """QUOTED_VALUE 3분기 중 매칭 그룹 반환(없으면 ''). 따옴표 분기는 .strip() 만(내용 보존),
       무따옴표 폴백 그룹은 추가로 .strip(\"'\\\"\") — 폴백으로 샌 따옴표를 벗겨 빈값 통일(belt&suspenders)."""
    if m.group(1) is not None:
        return m.group(1).strip()
    if m.group(2) is not None:
        return m.group(2).strip()
    if m.group(3) is not None:
        return m.group(3).strip().strip("'\"")
    return ''

PROJECT = section(content, 'project')
CC = section(content, 'claude-commands')

# claude-commands.plan 서브블록 (install.sh 와 동일 앵커: 들여쓰기 \1 캡처)
plan_m = re.search(r'^([ \t]+)plan:\s*\n(.*?)(?=^\1\S|\Z)', CC, re.MULTILINE | re.DOTALL)
PLAN_BLOCK = plan_m.group(2) if plan_m else ''

# claude-commands.metrics 서브블록 (plan 과 동일 앵커 — 들여쓰기 \1 캡처).
# 계측(시간·토큰·비용) 토글 모음. 키 부재 시 metrics_bool 이 기본 false 로 폴백한다.
metrics_m = re.search(r'^([ \t]+)metrics:\s*\n(.*?)(?=^\1\S|\Z)', CC, re.MULTILINE | re.DOTALL)
METRICS_BLOCK = metrics_m.group(2) if metrics_m else ''

# claude-commands.janus 서브블록 (plan·metrics 와 동일 앵커 — 들여쓰기 \1 캡처).
# /plan Step 9.8 Janus 버튼 알림용 토글·env 이름표. notify-enabled 는 기본 false(opt-in),
# base-url-key/token-key 는 Janus 타깃 env 이름표(빈값이면 SKILL 이 직접 env 로 폴백).
janus_m = re.search(r'^([ \t]+)janus:\s*\n(.*?)(?=^\1\S|\Z)', CC, re.MULTILINE | re.DOTALL)
JANUS_BLOCK = janus_m.group(2) if janus_m else ''

# claude-commands.area-ids 서브블록
ai = re.search(r'^([ \t]+)area-ids:[ \t]*\n((?:\1[ \t]+\S.*\n?|[ \t]*\n)*)', CC, re.MULTILINE)
AREA_BLOCK = ai.group(2) if ai else ''

# project.status-triggers 서브블록 — 폴러/SKILL 공용 트리거 컬럼명(#106).
# App(env)·install.sh·이 리더가 같은 config 값을 읽어 "폴러 dispatch ↔ SKILL 비교"가
# 한 컬럼명으로 정렬되게 한다. 하위키 kickoff/review 는 modules[].kickoff/review 플래그와
# 이름이 겹치므로 반드시 이 블록 내부에서만 읽는다(경계: area-ids 와 동일 패턴 — 더 깊은
# 들여쓰기만 캡처, 형제/최상위 dedent 에서 멈춤).
st = re.search(r'^([ \t]+)status-triggers:[ \t]*\n((?:\1[ \t]+\S.*\n?|[ \t]*\n)*)', PROJECT, re.MULTILINE)
STATUS_TRIGGERS_BLOCK = st.group(2) if st else ''

# project.status-columns 서브블록 — 비-트리거 도착/경유 컬럼명(#115). status-triggers 와
# 나란히 두되 별개 블록이다(통합 맵 재설계 아님). /kickoff·/review SKILL 이 sub-issue Status
# 비교·전환에 쓰는 컬럼명(in-review=APPROVE 도착, ready/backlog=kickoff skip 분류, done=머지
# 완료 skip)을 config 로 재정의 가능하게 한다. 트리거와 달리 App 폴러는 소비하지 않고 SKILL
# 전용(이 리더만 읽음). 블록 격리는 status-triggers·area-ids 와 동일 패턴 — 하위키가 modules[]
# 플래그와 겹칠 여지를 원천 차단(더 깊은 들여쓰기만 캡처, 형제/최상위 dedent 에서 멈춤).
sc = re.search(r'^([ \t]+)status-columns:[ \t]*\n((?:\1[ \t]+\S.*\n?|[ \t]*\n)*)', PROJECT, re.MULTILINE)
STATUS_COLUMNS_BLOCK = sc.group(2) if sc else ''

def plan_bool(key, default='true'):
    """true/false 만 인정(따옴표 허용). 오타·누락 → default. install.sh get_plan_bool 동일."""
    m = re.search(r'^[ \t]+' + re.escape(key) + r':\s*["\']?(true|false)["\']?\s*(?:#.*)?$',
                  PLAN_BLOCK, re.MULTILINE | re.IGNORECASE)
    return m.group(1).lower() if m else default

def metrics_bool(key, default='false'):
    """metrics 서브블록 boolean — true/false 만 인정(따옴표 허용). 오타·누락 → default.
       계측 토글은 opt-in 이라 기본 false (plan_bool 의 기본 true 와 대비)."""
    m = re.search(r'^[ \t]+' + re.escape(key) + r':\s*["\']?(true|false)["\']?\s*(?:#.*)?$',
                  METRICS_BLOCK, re.MULTILINE | re.IGNORECASE)
    return m.group(1).lower() if m else default

def janus_bool(key, default='false'):
    """janus 서브블록 boolean — true/false 만 인정(따옴표 허용). 오타·누락 → default.
       Janus 버튼 알림은 opt-in 이라 기본 false (metrics_bool 과 동일 철학)."""
    m = re.search(r'^[ \t]+' + re.escape(key) + r':\s*["\']?(true|false)["\']?\s*(?:#.*)?$',
                  JANUS_BLOCK, re.MULTILINE | re.IGNORECASE)
    return m.group(1).lower() if m else default

def project_number():
    pn = re.search(r'project-numbers:\s*\[([^\]]*)\]', content)
    nums = re.findall(r'\d+', pn.group(1)) if pn else []
    return nums[0] if nums else ''

def parent_repo_name():
    pr = get_scalar_in(PROJECT, 'parent-repository')
    return pr.rsplit('/', 1)[-1] if pr else ''

def area_id(name):
    # 값 앞 공백은 [ \t]* (개행 비흡수) — get_scalar_in 과 동일 이유.
    # 따옴표 분기 우선(따옴표 안 # 보존, #57) → 무따옴표 폴백(인라인 주석 제거, #52).
    m = re.search(rf'^\s+{re.escape(name)}:[ \t]*{QUOTED_VALUE}\s*(?:#.*)?$', AREA_BLOCK, re.MULTILINE)
    return pick_quoted_value(m) if m else ''

# ── modules 블록 파싱 (install.sh parse_config() 의 블록분할 방식 포팅) ──────
# 주의: positional 추출 금지. 각 `- name:` 부터 다음 `- name:` 직전까지를 한
#       블록으로 잘라 블록 내부에서만 플래그를 찾아 모듈↔값 정렬을 보장한다.
#       (install.sh L208-238 의 블록분할 정규식과 동일 — strict-review-bot-check
#        가 일부 모듈에만 있어 전체 positional 추출이 어긋나는 문제를 막기 위함.)
MODULES = section(content, 'modules')

# 모듈 플래그 기본값 (미지정 시 fail-soft). boolean 은 true/false 만 인정.
MODULE_BOOL_DEFAULTS = {'planner': 'true', 'review': 'true', 'kickoff': 'true', 'lead': 'false'}
MODULE_SCALAR_DEFAULTS = {'default-status': 'Ready', 'role': '', 'area-id': '',
                          'cross-area-group': '', 'ci-workflow-name': ''}

def warn_malformed_module_names(text):
    """`- name:` 행 중 값 추출에 실패하는 것(예: 미종결 따옴표 `name: "ab`)을 stderr 경고.
       조용한 누락(#52 footgun 재현)을 막기 위함 — 동작은 그대로(해당 모듈만 빠짐)."""
    for lm in re.finditer(r'^\s+-\s+name:.*$', text, re.MULTILINE):
        line = lm.group(0)
        if not re.match(rf'^\s+-\s+name:\s*{QUOTED_VALUE}\s*(?:#.*)?$', line):
            sys.stderr.write(f"⚠️  pipeline-config: 모듈 name 파싱 실패(미종결 따옴표 등) — "
                             f"해당 모듈 누락: {line.strip()}\n")

def module_blocks():
    """[(name, block), ...] 를 정의(나열)순으로 반환."""
    # 따옴표 분기 우선(따옴표 안 # 보존, #57) → 무따옴표 폴백(인라인 주석 제거, #52).
    # 무따옴표 모듈명에 # 가 오면 주석 경계로 본다(값 밖 # 만 주석). 따옴표로 감싸면 보존.
    warn_malformed_module_names(MODULES)
    name_iter = list(re.finditer(rf'^\s+-\s+name:\s*{QUOTED_VALUE}\s*(?:#.*)?$', MODULES, re.MULTILINE))
    out = []
    for idx, m in enumerate(name_iter):
        name = pick_quoted_value(m)
        block_start = m.end()
        block_end = name_iter[idx + 1].start() if idx + 1 < len(name_iter) else len(MODULES)
        out.append((name, MODULES[block_start:block_end]))
    return out

def module_bool_in(block, flag, default):
    """블록 내 boolean 플래그 — true/false 만 인정(따옴표 허용). 오타·누락 → default."""
    m = re.search(r'^[ \t]+' + re.escape(flag) + r':\s*["\']?(true|false)["\']?\s*(?:#.*)?$',
                  block, re.MULTILINE | re.IGNORECASE)
    return m.group(1).lower() if m else default

def resolve_module_flag(name, flag):
    """module.<Name>.<flag> — 정의 블록에서 flag 값 추출(대소문자 구분 name 매칭)."""
    block = None
    for mname, mblock in module_blocks():
        if mname == name:
            block = mblock
            break
    if block is None:
        # 모듈 부재 — area-id 만은 legacy area-ids 맵으로 폴백(친화 키 area-id.<Name>
        # 하위호환: 모듈을 modules 에 안 적고 legacy 맵에만 둔 구성 지원). 나머지는 빈 값.
        return area_id(name) if flag == 'area-id' else ''
    if flag in MODULE_BOOL_DEFAULTS:
        return module_bool_in(block, flag, MODULE_BOOL_DEFAULTS[flag])
    if flag == 'area-id':
        # modules[name].area-id 우선 → 없으면 legacy claude-commands.area-ids.<name> 폴백
        v = get_scalar_in(block, 'area-id')
        return v if v else area_id(name)
    if flag in MODULE_SCALAR_DEFAULTS:
        return get_scalar_in(block, flag, MODULE_SCALAR_DEFAULTS[flag])
    sys.stderr.write(f"⚠️  pipeline-config: 알 수 없는 모듈 플래그 '{flag}' (빈 값)\n")
    return ''

def lead_warn_if_multiple():
    """lead=true 가 2개 이상이면 stderr 경고(동작은 정의순 직렬)."""
    leads = [n for n, _ in module_blocks() if resolve_module_flag(n, 'lead') == 'true']
    if len(leads) >= 2:
        sys.stderr.write("⚠️  pipeline-config: lead 모듈이 2개 이상 — 정의순 직렬 선행 처리 ("
                         + ", ".join(leads) + ")\n")

MODULE_TABLE_FLAGS = ['role', 'planner', 'review', 'kickoff', 'lead',
                      'default-status', 'cross-area-group', 'area-id', 'ci-workflow-name']

def resolve(key):
    # 파생 키
    if key == 'parent-repo-name':
        return parent_repo_name()
    if key == 'project-number':
        return project_number()
    if key.startswith('area-id.'):
        # 레거시 친화 키 — modules.area-id 우선 → legacy area-ids 폴백
        return resolve_module_flag(key.split('.', 1)[1], 'area-id')
    if key.startswith('module.'):
        # module.<Name>.<flag> — name 에 '.' 이 없다고 가정(모듈명 규칙). 마지막 '.' 로 flag 분리.
        rest = key.split('.', 1)[1]
        if '.' not in rest:
            sys.stderr.write(f"⚠️  pipeline-config: 잘못된 module 키 '{key}' (module.<Name>.<flag> 형식 필요)\n")
            return ''
        mname, flag = rest.rsplit('.', 1)
        return resolve_module_flag(mname, flag)
    if key.startswith('plan.'):
        return plan_bool(key.split('.', 1)[1])
    if key.startswith('metrics.'):
        # 계측 토글 — 기본 false(opt-in). claude-commands.metrics.<key> 에서 읽음.
        return metrics_bool(key.split('.', 1)[1])
    if key.startswith('janus.'):
        # Janus 버튼 알림(/plan Step 9.8) — notify-enabled 는 bool(기본 false=opt-in),
        # base-url-key/token-key 는 env 이름표 스칼라(기본 빈값). claude-commands.janus.<key>.
        subkey = key.split('.', 1)[1]
        if subkey == 'notify-enabled':
            return janus_bool('notify-enabled')
        if subkey in ('base-url-key', 'token-key'):
            return get_scalar_in(JANUS_BLOCK, subkey)
        sys.stderr.write(f"⚠️  pipeline-config: 알 수 없는 janus 키 '{key}' (빈 값)\n")
        return ''
    # project 섹션 스칼라
    if key in ('owner', 'parent-repository', 'slack-channel'):
        return get_scalar_in(PROJECT, key)
    # base-branch — kickoff PR/rebase base 브랜치. 부재·빈값 모두 develop 폴백
    # (cross-check-tool 과 동일 철학: get_scalar_in default 는 키 부재 시만 적용되므로
    #  #57 빈따옴표 → 빈문자열을 한 번 더 develop 로 보정해 "항상 비지 않은 브랜치명" 불변식 보장).
    if key == 'base-branch':
        return get_scalar_in(CC, 'base-branch', 'develop') or 'develop'
    # status-trigger-{kickoff,review} — 폴러/SKILL 공용 트리거 컬럼명(#106). project.
    # status-triggers.{kickoff,review} 에서 읽고, 부재·빈값 모두 기본 컬럼명으로 폴백해
    # "항상 비지 않은 컬럼명" 불변식 보장(base-branch 와 동일 철학). App env 기본값과 일치.
    if key == 'status-trigger-kickoff':
        return get_scalar_in(STATUS_TRIGGERS_BLOCK, 'kickoff', 'In Progress') or 'In Progress'
    if key == 'status-trigger-review':
        return get_scalar_in(STATUS_TRIGGERS_BLOCK, 'review', 'Bot Review') or 'Bot Review'
    # status-column-{in-review,ready,backlog,done} — 비-트리거 도착/경유 컬럼명(#115). project.
    # status-columns.<key> 에서 읽고, 부재·빈값 모두 기본 컬럼명으로 폴백해 "항상 비지 않은
    # 컬럼명" 불변식 보장(status-trigger-*·base-branch 와 동일 철학). config 미지정 프로젝트는
    # 현행 하드코딩 값과 100% 동일하게 동작(이식 안전). SKILL 전용 — App 폴러는 소비 안 함.
    if key == 'status-column-in-review':
        return get_scalar_in(STATUS_COLUMNS_BLOCK, 'in-review', 'In Review') or 'In Review'
    if key == 'status-column-ready':
        return get_scalar_in(STATUS_COLUMNS_BLOCK, 'ready', 'Ready') or 'Ready'
    if key == 'status-column-backlog':
        return get_scalar_in(STATUS_COLUMNS_BLOCK, 'backlog', 'Backlog') or 'Backlog'
    if key == 'status-column-done':
        return get_scalar_in(STATUS_COLUMNS_BLOCK, 'done', 'Done') or 'Done'
    # claude-commands 섹션 스칼라 — cross-check-tool 만 기본값 codex (나머지는 빈 값 기본)
    if key == 'cross-check-tool':
        # 키 부재뿐 아니라 명시적 빈값(cross-check-tool: "" / '')도 codex 로 폴백 —
        # get_scalar_in 의 default 는 키 부재 시만 적용되므로(#57 빈따옴표 → 빈문자열),
        # 빈값을 한 번 더 codex 로 보정해 "항상 비지 않은 도구명" 불변식을 보장한다.
        return get_scalar_in(CC, 'cross-check-tool', 'codex') or 'codex'
    # codex-model·codex-reasoning-effort — plan codex exec 교차검증 + review codex review
    # 두 경로 공통 주입값(#83 통합 키). cross-check-tool 과 달리 기본 빈값(다른 빈값 기본
    # CC 스칼라와 동일 처리) — 빈값이면 SKILL 이 codex 플래그를 안 붙여 codex 자체 기본으로
    # 동작(본체 회귀 없음).
    if key in ('project-name', 'project-id', 'status-field-id', 'area-field-id',
               'author-login', 'local-account', 'docs-context-dir',
               'codex-model', 'codex-reasoning-effort'):
        return get_scalar_in(CC, key)
    # 알 수 없는 키 — fail-soft 빈 값 (stderr 경고)
    sys.stderr.write(f"⚠️  pipeline-config: 알 수 없는 키 '{key}' (빈 값)\n")
    return ''

if arg == '--list-modules':
    # 모듈명을 정의(나열)순으로 1줄씩
    for name, _ in module_blocks():
        print(name)
elif arg == '--modules-where':
    # --modules-where <flag>=<val> — 조건 매칭 모듈명 1줄씩(정의순)
    cond = sys.argv[3] if len(sys.argv) > 3 else ''
    if '=' not in cond:
        sys.stderr.write("⚠️  pipeline-config: --modules-where 는 <flag>=<val> 형식이 필요합니다\n")
    else:
        flag, _, val = cond.partition('=')
        flag = flag.strip(); val = val.strip()
        for name, _block in module_blocks():
            if resolve_module_flag(name, flag) == val:
                print(name)
elif arg == '--modules-table':
    # TSV — 헤더행 포함. SKILL.md 가 표 1회 흡수용.
    lead_warn_if_multiple()
    header = ['name'] + MODULE_TABLE_FLAGS
    print('\t'.join(header))
    for name, _block in module_blocks():
        row = [name] + [resolve_module_flag(name, f) for f in MODULE_TABLE_FLAGS]
        print('\t'.join(row))
elif arg == '--keys':
    print('\n'.join([
        'owner', 'parent-repository', 'parent-repo-name', 'project-number', 'slack-channel',
        'project-name', 'project-id', 'status-field-id', 'area-field-id',
        'author-login', 'local-account', 'docs-context-dir', 'base-branch',
        # 폴러/SKILL 공용 트리거 컬럼명 (project.status-triggers.*)
        'status-trigger-kickoff', 'status-trigger-review', 'cross-check-tool',
        # plan·review codex 교차검증 공통 모델·effort 주입값 (기본 빈값 — 빈값이면 codex 기본, #83)
        'codex-model', 'codex-reasoning-effort',
        # 비-트리거 도착/경유 컬럼 (project.status-columns.* — SKILL 전용, #115)
        'status-column-in-review', 'status-column-ready', 'status-column-backlog', 'status-column-done',
        'area-id.<Name>',
        'plan.completeness-critic-enabled', 'plan.consistency-critic-enabled',
        'plan.consistency-critic-dual-model', 'plan.contract-doc-enabled',
        # 계측 토글 (기본 false — opt-in). 워크플로 claude 래퍼가 읽어 코멘트 박제 on/off.
        'metrics.usage-tracking-enabled',
        # Janus 버튼 알림 (기본 false — opt-in). /plan Step 9.8 이 버튼 달린 Slack 알림 발사.
        'janus.notify-enabled', 'janus.base-url-key', 'janus.token-key',
        # modules 인터페이스 — 모듈 동작 의미론(planner/review/kickoff/lead 등)
        '--list-modules', 'module.<Name>.<flag>', '--modules-where <flag>=<val>', '--modules-table',
    ]))
elif arg == '--dump':
    keys = ['owner', 'parent-repository', 'parent-repo-name', 'project-number', 'slack-channel',
            'project-name', 'project-id', 'status-field-id', 'area-field-id',
            'author-login', 'local-account', 'docs-context-dir', 'cross-check-tool',
            'codex-model', 'codex-reasoning-effort',
            'plan.completeness-critic-enabled', 'plan.consistency-critic-enabled',
            'plan.consistency-critic-dual-model', 'plan.contract-doc-enabled']
    for k in keys:
        print(f"{k} = {resolve(k)}")
elif arg == '--require':
    # 필수 키 검증 — 하나라도 빈 값이면 exit 1 (원격쓰기 전 fail-fast 게이트).
    # 토글(plan.*)은 fail-soft 기본값이 있으므로 require 대상에서 제외해도 됨(호출부가 명시).
    required = sys.argv[3:]
    missing = [k for k in required if not resolve(k).strip()]
    if missing:
        sys.stderr.write("❌ pipeline-config: 필수 config 키가 비어있음: "
                         + ", ".join(missing) + "\n")
        sys.stderr.write("   .claude/pipeline-config.yml 의 project/claude-commands 섹션을 확인하세요.\n")
        sys.exit(1)
else:
    sys.stdout.write(resolve(arg))
    sys.stdout.write('\n')
PYEOF
rc=$?
# python 비정상 종료 처리:
#   - --require 의 의도적 exit 1 은 그대로 전파(원격쓰기 게이트가 막아야 함)
#   - 그 외(파싱 크래시 등)는 fail-soft — 토글 기본 true, 나머지 빈 값
if [ "$rc" -ne 0 ] && [ "${1:-}" != "--require" ]; then
  echo "⚠️  pipeline-config: 파싱 실패(exit $rc) — fail-soft 처리" >&2
  case "${1:-}" in
    plan.*-enabled|plan.*-dual-model) printf 'true\n' ;;
    metrics.*-enabled) printf 'false\n' ;;  # 계측 토글 기본 OFF — opt-in
    janus.notify-enabled) printf 'false\n' ;;  # Janus 버튼 알림 토글 기본 OFF — opt-in
    *) printf '\n' ;;
  esac
  exit 0
fi
exit "$rc"
