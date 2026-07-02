#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# test-config-trigger-values.sh — #106 트리거 기준값 하드코딩 제거 검증.
#
# 두 축:
#   (A) app-p5: install.sh parse_config 가 project.status-triggers.{kickoff,review} 를
#       App 폴러 env(STATUS_TRIGGERS_KICKOFF/REVIEW)로 정확히 뽑는지.
#       핵심 함정 — status-triggers 의 하위키 kickoff/review 가 modules[].kickoff/review
#       플래그와 이름이 겹친다. 블록 격리가 깨지면 module 플래그(true/false)를 컬럼명으로
#       오독한다. 그래서 "status-triggers 를 modules: 바로 위(마지막 project 키)"에 둔
#       fixture 로 그 경계 누출을 적극적으로 자극한다.
#   (B) M12: 런타임 리더(pipeline-config.sh)가 base-branch 를 default develop·명시값·
#       빈값 폴백으로 읽고, plan↔kickoff 사본이 동일 결과를 내는지.

READER_KICKOFF="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
READER_PLAN="$REPO_ROOT/plugin/skills/plan/scripts/pipeline-config.sh"
# review 사본도 base-branch 회귀 매트릭스에 포함 — SP-3 가 kickoff↔review 바이트 동일을
# 보장하지만, 3벌 중복이라 review 사본만 드리프트해도 동작 기준으로 잡히게 명시 검증한다.
READER_REVIEW="$REPO_ROOT/plugin/skills/review/scripts/pipeline-config.sh"

# ── (A) status-triggers → STATUS_TRIGGERS_* env ─────────────────────────

# 커스텀 컬럼명 + status-triggers 를 modules: 바로 위에 배치(경계 누출 자극).
# modules 의 kickoff/review 플래그(true/false)가 새면 컬럼명으로 오독된다.
_make_custom_config() {
  local f; f="$(mktemp)"
  cat > "$f" <<'YAML'
project:
  owner: acme
  parent-repository: acme/Repo
  project-numbers: [3]
  status-triggers:
    kickoff: "작업중"
    review: "리뷰대기"
modules:
  - name: Backend
    kickoff: true
    review: false
  - name: iOS
    kickoff: false
    review: true
modules-ignore:
  - Design
YAML
  echo "$f"
}

it "T-ST-1 status-triggers 커스텀 컬럼명을 STATUS_TRIGGERS_* 로 정확히 추출(모듈 kickoff/review 플래그 누출 없음)"
(
  cfg="$(_make_custom_config)"
  setup_install_env "$cfg"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "작업중"   "$STATUS_TRIGGERS_KICKOFF" "kickoff 컬럼명 오독(모듈 플래그 누출?)" || { rm -f "$cfg"; return; }
  assert_eq "리뷰대기" "$STATUS_TRIGGERS_REVIEW"  "review 컬럼명 오독(모듈 플래그 누출?)"  || { rm -f "$cfg"; return; }
  # 모듈 플래그(true/false)가 절대 새지 않았는지 못박기
  assert_ne "true"  "$STATUS_TRIGGERS_KICKOFF" "모듈 kickoff=true 가 컬럼명으로 샘" || { rm -f "$cfg"; return; }
  assert_ne "false" "$STATUS_TRIGGERS_KICKOFF" "모듈 kickoff=false 가 컬럼명으로 샘" || { rm -f "$cfg"; return; }
  rm -f "$cfg"; pass
)

it "T-ST-2 status-triggers 미지정 시 STATUS_TRIGGERS_* 빈 값(App 기본값 폴백 위임)"
(
  # reclip 예시엔 status-triggers 가 없다 — 빈 값이어야 App(lib/env.ts)이 기본 컬럼명 폴백.
  setup_install_env "$REPO_ROOT/examples/reclip/pipeline-config.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "" "$STATUS_TRIGGERS_KICKOFF" "미지정인데 빈 값 아님" || return
  assert_eq "" "$STATUS_TRIGGERS_REVIEW"  "미지정인데 빈 값 아님" && pass
)

