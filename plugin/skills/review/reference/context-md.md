# Context md append 템플릿

> Step 10(Context md append, Parent 모드 한정)에서 참조.
> 저장 경로는 SKILL.md 에서 config `docs-context-dir` 로 읽어 `<docs-context-dir>/<slug>-status.md` 로 결정한다.

기존 `/kickoff` 섹션은 **유지**하고 맨 아래에 `## 🔍 리뷰 (/review 실행 결과)` 섹션 append (이미 있으면 교체):

```markdown
## 🔍 리뷰 (`/review` 실행 결과)

**실행 시각**: <ISO-8601>
**Verdict 요약**: <APPROVE N / REQUEST_CHANGES M / escalated K>

| 영역 | 판정 | PR | Status | 비고 |
|---|---|---|---|---|
| Backend | ✅ APPROVE | #12 | `In Review` | 사용자 hands-on 검증 대기 |
| Frontend | ❌ REQUEST_CHANGES | #13 | `Bot Review` | blocker 2건 · `review-blocked` 라벨 |
| iOS | ⚪ pending | #14 | `Bot Review` | 새 커밋 대기 |

> Status 전환은 APPROVE 판정일 때만 `Bot Review → In Review`. REQUEST_CHANGES·escalated·pending은 `Bot Review` 유지. 전환 실패 시 `statusTransition.error` 필드 확인.

### 종합 리뷰 (critic)
- verdict: `pass | concerns`
- 주요 findings:
  - [major] ...
  - [minor] ...

### 참고
- 리뷰 상태 파일: `.pipeline/state/reviews/<slug>.json`
- 종합 리뷰 parent 코멘트: <URL>
```

## 10-a. Docs 커밋 트리거 (`/kickoff` G7-c 동일 조건)

**먼저 Docs 가 독립 git 레포 루트인지**(`--show-toplevel` 일치) 확인하고, 아니면(미클론·부모 git 하위 일반 dir 포함) 이 커밋 단계 전체를 스킵한다. 있을 때만 아래 트리거를 평가한다.

다음 중 하나 이상 충족 시만 Docs 레포에 커밋·push:
- (a) 한 영역 이상 `verdict=escalated` 또는 `request_changes`
- (b) SIGINT 캡처로 중단
- (c) 혼합 상태 (approved + request_changes · escalated 동시 존재)
- (d) `aggregate.criticFindings` 가 비어있지 않으면 (R11 — 개별 모두 approved 라도 critic 이 짚은 cross-area finding 을 영구 보존. critic 반환 규칙상 `findings 1건 이상` ⟺ verdict 가 pass 가 아님 이므로 blocker/major/minor 전부 포착. 하위호환: 구버전(1.0) 상태 파일은 `criticFindings` 키 부재 → "부재=빈 배열"로 간주해 트리거 off)

클린 성공(전부 approved · critic pass)은 Docs 커밋 생략.
