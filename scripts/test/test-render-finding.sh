#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# render-finding.py 단위테스트 (#104 M9).
#   track-findings/action.yml 의 python heredoc 에서 추출한 finding 렌더 로직을
#   순수 함수로 고정한다. 검증 축: fingerprint 결정성·area 구분(#1)·description
#   시그니처로 finding 소실 방지(#4)·이모지/구두점 title 의 sha 폴백·title fp suffix 보존.
#   dedup 트레이드오프는 미묘해서 회귀 그물 없이 한 줄만 바꿔도 finding 소실/이슈 폭주가 난다.

RENDER_PY="$REPO_ROOT/scripts/render-finding.py"

# render <source> <area> <finding-json> → stdout: 'fp\t제목\t라벨\t본문(base64)'
# MAJOR/MINOR 라벨은 고정값으로 주입(라벨 매핑도 함께 검증).
render() {
  local source="$1" area="$2" json="$3"
  FINDING_SOURCE="$source" AREA="$area" \
  MAJOR_LABEL="MAJ" MINOR_LABEL="MIN" \
  python3 "$RENDER_PY" "$json"
}

# TSV 필드 추출 헬퍼 (탭 구분).
fp_of()    { printf '%s' "$1" | cut -f1; }
title_of() { printf '%s' "$1" | cut -f2; }
label_of() { printf '%s' "$1" | cut -f3; }
body_of()  { printf '%s' "$1" | cut -f4 | base64 --decode; }

# RF-1 — code-review finding 의 출력 형태(4필드·fp 12hex·title fp suffix·라벨 매핑)
it "RF-1 code-review 렌더 형태·fp·라벨"
(
  out="$(render code-review Backend '{"severity":"major","file":"a.ts","line":3,"title":"bug here","description":"d","suggestion":"s"}')"
  fp="$(fp_of "$out")"
  # fp 는 12자리 hex
  case "$fp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "fp 가 12자리 hex 아님: '$fp'"; exit 0 ;;
  esac
  assert_contains "$(title_of "$out")" "[fp:$fp]" "title 에 fp suffix 누락" || exit 0
  assert_contains "$(title_of "$out")" "[major] bug here" "title base 불일치" || exit 0
  assert_eq "MAJ" "$(label_of "$out")" "major→MAJOR_LABEL 매핑" || exit 0
  # 본문에 severity·위치·설명·제안·fp 마커가 들어있어야 한다.
  b="$(body_of "$out")"
  assert_contains "$b" "**위치**: a.ts:3" "위치 렌더 누락" || exit 0
  assert_contains "$b" "finding-fp: $fp" "본문 fp 마커 누락" || exit 0
  pass
)

# RF-2 — minor severity 는 MINOR_LABEL 로 매핑된다
it "RF-2 minor→MINOR_LABEL 매핑"
(
  out="$(render code-review Backend '{"severity":"minor","file":"a.ts","title":"t","description":"d"}')"
  assert_eq "MIN" "$(label_of "$out")" "minor→MINOR_LABEL 매핑" || exit 0
  pass
)

# RF-3 — 결정성: 같은 입력은 항상 같은 fp (LLM 비결정 요소 배제)
it "RF-3 같은 입력 → 같은 fp (결정성)"
(
  j='{"severity":"major","file":"a.ts","line":9,"title":"같은 버그","description":"desc"}'
  fp1="$(fp_of "$(render code-review Backend "$j")")"
  fp2="$(fp_of "$(render code-review Backend "$j")")"
  assert_eq "$fp1" "$fp2" "결정성 위반 — 같은 입력에 다른 fp" || exit 0
  pass
)

# RF-4 — area 구분(버그 #1): critic 모드에서 같은 severity+title 이라도
#        finding.area 가 다르면 fp 가 달라야 한다(안 그러면 두 번째가 dedup 으로 소실).
it "RF-4 critic — area 다르면 fp 다름(#1)"
(
  fa="$(fp_of "$(render critic '' '{"severity":"major","area":"Backend","title":"동일 제목","description":"d"}')")"
  fb="$(fp_of "$(render critic '' '{"severity":"major","area":"iOS","title":"동일 제목","description":"d"}')")"
  assert_ne "$fa" "$fb" "area 다른데 fp 동일 — cross-area finding 소실 위험" || exit 0
  pass
)

