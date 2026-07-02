#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# SC2016: SC-8 은 SKILL 소스에 리터럴 문자열이 있는지 검사하므로 단일따옴표(비확장)가 의도적이다.
# shellcheck disable=SC2016
# test-status-column-values.sh — #115 비-트리거 도착/경유 Status 컬럼 config 화 검증.
#
# 배경: #106 이 트리거 컬럼 2개(kickoff/review)를 config 화했지만 인접 도착/경유 컬럼
#   (In Review·Ready·Backlog·Done)은 SKILL 에 기본명 고정이었다. 특히 /review 7-h 는
#   `jq select(.name=="In Review")` 리터럴로 도착 컬럼 option id 를 조회해, 프로젝트가
#   In Review 를 리네임하면 id 가 빈 값→GraphQL mutation 실패→APPROVE 된 PR 카드가
#   사용자 검증 단계로 못 넘어가는 실제 버그가 있었다. #115 는 이를 project.status-columns.*
#   config + 리더 친화키 status-column-* 로 흡수한다(SKILL 전용 — App 폴러 미소비).
#
# 세 축:
#   (A) 리더(pipeline-config.sh 3벌)가 status-column-* 를 default·명시값·빈값·부재
#       폴백으로 읽고, 3벌 사본이 동일 결과를 내는지. 기본값은 현행 하드코딩(In Review/
#       Ready/Backlog/Done)과 100% 동일(이식 안전).
#   (B) 블록 격리 — status-columns 하위키(ready 등)와 modules[] 플래그가 겹칠 여지가
#       없음을 못박고, 커스텀 컬럼명 추출이 모듈 플래그로 오염되지 않는지.
#   (C) /review 7-h 회귀 — 도착 컬럼 조회가 리터럴이 아니라 config 값(jq --arg)을 쓰는지.
#       리네임된 컬럼에서 config 방식은 id 를 찾고 옛 리터럴 방식은 빈 값이 됨을 동시에
#       단언해 "리네임 시 APPROVE 전환 성공" 회귀를 실 동작으로 잡는다.

READER_KICKOFF="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
READER_PLAN="$REPO_ROOT/plugin/skills/plan/scripts/pipeline-config.sh"
READER_REVIEW="$REPO_ROOT/plugin/skills/review/scripts/pipeline-config.sh"
REVIEW_SKILL="$REPO_ROOT/plugin/skills/review/SKILL.md"

# status-column 친화키 → 기본 컬럼명 (현행 하드코딩과 동일해야 이식 안전)
_SC_KEYS=(status-column-in-review status-column-ready status-column-backlog status-column-done)
_SC_DEFAULTS=("In Review" "Ready" "Backlog" "Done")

# ── (A) 리더 default / 명시 / 빈값 / 부재 ────────────────────────────────

it "SC-1 status-column-* 미지정 시 기본 컬럼명 (kickoff·plan·review 동일)"
(
  # status-columns 블록이 아예 없는 config → 각 기본 컬럼명으로 폴백해야 함.
  cfg="$(mktemp)"
  printf 'project:\n  owner: acme\nclaude-commands:\n  project-name: X\n' > "$cfg"
  ok=1
  for reader in "$READER_KICKOFF" "$READER_PLAN" "$READER_REVIEW"; do
    for i in "${!_SC_KEYS[@]}"; do
      v="$(PIPELINE_CONFIG="$cfg" bash "$reader" "${_SC_KEYS[$i]}" 2>/dev/null)"
      assert_eq "${_SC_DEFAULTS[$i]}" "$v" "${_SC_KEYS[$i]} 기본값 아님 ($reader)" || ok=0
    done
  done
  rm -f "$cfg"
  [ "$ok" = 1 ] && pass
)

it "SC-2 config 파일 부재 시에도 기본 컬럼명 (fail-soft, kickoff·plan·review 동일)"
(
  ok=1
  for reader in "$READER_KICKOFF" "$READER_PLAN" "$READER_REVIEW"; do
    for i in "${!_SC_KEYS[@]}"; do
      v="$(PIPELINE_CONFIG="/nonexistent-$$.yml" bash "$reader" "${_SC_KEYS[$i]}" 2>/dev/null)"
      assert_eq "${_SC_DEFAULTS[$i]}" "$v" "${_SC_KEYS[$i]} 부재 폴백 실패 ($reader)" || ok=0
    done
  done
  [ "$ok" = 1 ] && pass
)