it "T-ST-3 generate_env 가 STATUS_TRIGGERS_* 를 .env 에 기록"
(
  cfg="$(_make_custom_config)"
  setup_install_env "$cfg"
  eval "$(parse_config 2>/dev/null)"
  # generate_env 는 인증값 등 다른 전역도 참조하므로 최소값만 채워 실행.
  AUTHOR_APP_ID=1; AUTHOR_PEM_PATH=/x.pem; AUTHOR_INSTALLATION_ID=2
  REVIEWER_ENABLED=false; WEBHOOK_SECRET=s; PORT_VALUE=3000
  ENV_FILE="$(mktemp)"
  generate_env >/dev/null 2>&1
  env_out="$(cat "$ENV_FILE")"
  assert_contains "$env_out" "STATUS_TRIGGERS_KICKOFF=작업중"  "kickoff 컬럼명 .env 누락" || { rm -f "$cfg" "$ENV_FILE"; return; }
  assert_contains "$env_out" "STATUS_TRIGGERS_REVIEW=리뷰대기" "review 컬럼명 .env 누락"  || { rm -f "$cfg" "$ENV_FILE"; return; }
  rm -f "$cfg" "$ENV_FILE"; pass
)

# ── (B) base-branch 리더 (M12) ──────────────────────────────────────────

# base-branch 없는 config → 기본 develop
_make_no_base_config() {
  local f; f="$(mktemp)"
  printf 'project:\n  owner: acme\nclaude-commands:\n  project-name: X\n' > "$f"
  echo "$f"
}

it "T-BB-1 base-branch 미지정 시 기본 develop (plan·kickoff·review 동일)"
(
  cfg="$(_make_no_base_config)"
  k="$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" base-branch 2>/dev/null)"
  p="$(PIPELINE_CONFIG="$cfg" bash "$READER_PLAN" base-branch 2>/dev/null)"
  r="$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" base-branch 2>/dev/null)"
  assert_eq "develop" "$k" "kickoff base-branch 기본값 아님" || { rm -f "$cfg"; return; }
  assert_eq "develop" "$p" "plan base-branch 기본값 아님"    || { rm -f "$cfg"; return; }
  assert_eq "develop" "$r" "review base-branch 기본값 아님"  || { rm -f "$cfg"; return; }
  rm -f "$cfg"; pass
)

it "T-BB-2 base-branch 명시값(main)을 그대로 읽음 (plan·kickoff·review 동일)"
(
  cfg="$(mktemp)"
  printf 'project:\n  owner: acme\nclaude-commands:\n  base-branch: main\n' > "$cfg"
  k="$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" base-branch 2>/dev/null)"
  p="$(PIPELINE_CONFIG="$cfg" bash "$READER_PLAN" base-branch 2>/dev/null)"
  r="$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" base-branch 2>/dev/null)"
  assert_eq "main" "$k" "kickoff 명시값 미반영" || { rm -f "$cfg"; return; }
  assert_eq "main" "$p" "plan 명시값 미반영"    || { rm -f "$cfg"; return; }
  assert_eq "main" "$r" "review 명시값 미반영"  || { rm -f "$cfg"; return; }
  rm -f "$cfg"; pass
)

it "T-BB-3 base-branch 빈값('')도 develop 로 폴백(항상 비지 않음, kickoff·review)"
(
  cfg="$(mktemp)"
  printf 'project:\n  owner: acme\nclaude-commands:\n  base-branch: ""\n' > "$cfg"
  k="$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" base-branch 2>/dev/null)"
  r="$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" base-branch 2>/dev/null)"
  assert_eq "develop" "$k" "kickoff 빈값이 develop 로 폴백 안 됨" || { rm -f "$cfg"; return; }
  assert_eq "develop" "$r" "review 빈값이 develop 로 폴백 안 됨"  || { rm -f "$cfg"; return; }
  rm -f "$cfg"; pass
)

it "T-BB-4 config 파일 부재 시에도 base-branch 는 develop (fail-soft, kickoff·review)"
(
  k="$(PIPELINE_CONFIG=/nonexistent-$$.yml bash "$READER_KICKOFF" base-branch 2>/dev/null)"
  r="$(PIPELINE_CONFIG=/nonexistent-$$.yml bash "$READER_REVIEW" base-branch 2>/dev/null)"
  assert_eq "develop" "$k" "kickoff config 부재 폴백 실패" || return
  assert_eq "develop" "$r" "review config 부재 폴백 실패" && pass
)
