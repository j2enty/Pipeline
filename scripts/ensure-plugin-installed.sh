#!/usr/bin/env bash
# ensure-plugin-installed.sh — Pipeline 플러그인을 claude Code user scope 에
# "항상 최신 내용으로" 멱등 설치한다. 워크플로(review·kickoff·critic·critic-dispatch)가
# /pipeline:* 슬래시커맨드를 호출하기 "직전"에 부른다.
#
# 왜 필요한가 — 신뢰(trust) 게이트 우회:
#   claude Code 는 신뢰되지 않은 git repo(=영역 레포 체크아웃 폴더)에서 `--plugin-dir`
#   로컬 plugin 을 비대화(-p)로 로드하지 않는다(P3.3 e2e 에서 확인, 이슈 #31).
#   반면 `plugin install` 로 user scope(~/.claude)에 정식 설치한 plugin 은 cwd 신뢰와
#   무관하게 로드된다. 그래서 워크플로는 --plugin-dir 대신 "설치본"을 쓴다.
#
# 왜 install 단독이 아니라 marketplace update + uninstall + install 인가
# (claude 2.1.186, 신뢰 안 된 git repo 실측 — 이슈 #31 P3.3):
#   - `claude plugin install` 은 이미 설치돼 있으면 "already installed" 로 스킵 →
#     소스가 바뀌어도 미반영.
#   - `claude plugin update` 는 plugin.json 의 version 문자열이 바뀔 때만 갱신 →
#     version 을 고정(0.x.x)한 채 SKILL/에이전트 "내용"만 바꾸는 우리 일반 패턴에선 미반영.
#   - `claude plugin marketplace add` 는 한번 등록되면 "already on disk" 로 소스 재읽기를
#     안 한다 → 소스 디렉토리 변경을 마켓플레이스 캐시에 반영하려면 `marketplace update` 필요.
#   따라서 매 실행 항상 최신 plugin 을 보장하는 유일하게 신뢰 가능한 시퀀스 =
#     marketplace add(등록) → marketplace update(소스→캐시) → uninstall → install.
#   (왜 중요한가: 자동화 인프라에서 "코드 고쳤는데 러너는 옛 버전으로 도는" 버전 드리프트는
#    재현·디버깅이 가장 어려운 유령버그라 구조적으로 차단한다.)
#
# ⚠️ 운영 전제 — 동시성(반드시 지킬 계약):
#   이 스크립트는 user scope(~/.claude)라는 "공유 전역 상태"를 uninstall→install 로
#   비원자적으로 갱신한다. 따라서 self-hosted 러너가 "단일 1대(=job 직렬 실행)"임을
#   전제한다. 단일 러너에선 두 워크플로가 물리적으로 동시에 돌 수 없어 경합이 없고,
#   각 워크플로는 자기 claude 호출 "직전"에 자기 pipeline-ref 로 설치하므로 ref 격리도
#   정확하다.
#   러너를 다중화하면 이 전제가 깨진다: 한 워크플로의 claude -p 가 plugin 을 읽는 중에
#   다른 워크플로가 uninstall→install 하면 'command not found'·버전 섞임(cross-ref 오염)이
#   난다. 그 시점의 해법은 (a) 러너 레벨에서 plugin 설치/실행을 직렬화(GitHub Actions
#   concurrency 또는 설치 전용 단일 잡)하거나 (b) 여기에 파일 락을 도입하는 것이다.
#   지금 락을 넣지 않는 이유: 단일 러너에선 죽은 코드이고, stale 락 정리 없이는 데드락
#   리스크만 추가되기 때문(YAGNI). 다중화는 인프라 결정이라 그 시점에 인프라 레벨로 푼다.
#
# 종속성 제로: 마켓플레이스 소스 경로는 인자로 주입받는다(프로젝트 식별자 하드코딩 없음).
# 'pipeline' 마켓플레이스명·'pipeline@pipeline' 플러그인명은 Pipeline 프레임워크 자체
# 식별자(.claude-plugin/marketplace.json)이지 특정 사용자 프로젝트 식별자가 아니다.
set -euo pipefail

MARKETPLACE_SOURCE="${1:?마켓플레이스 소스 경로(=Pipeline 체크아웃 루트)를 첫 인자로 넘기세요}"
MARKETPLACE_NAME="pipeline"
PLUGIN_REF="pipeline@pipeline"

# 1) 마켓플레이스 등록 — 최초만 실제 등록, 이후 "already on disk" 로 멱등(exit 0).
claude plugin marketplace add "$MARKETPLACE_SOURCE"
# 2) 소스 디렉토리 → 마켓플레이스 캐시 최신화 — 2차+ 실행에서 소스 변경을 반영하는 핵심 단계.
claude plugin marketplace update "$MARKETPLACE_NAME"
# 3) 기존 설치 제거 — 최초엔 미설치라 실패가 정상이므로 무시(|| ...). version 무관하게
#    내용 갱신을 강제하는 유일 경로(install/update 단독은 위 주석대로 스킵될 수 있음).
#    stderr 를 숨기지 않는다 — 권한/락 같은 "진짜" 실패는 로그에 보여 장애 추적이 되게.
#    (codex 교차리뷰 반영: 과거 2>/dev/null 은 실패 원인을 통째로 은닉했다.)
claude plugin uninstall "$PLUGIN_REF" || echo "  (uninstall 스킵 — 미설치이거나 무시 가능한 실패. 위 메시지 참고.)"
# 4) 최신 캐시에서 새로 설치(user scope, ~/.claude — self-hosted 러너에 영구).
claude plugin install "$PLUGIN_REF"
