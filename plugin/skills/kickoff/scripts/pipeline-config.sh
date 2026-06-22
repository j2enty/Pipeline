#!/usr/bin/env bash
# pipeline-config.sh — /pipeline:review 런타임 config 리더.
#
# 슬래시커맨드가 "설치시 placeholder 치환" 대신 "실행시 config 읽기"로 전환하기 위한
# 도구. SKILL.md 의 코드펜스가 프로젝트값(owner·project-id·리뷰어봇·토큰키 등)을 이
# 스크립트로 실행시 읽어 주입한다. 값 추출 규칙은 본체 scripts/install.sh 의
# parse_config() 와 동일하게 맞춰, 런타임 값이 install.sh 가 치환했을 값과
# 일치(parity)하도록 했다.
#
# 주: 이 파일은 plan skill 의 동명 리더 복사본에 review 전용 4키(reviewer-app-id·
# reviewer-bot-slug·reviewer-token-key·slack-token-key)를 추가한 버전이다.
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
#   area-id.<Name>                 modules[Name].area-id 우선 → legacy claude-commands.area-ids.<Name> 폴백
#   module.<Name>.<flag>           modules[Name].<flag> (flag: role·ci-workflow-name·area-id·
#                                  planner·review·kickoff·lead·default-status·cross-area-group)
#   --list-modules                 모듈명을 정의순으로 1줄씩
#   --modules-where <flag>=<val>   조건 매칭 모듈명 1줄씩(정의순). 예: --modules-where lead=true
#   --modules-table                TSV 표(헤더행 포함): name⇥role⇥planner⇥review⇥kickoff⇥lead⇥
#                                  default-status⇥cross-area-group⇥area-id⇥ci-workflow-name
#   reviewer-app-id                claude-commands.reviewer-app-id     (review 전용·민감)
#   reviewer-bot-slug              claude-commands.reviewer-bot-slug   (review 전용·민감)
#   reviewer-token-key             claude-commands.reviewer-token-key  (review 전용·민감)
#   slack-token-key                claude-commands.slack-token-key     (review 전용·민감)
#   plan.completeness-critic-enabled       claude-commands.plan.* (기본 true)
#   plan.consistency-critic-enabled        (기본 true)
#   plan.consistency-critic-dual-model     (기본 true)
#   plan.contract-doc-enabled              (기본 true)
#
# fail-soft: config 부재·키 부재 시 빈 값(토글은 기본 true) + stderr 경고, exit 0.
#   (dry-run/플랜 흐름이 config 없다고 중단되지 않도록 — 호출부가 빈 값 처리.)
#
# 보안 결정: review 전용 4키(reviewer-app-id·reviewer-bot-slug·reviewer-token-key·
#   slack-token-key)는 --dump(LLM 컨텍스트 요약)에 노출하지 않는다. App ID·bot-slug·
#   토큰키(env 변수 이름표) 같은 식별성 높은 값을 통째로 LLM 컨텍스트에 흘리지 않기 위함.
#   개별 키 읽기(`pipeline-config.sh reviewer-token-key`)로만 접근. 부재 시 빈 값(fail-soft).

set -uo pipefail

CONFIG_PATH="${PIPELINE_CONFIG:-.claude/pipeline-config.yml}"

usage() {
  sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'
}

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
    --keys|--dump) : ;;
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
#   "..."  → 그룹1(닫는 따옴표까지, # 포함)
#   '...'  → 그룹2(동일)
#   무따옴표 → 그룹3([^"#\n]+? 비탐욕, # 이후는 인라인 주석으로 폴백)
# 줄끝 선택적 인라인 주석((?:#.*)?$)은 호출부 패턴이 붙인다. pick_quoted_value() 로 그룹 선택.
QUOTED_VALUE = r'''(?:"([^"\n]+)"|'([^'\n]+)'|([^"#\n]+?))'''

def pick_quoted_value(m):
    """QUOTED_VALUE 3분기 중 매칭된 그룹 값을 strip 해 반환(없으면 '')."""
    v = m.group(1) if m.group(1) is not None else (
        m.group(2) if m.group(2) is not None else m.group(3))
    return v.strip() if v is not None else ''

PROJECT = section(content, 'project')
CC = section(content, 'claude-commands')

# claude-commands.plan 서브블록 (install.sh 와 동일 앵커: 들여쓰기 \1 캡처)
plan_m = re.search(r'^([ \t]+)plan:\s*\n(.*?)(?=^\1\S|\Z)', CC, re.MULTILINE | re.DOTALL)
PLAN_BLOCK = plan_m.group(2) if plan_m else ''

# claude-commands.area-ids 서브블록
ai = re.search(r'^([ \t]+)area-ids:[ \t]*\n((?:\1[ \t]+\S.*\n?|[ \t]*\n)*)', CC, re.MULTILINE)
AREA_BLOCK = ai.group(2) if ai else ''

def plan_bool(key, default='true'):
    """true/false 만 인정(따옴표 허용). 오타·누락 → default. install.sh get_plan_bool 동일."""
    m = re.search(r'^[ \t]+' + re.escape(key) + r':\s*["\']?(true|false)["\']?\s*(?:#.*)?$',
                  PLAN_BLOCK, re.MULTILINE | re.IGNORECASE)
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

def module_blocks():
    """[(name, block), ...] 를 정의(나열)순으로 반환."""
    # 따옴표 분기 우선(따옴표 안 # 보존, #57) → 무따옴표 폴백(인라인 주석 제거, #52).
    # 무따옴표 모듈명에 # 가 오면 주석 경계로 본다(값 밖 # 만 주석). 따옴표로 감싸면 보존.
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
    # project 섹션 스칼라
    if key in ('owner', 'parent-repository', 'slack-channel'):
        return get_scalar_in(PROJECT, key)
    # claude-commands 섹션 스칼라
    # (review 전용 4키 reviewer-app-id·reviewer-bot-slug·reviewer-token-key·
    #  slack-token-key 포함 — install.sh parse_config() 와 동일하게 claude-commands
    #  블록 내부 스칼라로 읽음. --dump 에는 노출 안 함, 개별 키 읽기로만 접근.)
    if key in ('project-name', 'project-id', 'status-field-id', 'area-field-id',
               'author-login', 'local-account', 'docs-context-dir',
               'reviewer-app-id', 'reviewer-bot-slug', 'reviewer-token-key',
               'slack-token-key'):
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
        'author-login', 'local-account', 'docs-context-dir', 'area-id.<Name>',
        # review 전용 4키 (--keys 카탈로그엔 노출 / --dump 값요약엔 미노출)
        'reviewer-app-id', 'reviewer-bot-slug', 'reviewer-token-key', 'slack-token-key',
        'plan.completeness-critic-enabled', 'plan.consistency-critic-enabled',
        'plan.consistency-critic-dual-model', 'plan.contract-doc-enabled',
        # modules 인터페이스 — 모듈 동작 의미론(planner/review/kickoff/lead 등)
        '--list-modules', 'module.<Name>.<flag>', '--modules-where <flag>=<val>', '--modules-table',
    ]))
elif arg == '--dump':
    # 보안: review 전용 4키(reviewer-app-id·reviewer-bot-slug·reviewer-token-key·
    # slack-token-key)는 의도적으로 dump 목록에서 제외(LLM 컨텍스트 노출 방지).
    keys = ['owner', 'parent-repository', 'parent-repo-name', 'project-number', 'slack-channel',
            'project-name', 'project-id', 'status-field-id', 'area-field-id',
            'author-login', 'local-account', 'docs-context-dir',
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
    *) printf '\n' ;;
  esac
  exit 0
fi
exit "$rc"
