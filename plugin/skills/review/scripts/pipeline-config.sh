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
#   area-id.<Name>                 claude-commands.area-ids.<Name> (예: area-id.Backend)
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
  sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'
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
    mq = re.search(rf'^\s+{re.escape(key)}:\s*"([^"\n]*)"\s*$', block, re.MULTILINE)
    if not mq:
        mq = re.search(rf"^\s+{re.escape(key)}:\s*'([^'\n]*)'\s*$", block, re.MULTILINE)
    if mq:
        return mq.group(1).strip()
    m = re.search(rf'^\s+{re.escape(key)}:\s*([^"#\n]*)', block, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m and m.group(1).strip() else default

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
    m = re.search(rf'^\s+{re.escape(name)}:\s*"?([^"#\n]+)"?\s*$', AREA_BLOCK, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m else ''

def resolve(key):
    # 파생 키
    if key == 'parent-repo-name':
        return parent_repo_name()
    if key == 'project-number':
        return project_number()
    if key.startswith('area-id.'):
        return area_id(key.split('.', 1)[1])
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

if arg == '--keys':
    print('\n'.join([
        'owner', 'parent-repository', 'parent-repo-name', 'project-number', 'slack-channel',
        'project-name', 'project-id', 'status-field-id', 'area-field-id',
        'author-login', 'local-account', 'docs-context-dir', 'area-id.<Name>',
        # review 전용 4키 (--keys 카탈로그엔 노출 / --dump 값요약엔 미노출)
        'reviewer-app-id', 'reviewer-bot-slug', 'reviewer-token-key', 'slack-token-key',
        'plan.completeness-critic-enabled', 'plan.consistency-critic-enabled',
        'plan.consistency-critic-dual-model', 'plan.contract-doc-enabled',
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