# 커스텀 status-columns + modules[] 플래그 공존 (경계 누출 자극용).
# status-columns 를 modules: 바로 위(마지막 project 키)에 둬 블록 경계가 새면
# modules 의 kickoff/review(true/false)·default-status(Ready) 를 컬럼명으로 오독하게 유도.
_make_custom_config() {
  local f; f="$(mktemp)"
  cat > "$f" <<'YAML'
project:
  owner: acme
  parent-repository: acme/Repo
  project-numbers: [3]
  status-columns:
    in-review: "검증대기"
    ready: "준비"
    backlog: "적재"
    done: "완료"
modules:
  - name: Backend
    kickoff: true
    review: false
    default-status: Ready
  - name: iOS
    kickoff: false
    review: true
YAML
  echo "$f"
}

it "SC-3 커스텀 status-columns 값을 정확히 읽음 (kickoff·plan·review 동일)"
(
  cfg="$(_make_custom_config)"
  ok=1
  declare -a want=("검증대기" "준비" "적재" "완료")
  for reader in "$READER_KICKOFF" "$READER_PLAN" "$READER_REVIEW"; do
    for i in "${!_SC_KEYS[@]}"; do
      v="$(PIPELINE_CONFIG="$cfg" bash "$reader" "${_SC_KEYS[$i]}" 2>/dev/null)"
      assert_eq "${want[$i]}" "$v" "${_SC_KEYS[$i]} 커스텀값 미반영 ($reader)" || ok=0
    done
  done
  rm -f "$cfg"
  [ "$ok" = 1 ] && pass
)

it "SC-4 블록 격리 — status-columns 하위키가 modules[] 플래그를 오독하지 않음"
(
  # 커스텀 config 는 modules[].kickoff/review(true/false)·default-status(Ready) 를 갖는다.
  # status-column-ready 가 modules 의 default-status:Ready 나 플래그를 빨아들이면 오독.
  cfg="$(_make_custom_config)"
  ok=1
  # status-column-* 는 project.status-columns 값(준비 등)만 나와야 함
  r="$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" status-column-ready 2>/dev/null)"
  assert_eq "준비" "$r" "status-column-ready 가 modules default-status/플래그 오독" || ok=0
  assert_ne "Ready" "$r" "status-column-ready 가 modules default-status(Ready) 를 흡수" || ok=0
  assert_ne "true"  "$r" "status-column-ready 가 모듈 플래그(true) 흡수" || ok=0
  # 역방향: 모듈 플래그는 여전히 정확해야(컬럼 파싱이 모듈 블록을 깨지 않음)
  assert_eq "true"  "$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" module.Backend.kickoff 2>/dev/null)" "module.Backend.kickoff 손상" || ok=0
  assert_eq "false" "$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" module.Backend.review 2>/dev/null)" "module.Backend.review 손상" || ok=0
  assert_eq "Ready" "$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" module.Backend.default-status 2>/dev/null)" "module.Backend.default-status 손상" || ok=0
  rm -f "$cfg"
  [ "$ok" = 1 ] && pass
)

it "SC-5 status-columns 빈값('')도 기본 컬럼명으로 폴백(항상 비지 않음)"
(
  cfg="$(mktemp)"
  printf 'project:\n  owner: acme\n  status-columns:\n    in-review: ""\n    ready: ""\n    backlog: ""\n    done: ""\n' > "$cfg"
  ok=1
  for i in "${!_SC_KEYS[@]}"; do
    v="$(PIPELINE_CONFIG="$cfg" bash "$READER_KICKOFF" "${_SC_KEYS[$i]}" 2>/dev/null)"
    assert_eq "${_SC_DEFAULTS[$i]}" "$v" "${_SC_KEYS[$i]} 빈값이 기본으로 폴백 안 됨" || ok=0
  done
  rm -f "$cfg"
  [ "$ok" = 1 ] && pass
)

it "SC-6 status-columns 부분 지정 — 지정 키는 값, 미지정 키는 기본 폴백"
(
  # in-review 만 리네임, 나머지는 생략 → in-review 는 커스텀, 나머지는 기본.
  cfg="$(mktemp)"
  printf 'project:\n  owner: acme\n  status-columns:\n    in-review: "검증대기"\n' > "$cfg"
  assert_eq "검증대기" "$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" status-column-in-review 2>/dev/null)" "지정 키 값 미반영" || { rm -f "$cfg"; return; }
  assert_eq "Ready"    "$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" status-column-ready 2>/dev/null)"     "미지정 키 기본 폴백 실패" || { rm -f "$cfg"; return; }
  assert_eq "Done"     "$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" status-column-done 2>/dev/null)"      "미지정 키 기본 폴백 실패" || { rm -f "$cfg"; return; }
  rm -f "$cfg"; pass
)

