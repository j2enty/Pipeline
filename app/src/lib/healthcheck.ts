import type { ApplicationFunctionOptions } from "probot";

// 헬스체크 — App 이 살아있는지 + 폴러가 실제로 돌고 있는지 외부에서 확인
//
// Docker HEALTHCHECK / 외부 cron(healthcheck-watch.sh) 이 GET /health 로 찔러
// 상태를 본다. status 판단은 순수 함수(evaluateHealth)로 분리해 단위 테스트 가능.

// 헬스 판단 (순수 함수).
//
//   - lastTickAt 이 null → 폴러 미가동 환경 → "ok" (degraded 아님).
//     (폴러가 꺼진 건 정상 운영 형태일 수 있다 — env 조건 미충족 등)
//   - now - lastTickAt > intervalMs * 2 → tick 이 두 주기 넘게 끊김 → "degraded".
//   - 그 외 → "ok".
export function evaluateHealth(
  lastTickAt: number | null,
  intervalMs: number,
  now: number
): "ok" | "degraded" {
  if (lastTickAt === null) {
    return "ok";
  }
  if (now - lastTickAt > intervalMs * 2) {
    return "degraded";
  }
  return "ok";
}

// 헬스체크 상태 스냅샷 제공자 — index.ts 가 공유 상태/폴러 설정을 주입.
export interface HealthStateProvider {
  getLastTickAt: () => number | null;
  isPollerEnabled: () => boolean;
  intervalMs: number;
}

// 헬스체크 라우터 등록.
//
//   GET /health → { status, uptime, lastPollTickAt, pollerEnabled } JSON.
//   status 는 evaluateHealth 결과 (degraded 여도 HTTP 200 — 정보 노출용 엔드포인트).
//
// getRouter 가 없으면(테스트/임베드 환경) 조용히 스킵.
export function registerHealthcheck(
  getRouter: ApplicationFunctionOptions["getRouter"],
  getState: () => HealthStateProvider
): void {
  if (!getRouter) {
    return;
  }

  const router = getRouter("/health");
  router.get("/", (_req, res) => {
    const state = getState();
    const status = evaluateHealth(
      state.getLastTickAt(),
      state.intervalMs,
      Date.now()
    );
    res.json({
      status,
      uptime: process.uptime(),
      lastPollTickAt: state.getLastTickAt(),
      pollerEnabled: state.isPollerEnabled(),
    });
  });
}