# RF-4b — critic 모드에서 finding.area 가 env AREA 보다 우선한다(본문 영역 표기까지)
it "RF-4b critic — finding.area 우선(본문 영역 표기)"
(
  out="$(render critic 'EnvArea' '{"severity":"minor","area":"RealArea","title":"t","description":"d"}')"
  assert_contains "$(body_of "$out")" "**영역**: RealArea" "finding.area 가 본문에 안 실림" || exit 0
  pass
)

# RF-5 — finding 소실 방지(버그 #4): 같은 file+severity+title 이라도 description 이
#        다르면 별개 finding → fp 가 달라야 한다(desc_sig).
it "RF-5 description 다르면 fp 다름(#4 소실 방지)"
(
  fa="$(fp_of "$(render code-review Backend '{"severity":"major","file":"a.ts","title":"동일 제목","description":"원인 A"}')")"
  fb="$(fp_of "$(render code-review Backend '{"severity":"major","file":"a.ts","title":"동일 제목","description":"원인 B"}')")"
  assert_ne "$fa" "$fb" "description 다른데 fp 동일 — 별개 finding 소실 위험" || exit 0
  pass
)

# RF-6 — 이모지/구두점만인 title 의 sha 폴백: normalize 결과가 빈 문자열이면
#        서로 다른 title 이 같은 빈 문자열로 뭉개진다. sha 폴백으로 구분돼야 한다.
it "RF-6 이모지/구두점 title 의 sha 폴백"
(
  # 두 title 모두 normalize 후 빈 문자열(구두점/이모지) → sha 폴백이 없으면 fp 충돌.
  fa="$(fp_of "$(render code-review Backend '{"severity":"major","file":"a.ts","title":"🔥🔥","description":"d"}')")"
  fb="$(fp_of "$(render code-review Backend '{"severity":"major","file":"a.ts","title":"???","description":"d"}')")"
  assert_ne "$fa" "$fb" "구두점/이모지 title 이 같은 fp 로 뭉개짐 — sha 폴백 실패" || exit 0
  pass
)

# RF-7 — 한글 title 은 보존된다(sha 폴백으로 뭉개지지 않음): 서로 다른 한글 제목은
#        서로 다른 fp, 같은 한글 제목은 같은 fp. (normalize 가 한글을 지우면 둘 다 폴백돼도
#        내용상 구분은 되지만, 여기선 "한글 보존" 자체를 다른 제목→다른 fp 로 확인.)
it "RF-7 한글 title 보존(다른 제목→다른 fp)"
(
  base='{"severity":"major","file":"a.ts","description":"d"'
  fa="$(fp_of "$(render code-review Backend "$base,\"title\":\"널 체크 누락\"}")")"
  fb="$(fp_of "$(render code-review Backend "$base,\"title\":\"경계 조건 오류\"}")")"
  assert_ne "$fa" "$fb" "다른 한글 제목이 같은 fp — 한글이 normalize 에서 소거됨" || exit 0
  pass
)

# RF-8 — 매우 긴 title 이어도 fp suffix 가 보존된다(base 200자 제한 후 [fp:...] 부착)
it "RF-8 긴 title 에도 fp suffix 보존"
(
  long="$(printf 'x%.0s' $(seq 1 400))"
  out="$(render code-review Backend "{\"severity\":\"major\",\"file\":\"a.ts\",\"title\":\"$long\",\"description\":\"d\"}")"
  fp="$(fp_of "$out")"
  # 제목 끝이 정확히 [fp:<fp>] 로 끝나야 cross-run dedup 검색이 동작한다.
  case "$(title_of "$out")" in
    *"[fp:$fp]") ;;
    *) fail "긴 title 에서 fp suffix 유실"; exit 0 ;;
  esac
  pass
)