it "SC-7 reclip 예시 config 는 status-columns 미지정 → 전부 기본값(이식 안전 회귀)"
(
  # 실제 배포 예시가 status-columns 없이도 현행 컬럼명 그대로 동작함을 못박는다.
  ex="$REPO_ROOT/examples/reclip/pipeline-config.yml"
  ok=1
  for i in "${!_SC_KEYS[@]}"; do
    v="$(PIPELINE_CONFIG="$ex" bash "$READER_KICKOFF" "${_SC_KEYS[$i]}" 2>/dev/null)"
    assert_eq "${_SC_DEFAULTS[$i]}" "$v" "reclip 예시에서 ${_SC_KEYS[$i]} 기본값 아님" || ok=0
  done
  [ "$ok" = 1 ] && pass
)

# ── (C) /review 7-h 도착 컬럼 조회 회귀 (실제 버그) ──────────────────────

it "SC-8 7-h 도착 컬럼 조회가 리터럴이 아니라 config(jq --arg)로 배선됨"
(
  # SKILL 코드가 (a) IN_REVIEW 를 config 리더로 받고 (b) jq --arg col 로 주입하며
  # (c) 옛 리터럴 select(.name=="In Review") 를 더는 쓰지 않는지 — 소스 회귀 가드.
  body="$(cat "$REVIEW_SKILL")"
  assert_contains "$body" 'IN_REVIEW="$(bash "$CFG" status-column-in-review)"' "IN_REVIEW 가 config 리더에서 안 옴" || return
  assert_contains "$body" '--arg col "$IN_REVIEW"' "jq 에 config 값 주입(--arg col) 없음" || return
  assert_contains "$body" 'select(.name==$col)' "jq 가 config 컬럼명으로 매칭 안 함" || return
  assert_not_contains "$body" 'select(.name=="In Review")' "옛 리터럴 In Review 조회가 남아있음(회귀)" && pass
)

it "SC-9 리네임된 도착 컬럼: config 방식은 id 조회 성공, 옛 리터럴 방식은 실패(버그 재현)"
(
  # gh project field-list JSON 을 흉내 — Status 옵션이 '검증대기' 로 리네임된 상태.
  fieldjson='{"fields":[{"name":"Status","options":[
    {"id":"opt-ip","name":"In Progress"},
    {"id":"opt-br","name":"Bot Review"},
    {"id":"opt-ir-renamed","name":"검증대기"},
    {"id":"opt-done","name":"Done"}
  ]}]}'
  # (a) config 방식 — IN_REVIEW=리네임값 을 --arg 로 주입 → 정확한 id 조회
  IN_REVIEW="검증대기"
  got=$(printf '%s' "$fieldjson" \
    | jq -r --arg col "$IN_REVIEW" '.fields[] | select(.name=="Status") | .options[] | select(.name==$col) | .id')
  assert_eq "opt-ir-renamed" "$got" "config(jq --arg) 방식이 리네임 컬럼 id 를 못 찾음" || return
  # (b) 옛 리터럴 방식 — select(.name=="In Review") → 빈 값(이게 버그였다)
  old=$(printf '%s' "$fieldjson" \
    | jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="In Review") | .id')
  assert_eq "" "$old" "옛 리터럴 방식이 리네임 후에도 값을 냄(버그 재현 실패 — 테스트 무의미)" && pass
)

it "SC-10 기본 컬럼명(In Review) 프로젝트: config 폴백값으로도 id 조회 성공(하위호환)"
(
  # status-columns 미지정 프로젝트는 리더가 'In Review' 를 폴백으로 낸다 → 여전히 조회돼야.
  fieldjson='{"fields":[{"name":"Status","options":[
    {"id":"opt-ir","name":"In Review"},
    {"id":"opt-done","name":"Done"}
  ]}]}'
  cfg="$(mktemp)"; printf 'project:\n  owner: acme\n' > "$cfg"
  IN_REVIEW="$(PIPELINE_CONFIG="$cfg" bash "$READER_REVIEW" status-column-in-review 2>/dev/null)"
  assert_eq "In Review" "$IN_REVIEW" "부재 config 에서 In Review 폴백 실패" || { rm -f "$cfg"; return; }
  got=$(printf '%s' "$fieldjson" \
    | jq -r --arg col "$IN_REVIEW" '.fields[] | select(.name=="Status") | .options[] | select(.name==$col) | .id')
  assert_eq "opt-ir" "$got" "기본 컬럼명 프로젝트에서 도착 컬럼 id 조회 실패(하위호환 깨짐)" || { rm -f "$cfg"; return; }
  rm -f "$cfg"; pass
)
