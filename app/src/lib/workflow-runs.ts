import type { Probot } from "probot";

// 특정 workflow yml 이 in_progress 또는 queued 인지 확인 (중복 dispatch 방지용)
//
// in_progress 뿐 아니라 queued(시작 대기 중) 상태도 체크 — runner 가 없어 대기 중인
// run 을 감지 못해 중복 dispatch 되던 버그(#19) 수정.
//
// workflow 가 없거나 권한 부족 등으로 조회 실패 시 false 반환 → 폴러는 dispatch 시도.
// "안전한 false" 정책: 중복은 yml 멱등성으로 흡수, 미실행보다는 중복 실행이 낫다.
export async function isWorkflowFileInProgress(
  app: Probot,
  authorInstallationId: number,
  options: { owner: string; repo: string; workflowFileName: string }
): Promise<boolean> {
  const octokit = await app.auth(authorInstallationId);

  try {
    const [inProgress, queued] = await Promise.all([
      octokit.rest.actions.listWorkflowRuns({
        owner: options.owner,
        repo: options.repo,
        workflow_id: options.workflowFileName,
        status: "in_progress",
        per_page: 1,
      }),
      octokit.rest.actions.listWorkflowRuns({
        owner: options.owner,
        repo: options.repo,
        workflow_id: options.workflowFileName,
        status: "queued",
        per_page: 1,
      }),
    ]);
    return inProgress.data.total_count > 0 || queued.data.total_count > 0;
  } catch (err) {
    app.log.debug(
      { err, ...options },
      "workflow run 조회 실패 — false 로 폴백 (dispatch 진행)"
    );
    return false;
  }
}
