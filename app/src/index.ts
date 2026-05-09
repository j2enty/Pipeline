import { Probot } from "probot";

// Pipeline App — 이벤트 핸들러 등록
// chain 로직은 handlers/ 에서 모듈별로 분리
export default (app: Probot) => {
  app.log.info("Pipeline App 시작");

  // Phase 4-5 에서 핸들러 추가 예정:
  // - pull_request (opened, closed, synchronize)
  // - pull_request_review (submitted)
  // - issues (closed)
  // - projects_v2_item (edited) — Project status 변경 → dispatch
};
