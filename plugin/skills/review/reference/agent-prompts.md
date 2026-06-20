# 리뷰어 Agent 프롬프트 템플릿

> Step 7-a/7-b/7-c(개별 리뷰), Step 8-a/8-b(종합 리뷰)에서 참조.
> **체크리스트·severity 정의·반환 JSON 스키마는 이미 `pipeline:code-reviewer`·`pipeline:verifier`·`pipeline:critic` 에이전트 시스템프롬프트에 승격되어 있다.** 여기서는 **호출 시 주입할 입력 배선**만 슬림하게 적는다.
> `<프로젝트명>`·`<owner>` 는 SKILL.md 상단 "프로젝트 설정 (실행시 주입)" 의 `--dump` 출력값으로 채운다 (하드코딩 금지).

## 7-b. Code-reviewer 프롬프트 (`CODE_REVIEW_PROMPT`)

```
당신은 <프로젝트명> <영역> 영역 PR 의 독립 code-reviewer입니다. (severity 분류·반환 JSON
스키마·금지사항은 당신의 시스템프롬프트를 따릅니다.)

## 입력
- PR: <pr-url>
- Base: <baseRefName> (대부분 develop)
- Diff 기준: git -C <영역> diff origin/<baseRefName>...<branch>
- 플랜 문서(로컬 캐시): <planPath or "없음">
  - 원본 위치: <planSource or "없음"> (Docs 레포 plan/<parent-N>-<slug> 브랜치에서 materialize됨)
- Parent 이슈: <parent-url or "수동 PR">

위 입력으로 diff 를 적대적으로 리뷰하고, 시스템프롬프트의 반환 JSON 스키마로만 응답하세요.
```

- **플랜 있음**: code-reviewer + verifier 를 **동일 메시지 내 두 Agent 로 병렬 호출**.
- **플랜 없음**: code-reviewer 단독.

## 7-c. Verifier 프롬프트 (`VERIFIER_PROMPT`) — 플랜 있을 때만

```
당신은 <프로젝트명> <영역> 영역 PR 의 독립 verifier입니다. PR 이 플랜을 준수하는지
검증합니다. (체크리스트·반환 JSON 스키마는 당신의 시스템프롬프트를 따릅니다.)

## 입력
- PR: <pr-url>
- 브랜치: <branch> (diff: git -C <영역> diff origin/<baseRefName>...HEAD)
- 플랜 문서(로컬 캐시): <planPath>
  - 원본 위치: <planSource> (Docs 레포 plan/<parent-N>-<slug> 브랜치)
- Parent 요구사항(로컬 캐시): <reqPath or "없음">
  - 원본 위치: Docs@plan/<parent-N>-<slug>:claude/requirements/<parent-N>-<slug>.md (있으면)

위 입력으로 플랜 준수를 재검증하고, 시스템프롬프트의 반환 JSON 스키마로만 응답하세요.
```

## 8-b. Critic 프롬프트 (`CRITIC_PROMPT`) — 영역 간 종합 리뷰(모드 C)

```
당신은 <프로젝트명> parent 이슈 #<parent-N> 의 종합 리뷰어입니다. pipeline:critic 을
**영역 간 종합 리뷰 모드(모드 C)** 로 호출합니다. (cross-area 체크리스트·3축 격차·반환
JSON 스키마는 당신의 시스템프롬프트를 따릅니다.)

## 입력
- Parent: <parent-url> "<title>"
- Slug: <slug>
- 영역별 PR (각각 URL + 플랜 경로 + 개별 리뷰 요약):
  - Backend: <pr-url> / <plan> / <code-review summary>
  - Frontend: ...
  - iOS: ...
  - Android: ...
  - 참고: critic-only 모드면 개별 리뷰 요약이 없을 수 있음. 그럴 땐 critic 이 각 PR 의
    diff(git -C <영역> diff origin/<baseRefName>...<branch>)를 직접 읽어 검토. (이전 요약이
    상태 파일에 캐시돼 있으면 보조로 사용, 없으면 diff 직접 확인)

위 입력으로 cross-area 일관성을 점검하고, 시스템프롬프트의 모드 C 반환 JSON 스키마로만
응답하세요.
```

> Backend·Frontend·iOS·Android 등 영역 이름은 일반 설명용 예시이며, 실제 대상 영역은 Step 2 에서 수집된 PR 의 영역으로 채운다.
