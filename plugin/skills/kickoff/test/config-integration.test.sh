#!/usr/bin/env bash
# config-integration.test.sh — kickoff SKILL.md ↔ 동봉 리더 통합 불변식 (비원격).
#
# 목적:
#   kickoff SKILL.md 가 런타임에 읽는 모든 config 키가 동봉 리더
#   (scripts/pipeline-config.sh)에서 실제로 지원되는지 검증한다.
#   오타·미지원 키(예: area-id.IOS 처럼 대소문자가 틀린 키)를 라이브 실행 전에
#   조기 검출하는 통합 게이트. area-id.* 6종을 명시적으로 포함시켜 검증한다.
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

# ── area-id.* 6종 명시 검증 (대소문자 정확 — 픽스처 값 비면 안 됨) ────
for area in Backend Admin Frontend iOS Android Design; do
  key="area-id.$area"
  # SKILL.md 가 실제로 이 키를 참조하는지
  if grep -qF -- "bash \"\$CFG\" $key" "$SKILL"; then
    ok "SKILL.md 가 $key 참조"
  else
    bad "SKILL.md 가 $key 를 참조하지 않음 (Area ID 참조표 누락 의심)"
  fi
  # 리더가 픽스처에서 비지 않은 값을 돌려주는지 (대소문자 정확성 검증)
  val="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" "$key" 2>/dev/null)"
  if [ -n "$val" ]; then
    ok "$key 픽스처 값 존재: $val"
  else
    bad "$key 픽스처 값이 빈 값 (대소문자 불일치 의심 — area-id.iOS 등 정확히)"
  fi
done

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
