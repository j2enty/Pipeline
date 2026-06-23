# 상태 파일 스키마 (schemaVersion 1.1)

> Step 5(상태 파일 초기화/갱신)·7-i(개별 리뷰 기록)·8-c-bis(critic finding 기록)에서 참조.
> 이 스키마는 code-reviewer·verifier·critic 가 반환한 JSON 을 1:1 로 보존하는 **단일 진실원**이다.
> 후속 GHA(critic.yml·track-findings action)가 이 파일을 읽으므로 키·구조를 임의로 바꾸지 않는다.

## 전체 스키마

```json
{
  "schemaVersion": "1.1",
  "mode": "parent" | "single",
  "slug": "<SLUG>" | null,
  "linkedKickoffSession": "<SLUG>" | null,
  "parent": {"url": "...", "number": 0} | null,
  "prs": {
    "<area>": {
      "url": "...",
      "number": 0,
      "repo": "<owner>/<area>",
      "planPath": ".pipeline/state/reviews/cache/<parent-N>-<slug>-<area-lowercase>-plan.md" | null,
      "planSource": "Docs@plan/<parent-N>-<slug>:claude/plans/<parent-N>-<slug>-<area-lowercase>.md" | null,
      "lastReviewedSha": null,
      "verdict": "pending",
      "reviewUrl": null,
      "retry": {"fixing": {"count":0,"limit":3}, "transient": {"count":0,"limit":3}},
      "lastError": null,
      "escalation": null,
      "reviewBlockedLabel": false,
      "findingsSummary": {"blocker":0, "major":0, "minor":0, "nit":0},
      "findings": {
        "codeReview": [
          {"severity": "...", "file": "...", "line": 0, "title": "...", "description": "...", "suggestion": "..."}
        ],
        "verifier": {"verdict": "pass" | "fail", "reasons": []}
      },
      "startedAt": null,
      "completedAt": null
    }
  },
  "aggregate": {
    "verdict": null,
    "parentCommentUrl": null,
    "criticFindings": [
      {"severity": "...", "area": "...", "title": "...", "description": "...", "affected_prs": []}
    ],
    "completedAt": null
  },
  "createdAt": "...", "updatedAt": "...",
  "events": [{"ts": "...", "type": "run_start", "mode": "...", "prs": ["<area>", ...]}]
}
```

> `repo` 의 `<owner>` 는 config `owner` 값으로 채운다 (하드코딩 금지).

파일 쓰기는 원자적 (temp + `mv`). 매 상태 전이·retry 증가·에스컬·SIGINT 시 갱신.

## schemaVersion 1.1 (2026-05-30) — finding 영구 보존 필드

- `prs.<area>.findingsSummary` (최상위): severity별 카운트. **요약 카운트의 단일 진실원** — `findings` 하위에 `summary` 키를 따로 두지 않는다(중복 금지).
- `prs.<area>.findings.codeReview[]`: code-reviewer 가 낸 상세 finding 배열. 필드는 `severity, file, line, title, description, suggestion` 6개. (개별 라인 코멘트 URL 은 7-f 가 atomic POST 라 응답에서 못 얻으므로 저장하지 않음.)
- `prs.<area>.findings.verifier`: verifier 판정(`verdict`, `reasons`).
- `aggregate.criticFindings[]`: critic 이 낸 cross-area finding 배열. 필드는 `severity, area, title, description, affected_prs` 5개. (critic 스키마엔 `file`/`line` 이 없다.)

**하위호환**: 구버전(`1.0`) 상태 파일에는 `findings`/`criticFindings` 가 없다. 소비자는 이 키들의 부재를 **빈 값**(빈 배열/빈 객체)으로 취급한다. 기존 필드·기존 동작은 일절 변경되지 않으며, 위 키들은 **추가만** 된 것이다.

## 7-i. 개별 리뷰 상태 파일 갱신 (run_individual_review 종료 시)

