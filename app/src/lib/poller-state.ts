// 폴러 ↔ 헬스체크 공유 상태
//
// 폴러는 성공 tick마다 시각을 기록하고, 헬스체크 라우터는 그 시각을 읽어
// "살아있음"을 판단한다. 두 모듈이 직접 의존하지 않도록 이 모듈을 사이에 둔다.
//
// 전역 가변 상태는 모듈 내부에 캡슐화하고, 외부에는 명시적 접근자만 노출한다.

// 마지막 성공 tick 시각 (epoch ms). 아직 한 번도 tick이 없으면 null.
let lastTickAtMs: number | null = null;

// 폴러가 실제로 가동됐는지 (env 조건 미충족 시 false 유지).
let pollerEnabled = false;

// 성공 tick 시각 기록 — status-poller 가 매 성공 tick 마다 호출.
export function recordTick(nowMs: number = Date.now()): void {
  lastTickAtMs = nowMs;
}

// 마지막 성공 tick 시각 조회 — 헬스체크가 살아있음 판단에 사용.
export function getLastTickAt(): number | null {
  return lastTickAtMs;
}

// 폴러 가동 여부 설정 — index.ts 가 폴러를 실제로 시작할 때 true 로 표시.
export function setPollerEnabled(enabled: boolean): void {
  pollerEnabled = enabled;
}

// 폴러 가동 여부 조회.
export function isPollerEnabled(): boolean {
  return pollerEnabled;
}

// 테스트 격리용 — 모듈 내부 상태를 초기값으로 되돌린다.
export function resetPollerStateForTest(): void {
  lastTickAtMs = null;
  pollerEnabled = false;
}
