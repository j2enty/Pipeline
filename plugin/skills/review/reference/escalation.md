# 에스컬레이션 템플릿·진단 힌트

> Step 9(에스컬 플로우)에서 참조. 에스컬 코멘트 본문(9-b)·진단 힌트 표(9-c)·Slack 이중 발송 규칙.
> `<owner>`·`<영역>` 등은 SKILL.md 의 config 주입값·실행 컨텍스트로 채운다.

## 9-b. 에스컬 코멘트 본문 템플릿 (G9)

실패 단위에 따라 부착 위치 결정 (C7):
- **개별 PR 실패** → 해당 PR 에 코멘트
- **종합 리뷰 실패** → parent issue 에 코멘트

```markdown
## 🚨 `/review` 중단 — <영역 or cross-area>

**PR**: #<N> (또는 Parent: #<parent-N>)
**실패 유형**: `<카테고리> / <구체 사유>` (<count>/<limit> 초과)
**문제**: <핵심 요약>
**원인**: <설명>

**실행 컨텍스트**
- 리뷰 대상 SHA: `<sha>` (PR 실패인 경우)
- 재시도: <카테고리> <count>/<limit>
- 마지막 에러: `.pipeline/state/reviews/<slug>.json` 참조

**재개 방법**
1. 원인 진단
2. 필요 시 코드 수정 + 커밋 push
3. `/review <url>` 재실행

---
*자동 발송됨.*
```

## 9-c. 진단 힌트 표 (카테고리별)

| 사유 | 힌트 |
|---|---|
| JSON 포맷 오류 (fixing) | 프롬프트 재확인, Agent 모델 변경(sonnet→opus) 검토 |
| Rate limit (transient) | GitHub API 쿼터 확인, 시간 두고 재실행 |
| 네트워크 (transient) | 연결 상태 점검 |
| PR 접근 불가 (immediate) | 레포 권한·PAT 스코프 확인 |
| PR 삭제 (immediate) | `/review` 재실행 의미 없음. 새 PR 생성 필요 |
| 플랜 모호 (immediate) | 플랜 문서 수정 후 `/review` 재실행 |
| 머지 충돌 (immediate) | 브랜치 rebase 후 재실행 |

## Slack 이중 발송 규칙

- 메시지 형식: 제목 + 컨텍스트 (실패 유형·원인 요약) + GitHub 코멘트 링크. 풀 컨텍스트 중복 금지 (GitHub 이 영구 기록)
- Slack 토큰 키(config `slack-token-key`) 미설정 시 헬퍼가 graceful skip → 파이프라인 차단 없음
- Slack 발송 실패도 차단 없음 (보조 채널)
- GitHub 코멘트 발송이 1차, Slack 은 항상 그 뒤 호출 (순서 고정 — Slack 먼저 가면 사용자가 빈 링크 클릭 위험)

## 9-e. 영역별 독립 원칙 (G2)

- 한 영역 리뷰 실패·REQUEST_CHANGES 나도 **나머지 영역은 계속 진행**
- Backend 리뷰 실패도 나머지 영역 리뷰는 계속 (`/kickoff`와 다름 — 이미 코드가 짜인 상태라 각 PR은 독립 검토 가능)
- 종합 리뷰 단계에서 Backend 문제가 cross-area 이슈로 재지적될 수 있음
