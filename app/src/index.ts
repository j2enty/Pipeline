import { Probot } from "probot";
import { registerOnReviewSubmitted } from "./handlers/on-review-submitted";
import { startStatusPoller } from "./pollers/status-poller";
import { parsePollerConfigFromEnv } from "./lib/env";

// Pipeline App — 이벤트 핸들러 등록 + 백그라운드 폴러 시작 진입점
//
// chain 결정 로직은 두 갈래로 분리:
//   - handlers/  : webhook 실시간 처리 (예: review submitted → critic dispatch)
//   - pollers/   : 정기 폴링 처리 (예: project status 변경 감지 → kickoff/review dispatch)
export default (app: Probot) => {
  app.log.info("Pipeline App 시작");

  registerOnReviewSubmitted(app);
  startStatusPollerFromEnv(app);
};

// 환경변수 → StatusPoller 옵션 변환 후 시작
//
// 필수 환경변수가 없으면 폴러 비활성화 (App 자체는 기동 — webhook 핸들러는 작동).
//
// 파싱 판단(순수 로직)은 lib/env.ts 로 분리. 여기서는 결과에 따라
// 기존과 동일한 로그를 남기고 폴러를 시작하는 부수효과만 담당한다.
function startStatusPollerFromEnv(app: Probot): void {
  const result = parsePollerConfigFromEnv(process.env);

  if ("disabledReason" in result) {
    switch (result.disabledReason) {
      case "owner-missing":
        app.log.warn("OWNER 미설정 — Status 폴러 비활성화");
        return;
      case "author-installation-id-missing":
        app.log.warn("AUTHOR_INSTALLATION_ID 미설정 — Status 폴러 비활성화");
        return;
      case "parse-failed":
        app.log.error(
          {
            err: result.parseError,
            projectNumbersRaw: result.projectNumbersRaw,
            modulesRaw: result.modulesRaw,
          },
          "PROJECT_NUMBERS / MODULES 파싱 실패 — Status 폴러 비활성화"
        );
        return;
      case "empty-arrays":
        app.log.warn(
          {
            projectNumbers: result.projectNumbers,
            modules: result.modules,
          },
          "PROJECT_NUMBERS 또는 MODULES 가 비어있음 — Status 폴러 비활성화"
        );
        return;
    }
  }

  startStatusPoller(app, result.config);
}