```json
"prs": {
  "<area>": {
    "verdict": "approved" | "request_changes",
    "reviewUrl": "<submitted review URL>",
    "lastReviewedSha": "<현재 PR head SHA>",
    "reviewBlockedLabel": true | false,
    "findingsSummary": {"blocker": 0, "major": 0, "minor": 0, "nit": 0},
    "findings": {
      "codeReview": [
        {"severity": "...", "file": "...", "line": 0, "title": "...", "description": "...", "suggestion": "..."}
      ],
      "verifier": {"verdict": "pass" | "fail", "reasons": []}
    },
    "statusTransition": {
      "from": "Bot Review" | "In Progress" | null,
      "to": "In Review" | null,
      "attemptedAt": "<ISO-8601>",
      "succeeded": true | false,
      "error": "<메시지 or null>"
    },
    "completedAt": "<ISO-8601>"
  }
},
"events": [..., {"ts": "...", "type": "individual_reviewed", "area": "<area>", "verdict": "..."},
            {"ts": "...", "type": "status_transition", "area": "<area>", "from": "...", "to": "..."}]
```

**finding 기록 규칙 (schemaVersion 1.1)** — 7-d 에서 보존한 결과를 여기서 상태 파일에 쓴다:
- `prs.<area>.findingsSummary` (최상위): 7-d 에서 집계한 severity별 카운트. **요약 카운트의 단일 진실원**. `findings` 하위에 `summary` 키를 만들지 않는다(중복 금지).
- `prs.<area>.findings.codeReview[]`: 7-d 에서 보존한 code-reviewer finding 배열을 그대로 기록. 각 항목은 `severity, file, line, title, description, suggestion` 6개 필드만(개별 코멘트 URL 은 7-f 가 atomic POST 라 못 얻으므로 저장하지 않음).
- `prs.<area>.findings.verifier`: 7-d 에서 보존한 verifier 의 `{verdict, reasons}`. 플랜 없어 verifier 미실행이면 `{"verdict":"pass","reasons":[]}`.
- `line` 주의: code-reviewer 가 보고한 line 은 "리뷰 당시 NEW 파일 기준"이라 머지/리베이스 후 무효화될 수 있다.

## 8-c-bis. critic verdict·findings 상태 파일 기록 (schemaVersion 1.1)

8-c 의 parent 코멘트 렌더와 **별개로**, 8-b critic 이 반환한 **verdict 와 findings 를 상태 파일 `aggregate` 에 함께 기록**한다(코멘트는 휘발성, 상태 파일은 영구 보존·후속 추적용):

```json
"aggregate": {
  "verdict": "pass" | "concerns" | "blocker",
  "parentCommentUrl": "<PARENT_COMMENT_URL>",
  "criticFindings": [
    {"severity": "...", "area": "...", "title": "...", "description": "...", "affected_prs": []}
  ],
  "completedAt": "<ISO-8601>"
}
```

- `aggregate.verdict`: 8-b 의 critic 반환 verdict(`pass`/`concerns`/`blocker`)를 **이 단계에서 기록**한다. enum 은 `pass`/`concerns`/`blocker` 고정(전체 리뷰 enum 으로 바꾸지 않는다). `.github/workflows/critic.yml` 이 이 값을 읽어 머지 분기하며 allowlist 밖이면 fail-closed 로 머지 차단. **8-c-bis 가 verdict 를 쓰는 유일한 실행 지점**이므로 이 기록이 빠지면 verdict 가 초기값 null 로 남아 critic 자동머지가 영구 차단된다(#54).
- `aggregate.criticFindings[]`: 8-b 의 critic 반환 `findings[]` 각 항목을 그대로 기록. 각 항목은 `severity, area, title, description, affected_prs` 5개 필드(critic 스키마엔 `file`/`line` 이 없다 — area/affected_prs 만으로 식별). critic findings 가 0건이면 빈 배열(`[]`).
- 개별 PR verdict(`prs.<area>.verdict`: `approved`/`request_changes`)와는 **별개**다 — `aggregate.verdict` 는 critic 종합 verdict 다(혼동 금지).
- verdict·criticFindings 는 한 jq 트랜잭션으로 원자적(temp + `mv`) 기록한다.

## 9-d. 에스컬 시 상태 파일 업데이트

```json
"prs": {
  "<area>": {
    "verdict": "escalated",
    "escalation": {
      "category": "fixing|transient|immediate",
      "subcategory": "<한글>",
      "commentUrl": "<코멘트 URL>",
      "commentedAt": "..."
    },
    "reviewBlockedLabel": true,
    "lastError": "<stderr 말미 20줄>"
  }
},
"events": [..., {"ts": "...", "type": "escalation", "scope": "pr|aggregate", "area": "<area>"}]
```
