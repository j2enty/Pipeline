# executor·verifier 프롬프트 템플릿

> Step 8-c(영역 단위 실행 블록)에서 참조. executor 호출 입력(`EXECUTOR_PROMPT`)·
> verifier 호출 입력(`VERIFIER_PROMPT`)의 배선만 적는다.
> **절차·반환 JSON 스키마·금지사항은 이미 `pipeline:executor`·`pipeline:verifier` 에이전트
> 시스템프롬프트에 승격되어 있다.** 여기서는 **호출 시 주입할 입력**만 슬림하게 넣는다.
> `<프로젝트명>`·`<owner>` 는 SKILL.md 상단 "프로젝트 설정 (실행시 주입)" 의 `--dump`
> 출력값으로 채운다 (하드코딩 금지).

## 8-c-1. Executor 프롬프트 (`EXECUTOR_PROMPT`)

```
당신은 <프로젝트명> <영역> 영역 executor입니다. (절차·반환 JSON 스키마·금지사항은
당신의 시스템프롬프트를 따릅니다.)

## 입력
- Sub-issue: <owner>/<영역>#<sub-N>
- 플랜: Docs/claude/plans/<parent-N>-<slug>-<영역소문자>.md (먼저 읽기 — 구현 태스크·인수 기준의 단일 진실원)
- 브랜치: feature/#<sub-N>-<slug>
- Base 브랜치: develop
- (재시도 호출 시) verifier reasons: <JSON or "없음"> — 직전 verifier 가 fail 사유를 넘겼으면 그 항목만 고친다(범위 확장 금지)

위 입력으로 플랜대로 구현 → 커밋 → push → 테스트 그린까지 책임지고, 시스템프롬프트의
반환 JSON 스키마로만 응답하세요.
```

> 공통 규칙(`git -C <영역>` 호출, 커밋 스타일)은 `<프로젝트명>` 루트 `CLAUDE.md` 에,
> 영역별 테스트 전략은 각 영역 `CLAUDE.md` 에 위임. 프롬프트에는 이 문서들이 "이미 로드됨"을
> 전제로 작업 지시만 남긴다.

**재시도 정책은 오케스트레이터 소유** — executor 는 `errorSummary.category` 라벨만 달아
반환하고, 상한(fixing 5회 / transient 3회 + 2s→4s→8s 백오프 / immediate 즉시) 적용은
SKILL.md 8-c 루프가 수행한다.

## 8-c-2. Verifier 프롬프트 (`VERIFIER_PROMPT`)

```
당신은 <프로젝트명> <영역> 영역의 독립 verifier입니다. executor 가 스스로 통과했다고
주장한 결과를 재검증합니다. (체크리스트·반환 JSON 스키마는 당신의 시스템프롬프트를
따릅니다.)

## 입력
- 브랜치: <branch>  (diff: git -C <영역> diff origin/develop...HEAD)
- Executor testSummary: <JSON>
- 플랜 문서: Docs/claude/plans/<parent-N>-<slug>-<영역소문자>.md
- Parent 요구사항: Docs/claude/requirements/<parent-N>-<slug>.md

위 입력으로 플랜 준수를 재검증하고, 시스템프롬프트의 반환 JSON 스키마로만 응답하세요.
```

> Backend·Admin·Frontend·iOS·Android 등 영역 이름은 일반 설명용 예시이며, 실제 대상
> 영역은 Step 3 에서 발견된 sub-issue 의 영역으로 채운다. 영역명 소문자(`<영역소문자>`)는
> 플랜 파일명 규칙(R8 — 소문자) 때문이다 (`tr '[:upper:]' '[:lower:]'`).
