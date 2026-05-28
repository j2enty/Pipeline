import { Probot, type ApplicationFunctionOptions } from "probot";
import { registerOnReviewSubmitted } from "./handlers/on-review-submitted";
import { startStatusPoller } from "./pollers/status-poller";
import { parsePollerConfigFromEnv } from "./lib/env";
import { notifyFailure } from "./lib/alert";
import { registerHealthcheck } from "./lib/healthcheck";
import {
  getLastTickAt,
  isPollerEnabled,
  setPollerEnabled,
} from "./lib/poller-state";

// 폴러 미가동 시 헬스체크에 노출할 기본 주기 (env 기본값과 동일하게 5분).
const DEFAULT_POLLER_INTERVAL_MS = 300000;

// Pipeline App — 이벤트 핸들러 등록 + 백그라운드 폴러 시작 진입점
//
// chain 결정 로직은 두 갈래로 분리:
//   - handlers/  : webhook 실시간 처리 (예: review submitted → critic dispatch)
//   - pollers/   : 정기 폴링 처리 (예: project status 변경 감지 → kickoff/review dispatch)
export default (app: Probot, { getRouter }: ApplicationFunctionOptions) => {
  app.log.info("Pipeline App 시작");

  // 미처리 webhook 에러 — 조용한 실패 방지용 알림 (best-effort).
  app.onError(async (err) => {
    await notifyFailure(app, {
      title: "미처리 webhook 에러",
      context: String(err),
    });
  });

  registerOnReviewSubmitted(app);
  const pollerIntervalMs = startStatusPollerFromEnv(app);

  // 헬스체크 라우터 등록 — 폴러 ↔ 헬스체크 공유 상태를 주입.
  registerHealthcheck(getRouter, () => ({
    getLastTickAt,
    isPollerEnabled,
    intervalMs: pollerIntervalMs,
  }));
};

// 환경변수 → StatusPoller 옵션 변환 후 시작
//
// 필수 환경변수가 없으면 폴러 비활성화 (App 자체는 기동 — webhook 핸들러는 작동).
//
// 파싱 판단(순수 로직)은 lib/env.ts 로 분리. 여기서는 결과에 따라
// 기존과 동일한 로그를 남기고 폴러를 시작하는 부수효과만 담당한다.
//
// 반환값: 헬스체크에 노출할 폴링 주기(ms). 비활성화 시 기본값을 돌려준다.
function startStatusPollerFromEnv(app: Probot): number {
  const result = parsePollerConfigFromEnv(process.env);

  if ("disabledReason" in result) {
    // 비활성화 — 폴러는 안 돌지만 App 자체는 기동 (헬스체크상 degraded 아님).
    setPollerEnabled(false);
    switch (result.disabledReason) {
      case "owner-missing":
        app.log.warn("OWNER 미설정 — Status 폴러 비활성화");
        return DEFAULT_POLLER_INTERVAL_MS;
      case "author-installation-id-missing":
        app.log.warn("AUTHOR_INSTALLATION_ID 미설정 — Status 폴러 비활성화");
        return DEFAULT_POLLER_INTERVAL_MS;
      case "parse-failed":
        app.log.error(
          {
            err: result.parseError,
            projectNumbersRaw: result.projectNumbersRaw,
            modulesRaw: result.modulesRaw,
          },
          "PROJECT_NUMBERS / MODULES 파싱 실패 — Status 폴러 비활성화"
        );
        return DEFAULT_POLLER_INTERVAL_MS;
      case "empty-arrays":
        app.log.warn(
          {
            projectNumbers: result.projectNumbers,
            modules: result.modules,
          },
          "PROJECT_NUMBERS 또는 MODULES 가 비어있음 — Status 폴러 비활성화"
        );
        return DEFAULT_POLLER_INTERVAL_MS;
    }
  }

  setPollerEnabled(true);
  startStatusPoller(app, result.config);
  return result.config.intervalMs;
}
