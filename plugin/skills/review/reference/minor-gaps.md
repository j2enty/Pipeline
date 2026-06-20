# Minor 격차 (구현 중 발견 시 결정)

> 원본 review.md.tmpl 의 "Minor 격차" 섹션. 구현·운영 중 마주칠 수 있는 경계 케이스 결정 기록.
> `<owner>`·`<reviewer-bot-slug>`·`<author-login>` 등은 SKILL.md 의 config 주입값으로 해석한다 (하드코딩 금지).

- **R1** PR에 이미 사람 리뷰가 있는 경우 — 현재는 병존 (덮어쓰지 않음). dismiss 필요하면 명시적 플래그 추가 논의
- **R2** base 브랜치가 `develop` 아닌 경우 — 현재는 PR의 `baseRefName` 동적 사용
- **R3** critic `concerns` 시 개별 PR 판정 덮기 — 현재는 개별 판정 유지, critic은 parent 코멘트로만 반영
- **R4** Agent 타임아웃 — Agent 기본에 의존
- **R5** 머지 충돌 PR (diff 계산 실패) — `immediate` 에스컬, 사용자 rebase 안내
- **R6** 동일 PR 반복 리뷰 시 이전 Review dismiss — 현재는 새 Review 추가만, dismiss 안 함
- **R7** (해결 · 2026-04-20) 플랜 파일이 Docs 레포 `plan/<parent-N>-<slug>` 브랜치에만 존재 — `git -C Docs show plan/<parent-N>-<slug>:claude/plans/...`로 추출해 `.omc/state/reviews/cache/` 캐시에 materialize 후 Agent에 전달
- **R8** (해결 · 2026-04-20) 플랜 파일명 영역은 **소문자** (`<parent-N>-<slug>-frontend.md`, `<parent-N>-<slug>-ios.md`, `<parent-N>-<slug>-android.md`, `<parent-N>-<slug>-backend.md`) — `/review`가 경로 구성 시 `tr '[:upper:]' '[:lower:]'` 적용
- **R9** (도입 · 2026-04-21) APPROVE 판정 시 sub-issue Status `Bot Review → In Review` 전환 — `/kickoff` 의 `Bot Review` stage split 연장선. 전환 대상은 `Status=Bot Review` 인 항목만. 전환 실패는 에스컬 아님(경고 로그 + `statusTransition.succeeded=false` 기록)
- **R10** (도입 · 2026-05-02) Self-approve 차단 회피 — config `author-login` user 토큰으로 review 부착 시 PR author 와 같은 entity 라 GitHub 가 "Can not approve your own pull request" 로 차단. 해결: config `reviewer-bot-slug` GitHub App (App ID = config `reviewer-app-id`) installation token 사용. App 은 user 와 다른 entity 라 차단 회피 + 정식 `[bot]` 명의 부착. 설정·인증 흐름:
  - 환경변수 (`.zshrc`): config `reviewer-token-key` 값을 PREFIX 로 하는 `<PREFIX>_APP_ID`, `<PREFIX>_PEM` (.pem 파일 경로), `<PREFIX>_INSTALLATION_ID` 모두 `export`
  - 헬퍼 스크립트: `"${CLAUDE_SKILL_DIR}/scripts/gh-app-token.sh" "<reviewer-token-key>"` → installation token (1시간 유효)
  - 호출은 7-f 의 REST API 단일 POST 패턴 (review + line comments atomic)
  - GraphQL `addPullRequestReviewComment` 는 `line` 인자 미지원이라 사용 금지 (이전 명세 잘못)
  - M3 GHA 도입 시 `.pem` 을 GHA Secret 으로 이전 → 로컬 사본 폐기 가능 (이전 자동화 봇과 같은 보안 모델)
- **R11** (도입 · 2026-05-03) Docs 커밋 트리거에 `critic verdict=concerns` 추가 — 기존 10-a 트리거 (a)(b)(c) 는 개별 verdict (escalated/request_changes) 또는 SIGINT/혼합 상태만 감지. 개별 모두 approved + critic concerns 케이스가 빠져 있어 cross-area finding 이 영구 보존되지 않는 문제 발견 (관찰 사례: 2026-05-03 `m2-scaffolding` — 두 PR APPROVE 인데 critic 이 blocker 1건 + major 2건 짚음). 해결: 트리거에 (d) `aggregate.criticVerdict == "concerns"` 추가. critic finding 이 있으면 `<docs-context-dir>/<slug>-status.md` 자동 push 해서 M3 작업자가 진입 시 컨텍스트 로드 가능하게.
