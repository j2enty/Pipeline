#!/usr/bin/env bash
# bump-version.sh — 플러그인 버전(plugin/.claude-plugin/plugin.json 의 version)을 semver 규칙으로 올린다
#
# 배경:
#   plugin/ 코드를 고칠 때마다 version 을 손으로 올려야 하는데 자주 깜빡한다.
#   이 스크립트로 한 번에 올리고, CI 의 version-gate 잡이 "올렸는지"를 강제한다.
#
# 사용법:
#   bash scripts/bump-version.sh <patch|minor|major>
#     patch: 0.1.0 → 0.1.1  (버그수정 — 끝자리 +1)
#     minor: 0.1.0 → 0.2.0  (기능추가 — 가운데 +1, patch 0 리셋)
#     major: 0.1.0 → 1.0.0  (호환깨짐/정식출시 — 앞자리 +1, minor·patch 0 리셋)
#
# 동작:
#   plugin/.claude-plugin/plugin.json 의 version 필드만 바꿔 같은 파일에 다시 쓴다.
#   JSON 편집은 python3 로 처리하되 version 값 한 곳만 치환 — 나머지 키·순서·들여쓰기 보존.
#   바꾼 결과를 "vX.Y.Z → vA.B.C" 한 줄로 출력.
#
# 종료코드: 성공 0, 인자 없음·잘못된 인자 2, 그 외 오류 1.
#
# 환경변수(옵션):
#   PLUGIN_JSON  — 대상 plugin.json 경로 (미설정 시 레포의 표준 경로). 테스트가 임시 복사본을 주입할 때 사용.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
사용법: bash scripts/bump-version.sh <patch|minor|major>
  patch: 끝자리 +1            (예: 0.1.0 → 0.1.1)
  minor: 가운데 +1, patch 리셋 (예: 0.1.5 → 0.2.0)
  major: 앞자리 +1, 나머지 리셋 (예: 0.1.5 → 1.0.0)
EOF
}

# ── 인자 검증 ────────────────────────────────────────────────
PART="${1:-}"
case "$PART" in
  patch|minor|major) ;;
  *) usage; exit 2 ;;
esac

PLUGIN_JSON="${PLUGIN_JSON:-$REPO_ROOT/plugin/.claude-plugin/plugin.json}"
if [ ! -f "$PLUGIN_JSON" ]; then
  printf 'bump-version: plugin.json 을 찾을 수 없습니다: %s\n' "$PLUGIN_JSON" >&2
  exit 1
fi

# ── version 치환 (python3 — version 값 한 곳만, 나머지 형식 보존) ──
python3 - "$PLUGIN_JSON" "$PART" <<'PYEOF'
import json
import re
import sys

path, part = sys.argv[1], sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# JSON 유효성 + 현재 version 추출 (파싱 실패 시 예외로 비정상 종료)
data = json.loads(text)
current = data.get("version")
if not isinstance(current, str):
    sys.stderr.write("bump-version: plugin.json 에 string 타입 version 필드가 없습니다\n")
    sys.exit(1)

m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", current)
if not m:
    sys.stderr.write(f"bump-version: version 이 X.Y.Z 형식이 아닙니다: {current}\n")
    sys.exit(1)

major, minor, patch = (int(g) for g in m.groups())
if part == "patch":
    patch += 1
elif part == "minor":
    minor += 1
    patch = 0
else:  # major
    major += 1
    minor = 0
    patch = 0
new = f"{major}.{minor}.{patch}"

# version 값 한 곳만 치환 — 키 순서·들여쓰기·기타 형식을 byte 단위로 보존.
pattern = r'("version"\s*:\s*")' + re.escape(current) + r'(")'
new_text, n = re.subn(pattern, r"\g<1>" + new + r"\g<2>", text, count=1)
if n != 1:
    sys.stderr.write("bump-version: version 필드 치환에 실패했습니다\n")
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)

print(f"v{current} → v{new}")
PYEOF
