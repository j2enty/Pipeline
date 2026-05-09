import { Probot } from "probot";
import { registerOnReviewSubmitted } from "./handlers/on-review-submitted";

// Pipeline App — 이벤트 핸들러 등록 진입점
//
// chain 결정 로직은 handlers/ 와 pollers/ 로 분리:
//   - handlers/  : webhook 실시간 처리 (예: review submitted → critic dispatch)
//   - pollers/   : 정기 폴링 처리 (예: project status 변경 감지) — 향후 추가
export default (app: Probot) => {
  app.log.info("Pipeline App 시작");
  registerOnReviewSubmitted(app);
};
