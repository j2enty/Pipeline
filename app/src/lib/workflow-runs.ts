import type { Probot } from "probot";

// 특정 workflow yml 이 in_progress 인지 확인 (중복 dispatch 방지용)
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
    const result = await octokit.rest.actions.listWorkflowRuns({
      owner: options.owner,
      repo: options.repo,
      workflow_id: options.workflowFileName,
      status: "in_progress",
      per_page: 1,
    });
    return result.data.total_count > 0;
  } catch (err) {
    app.log.debug(
      { err, ...options },
      "workflow run 조회 실패 — false 로 폴백 (dispatch 진행)"
    );
    return false;
  }
}
