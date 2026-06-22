---
paths:
  - "app/**"
---

# App 코드 규칙 (Probot / TypeScript)

> `app/` 작업 시 자동 로드되는 경로 규칙. App 스택 선택 근거·배포·환경 분리 등 **설계 배경은 `docs/architecture.md`** 참조.

## 로깅

- Probot 기본 로거 사용 (`app.log.info()`, `app.log.warn()`, `app.log.error()`)
- 구조화된 JSON 포맷 — 운영 서버에서 파싱·모니터링 용이
- 레벨 기준: DEBUG(개발), INFO(정상 흐름), WARN(비정상이지만 처리 가능), ERROR(처리 실패)

## 에러 처리

- 예상된 에러 (rate limit·timeout·일시적 API 오류) → 재시도
- 예상치 못한 에러 (파싱 실패·권한 없음 등) → 즉시 에스컬레이션
- GHA yml 실패 → App이 결과 수신 후 판단 (재시도 vs 에스컬레이션)

## 재시도 정책

- 최대 **3회**, 지수 백오프 (1초 → 2초 → 4초)
- GHA yml: `retry-on-failure: 3`
- App: Probot 내장 retry 또는 직접 구현

## 에스컬레이션

| 트리거 | 자동 액션 |
|---|---|
| 재시도 3회 전부 실패 | 슬랙 알림(옵션) + GitHub 이슈 자동 생성 |
| critic 결과 `escalated` | 슬랙 알림(옵션) + 백로그 이슈 자동 생성 |
| 사람 판단 필요 | 슬랙 + 해당 이슈에 코멘트 |

- 슬랙 알림은 `SLACK_WEBHOOK_URL` 미설정 시 자동 스킵 (파이프라인 전체는 정상 진행)
- GitHub 이슈 생성은 항상 수행 (영구 기록 목적)
