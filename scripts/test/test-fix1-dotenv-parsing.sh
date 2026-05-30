#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Fix 1 — read_existing_webhook_secret dotenv 호환 파싱.
# export형 / = 공백형 / 큰따옴표 / 작은따옴표 / CRLF / 주석라인 / 유사키 각각 검증.

# 헬퍼: 임시 .env 작성 후 read_existing_webhook_secret 호출 → 값 반환
_read_from_env() {
  local content="$1"
  (
    setup_install_env
    tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
    printf '%s' "$content" > "$tmp_env"
    result="$(read_existing_webhook_secret 2>/dev/null)"
    printf '%s' "$result"
    rm -f "$tmp_env"
  )
}

# F1-1 — 기본 형식 (회귀 보장)
it "F1-1 기본 WEBHOOK_SECRET=value 파싱"
(
  val="$(_read_from_env 'WEBHOOK_SECRET=plain_secret_value'$'\n')"
  assert_eq "plain_secret_value" "$val" "기본 파싱 실패" && pass
)

# F1-2 — export 접두
it "F1-2 export WEBHOOK_SECRET=value 파싱"
(
  val="$(_read_from_env 'export WEBHOOK_SECRET=exported_secret'$'\n')"
  assert_eq "exported_secret" "$val" "export 형 파싱 실패" && pass
)

# F1-3 — 키와 = 사이 공백
it "F1-3 WEBHOOK_SECRET =value (공백) 파싱"
(
  val="$(_read_from_env 'WEBHOOK_SECRET =spaced_secret'$'\n')"
  assert_eq "spaced_secret" "$val" "키=공백 형 파싱 실패" && pass
)

# F1-4 — 큰따옴표 벗기기
it "F1-4 WEBHOOK_SECRET=\"value\" 따옴표 제거"
(
  val="$(_read_from_env 'WEBHOOK_SECRET="quoted_double"'$'\n')"
  assert_eq "quoted_double" "$val" "큰따옴표 제거 실패" && pass
)

# F1-5 — 작은따옴표 벗기기
it "F1-5 WEBHOOK_SECRET='value' 따옴표 제거"
(
  val="$(_read_from_env "WEBHOOK_SECRET='quoted_single'"$'\n')"
  assert_eq "quoted_single" "$val" "작은따옴표 제거 실패" && pass
)

# F1-6 — CRLF 라인엔딩 후행 CR 제거
it "F1-6 CRLF 라인엔딩 후행 CR 제거"
(
  # printf 로 CR+LF 포함 내용 작성
  val="$(_read_from_env "$(printf 'WEBHOOK_SECRET=crlf_secret\r\n')")"
  assert_eq "crlf_secret" "$val" "CRLF CR 미제거" && pass
)

# F1-7 — 주석 라인은 무시 (# 시작)
it "F1-7 주석 라인(# WEBHOOK_SECRET=...) 무시"
(
  val="$(_read_from_env '# WEBHOOK_SECRET=commented_out'$'\n')"
  assert_eq "" "$val" "주석 라인이 매칭됨" && pass
)

# F1-8 — 유사키 OLD_WEBHOOK_SECRET 무시
it "F1-8 유사키 OLD_WEBHOOK_SECRET 오매칭 방지"
(
  val="$(_read_from_env 'OLD_WEBHOOK_SECRET=should_not_match'$'\n')"
  assert_eq "" "$val" "OLD_WEBHOOK_SECRET 오매칭" && pass
)

# F1-9 — 유사키 WEBHOOK_SECRET_BAK 무시
it "F1-9 유사키 WEBHOOK_SECRET_BAK 오매칭 방지"
(
  val="$(_read_from_env 'WEBHOOK_SECRET_BAK=should_not_match'$'\n')"
  assert_eq "" "$val" "WEBHOOK_SECRET_BAK 오매칭" && pass
)

# F1-10 — 유사키가 앞에 있고 진짜 키가 뒤에 있을 때 올바른 값 추출
it "F1-10 유사키 다음 줄에 진짜 키 — 진짜 값만 반환"
(
  content="$(printf 'OLD_WEBHOOK_SECRET=old_val\nWEBHOOK_SECRET=real_val\n')"
  val="$(_read_from_env "$content")"
  assert_eq "real_val" "$val" "유사키 섞인 파일에서 진짜 값 추출 실패" && pass
)

# F1-11 — export + 큰따옴표 조합
it "F1-11 export WEBHOOK_SECRET=\"value\" 조합 파싱"
(
  val="$(_read_from_env 'export WEBHOOK_SECRET="combo_secret"'$'\n')"
  assert_eq "combo_secret" "$val" "export+따옴표 조합 실패" && pass
)
