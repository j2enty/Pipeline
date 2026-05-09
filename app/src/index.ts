import { Probot } from "probot";
import { registerOnReviewSubmitted } from "./handlers/on-review-submitted";
import { startStatusPoller } from "./pollers/status-poller";

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
function startStatusPollerFromEnv(app: Probot): void {
  const ownerLogin = process.env.OWNER ?? "";
  const projectNumbersRaw = process.env.PROJECT_NUMBERS ?? "[]";
  const modulesRaw = process.env.MODULES ?? "[]";
  const authorInstallationIdRaw = process.env.AUTHOR_INSTALLATION_ID ?? "";
  const intervalMs = Number(process.env.STATUS_POLLER_INTERVAL_MS ?? "300000");

  if (!ownerLogin) {
    app.log.warn("OWNER 미설정 — Status 폴러 비활성화");
    return;
  }
  if (!authorInstallationIdRaw) {
    app.log.warn("AUTHOR_INSTALLATION_ID 미설정 — Status 폴러 비활성화");
    return;
  }

  let projectNumbers: number[];
  let modules: string[];
  try {
    projectNumbers = JSON.parse(projectNumbersRaw);
    modules = JSON.parse(modulesRaw);
  } catch (err) {
    app.log.error(
      { err, projectNumbersRaw, modulesRaw },
      "PROJECT_NUMBERS / MODULES 파싱 실패 — Status 폴러 비활성화"
    );
    return;
  }

  if (projectNumbers.length === 0 || modules.length === 0) {
    app.log.warn(
      { projectNumbers, modules },
      "PROJECT_NUMBERS 또는 MODULES 가 비어있음 — Status 폴러 비활성화"
    );
    return;
  }

  startStatusPoller(app, {
    ownerLogin,
    projectNumbers,
    modules,
    authorInstallationId: Number(authorInstallationIdRaw),
    intervalMs,
  });
}
