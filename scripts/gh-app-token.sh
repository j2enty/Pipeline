#!/usr/bin/env bash
# gh-app-token.sh — GitHub App installation access token 발급
#
# 배경:
#   GitHub App 으로 자동화 호출 시 PAT 가 아닌 App 명의가 필요해요.
#   App 인증은 (1) App private key 로 JWT 만들고 → (2) JWT 로 installation token
#   받고 → (3) installation token 으로 API 호출하는 3단계인데, (1)(2) 가
#   매번 보일러플레이트라 이 스크립트로 캡슐화.
#
# 사용법:
#   TOKEN=$(./scripts/gh-app-token.sh <ENV_PREFIX>)
#   curl -H "Authorization: token $TOKEN" https://api.github.com/...
#
# 환경변수 (PREFIX 가 AUTHOR 이면 다음 3개 필요):
#   AUTHOR_APP_ID            — GitHub App ID
#   AUTHOR_PEM               — Private key 파일 절대경로
#   AUTHOR_INSTALLATION_ID   — App 이 설치된 Installation ID
#
# 출력:
#   stdout 한 줄: installation token (예: ghs_xxxxx...)
#   유효기간: 발급 후 1시간 (GitHub 정책)
#
# 예:
#   TOKEN=$(./scripts/gh-app-token.sh AUTHOR)
#   TOKEN=$(./scripts/gh-app-token.sh REVIEWER)
#
# 참고: PREFIX 만 일반화돼 있어 다른 GitHub App 에도 그대로 재사용 가능.
#   새 App 추가 시 환경변수 3개만 같은 네이밍 규칙으로 등록하면 됨.

set -euo pipefail

PREFIX="${1:?사용법: $0 <ENV_PREFIX> (예: AUTHOR, REVIEWER)}"

APP_ID_VAR="${PREFIX}_APP_ID"
PEM_VAR="${PREFIX}_PEM"
INSTALL_VAR="${PREFIX}_INSTALLATION_ID"

APP_ID="${!APP_ID_VAR:?$APP_ID_VAR 환경변수 필요}"
PEM="${!PEM_VAR:?$PEM_VAR 환경변수 필요}"
INSTALL_ID="${!INSTALL_VAR:?$INSTALL_VAR 환경변수 필요}"

[ -r "$PEM" ] || { echo "ERROR: PEM 파일 없음 또는 읽기 불가: $PEM" >&2; exit 1; }

# JWT 생성 (RS256). GitHub 정책: exp 는 iat+10분 이내, iat 는 서버 시계 어긋남
# 대비해 60초 이전으로 설정.
NOW=$(date +%s)
IAT=$((NOW - 60))
EXP=$((NOW + 540))

# base64url (RFC 7515): + → -, / → _, = padding 제거
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '%s' "{\"iat\":$IAT,\"exp\":$EXP,\"iss\":$APP_ID}" | b64url)
SIGNATURE=$(printf '%s' "$HEADER.$PAYLOAD" \
  | openssl dgst -sha256 -sign "$PEM" \
  | b64url)
JWT="$HEADER.$PAYLOAD.$SIGNATURE"

# Installation access token 요청
RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALL_ID/access_tokens")

TOKEN=$(printf '%s' "$RESPONSE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null \
  || true)

if [ -z "$TOKEN" ]; then
  echo "ERROR: Installation token 발급 실패" >&2
  echo "Response: $RESPONSE" >&2
  exit 1
fi

printf '%s' "$TOKEN"
