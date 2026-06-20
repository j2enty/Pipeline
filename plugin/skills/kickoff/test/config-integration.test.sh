#!/usr/bin/env bash
# config-integration.test.sh — kickoff SKILL.md ↔ 동봉 리더 통합 불변식 (비원격).
#
# 목적:
#   kickoff SKILL.md 가 런타임에 읽는 모든 config 키가 동봉 리더
#   (scripts/pipeline-config.sh)에서 실제로 지원되는지 검증한다.
#   오타·미지원 키(예: module.IOS 처럼 대소문자가 틀린 키)를 라이브 실행 전에
#   조기 검출하는 통합 게이트. #42: 모듈 동작은 area-id.* 개별호출 대신 리더
#   인터페이스(--modules-table/--modules-where/module.<name>.<flag>)로 읽으므로,
#   그 인터페이스가 픽스처에서 동작(빈 출력 아님)하는지 검증한다.
#
# 검출 원리:
#   리더는 config 파일이 존재할 때 미지원 키 호출 시 stderr 에 "알 수 없는 키"
#   경고를 낸다(단 area-id.<Name> 은 어떤 Name 이든 지원하므로 경고 없음).
#   픽스처 config 를 주입(PIPELINE_CONFIG)한 뒤 SKILL.md 가 참조하는 키마다 리더를
#   돌려 그 경고가 안 나오는지 단언한다. area-id.* 는 추가로 픽스처 값이 비지 않는지
#   (대소문자 정확) 단언한다.
#
# 종료 코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$DIR/../SKILL.md"
READER="$DIR/../scripts/pipeline-config.sh"
FIXTURE="$DIR/fixtures/full.yml"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '✗ %s\n' "$1"; }

# ── 전제 파일 존재 ───────────────────────────────────────────────────
for f in "$SKILL" "$READER" "$FIXTURE"; do
  [ -f "$f" ] || { bad "전제 파일 없음: $f"; echo "통과 $PASS · 실패 $FAIL"; exit 1; }
done

# ── SKILL.md 가 참조하는 키 수집 ─────────────────────────────────────
# (bash 3.2 호환 — mapfile 미사용. 개행 구분 문자열로 모은 뒤 for 로 순회)
# (a) 개별 읽기:  bash "$CFG" <key>   (area-id.<Name> 의 대문자 Name 도 포함되도록 [A-Za-z.-])
direct_keys="$(grep -oE 'bash "\$CFG" [a-z][A-Za-z.-]+' "$SKILL" \
  | sed -E 's/^bash "\$CFG" //' | sort -u)"

# (b) --require <key>...  (한 줄에 여러 키)
require_keys="$(grep -oE '\-\-require [a-z][a-z .-]+' "$SKILL" \
  | sed -E 's/^--require //' | tr ' ' '\n' | grep -E '^[a-z]' | sort -u)"

ALL_KEYS="$(printf '%s\n%s\n' "$direct_keys" "$require_keys" | grep -E '^[a-z]' | sort -u)"

# 최소 1개는 수집됐어야 — 0이면 추출 정규식이 깨진 것
if [ -z "$ALL_KEYS" ]; then
  bad "SKILL.md 에서 config 키 참조를 하나도 못 찾음 (추출 정규식 점검)"
  echo "통과 $PASS · 실패 $FAIL"; exit 1
else
  ok "SKILL.md config 키 참조 $(printf '%s\n' "$ALL_KEYS" | grep -c .)종 수집"
fi

# ── 각 키가 리더에서 지원되는지 (미지원 키 경고 부재) ────────────────
for key in $ALL_KEYS; do
  warn="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" "$key" 2>&1 >/dev/null)"
  if printf '%s' "$warn" | grep -q "알 수 없는 키"; then
    bad "리더 미지원 키: '$key' (SKILL.md 가 읽지만 pipeline-config.sh 가 모름)"
  else
    ok "리더 지원: $key"
  fi
done

# ── 모듈 동작표 인터페이스 검증 (#42 — 모듈명 비종속) ────────────────
# SKILL.md 가 area-id 6종 개별호출 대신 리더 모듈 인터페이스를 쓰는지 +
# 그 인터페이스가 픽스처에서 실제로 동작하는지(빈 출력 아님) 검증.

# (1) SKILL.md 가 --modules-table 를 1회 읽는지
if grep -qF -- '"$CFG" --modules-table' "$SKILL"; then
  ok "SKILL.md 가 --modules-table 참조(모듈표 1회 읽기)"
else
  bad "SKILL.md 가 --modules-table 를 참조하지 않음 (모듈 동작표 주입 누락)"
fi

# (2) SKILL.md 가 lead/kickoff 분기를 --modules-where 로 하는지
if grep -qE -- '--modules-where (lead|kickoff)' "$SKILL"; then
  ok "SKILL.md 가 --modules-where lead/kickoff 분기"
else
  bad "SKILL.md 가 --modules-where lead/kickoff 분기를 안 함"
fi

# (3) 리더 모듈 인터페이스가 픽스처에서 실제 동작 — 빈 출력이면 안 됨
table_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-table 2>/dev/null)"
if printf '%s\n' "$table_out" | head -1 | grep -q $'name\trole'; then
  ok "리더 --modules-table 헤더행 출력"
else
  bad "리더 --modules-table 헤더행 없음"
fi
lead_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where lead=true 2>/dev/null)"
if [ -n "$lead_out" ]; then
  ok "리더 --modules-where lead=true 매칭 존재: $lead_out"
else
  bad "리더 --modules-where lead=true 결과 빈 값 (lead 모듈 픽스처 누락)"
fi
kf_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where kickoff=false 2>/dev/null)"
if [ -n "$kf_out" ]; then
  ok "리더 --modules-where kickoff=false 매칭 존재: $kf_out"
else
  bad "리더 --modules-where kickoff=false 결과 빈 값 (제외 모듈 픽스처 누락)"
fi

# (4) area-id 는 module.<name>.area-id 로 — 대소문자 정확성(표의 name 그대로) 검증
first_mod="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --list-modules 2>/dev/null | head -1)"
if [ -n "$first_mod" ]; then
  aid="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" "module.$first_mod.area-id" 2>/dev/null)"
  if [ -n "$aid" ]; then
    ok "module.$first_mod.area-id 픽스처 값 존재: $aid"
  else
    bad "module.$first_mod.area-id 빈 값 (area-id 컬럼 누락)"
  fi
  # 대소문자 함정 — 잘못된 케이스는 빈 값이어야
  upper="$(printf '%s' "$first_mod" | tr '[:lower:]' '[:upper:]')"
  if [ "$upper" != "$first_mod" ]; then
    miss="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" "module.$upper.area-id" 2>/dev/null)"
    if [ -z "$miss" ]; then ok "대소문자 구분: module.$upper.area-id 빈 값"; else bad "대소문자 구분 실패: module.$upper.area-id=$miss"; fi
  fi
else
  bad "리더 --list-modules 가 빈 출력 (modules 블록 누락)"
fi

# ── --require 게이트 키는 픽스처에서 비어있지 않아야 (해당 시) ──────────
for key in $require_keys; do
  [ -z "$key" ] && continue
  val="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" "$key" 2>/dev/null)"
  if [ -n "$val" ]; then
    ok "--require 키 픽스처 값 존재: $key"
  else
    bad "--require 키 '$key' 가 픽스처에서 빈 값 (게이트 검증 불가)"
  fi
done

echo
echo "── 결과 ──"
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ] && { echo "전부 통과"; exit 0; } || { echo "실패 있음"; exit 1; }
