import type { Probot } from "probot";

// repository_dispatch 이벤트 발사 옵션
export interface RepositoryDispatchOptions {
  owner: string;
  repo: string;
  eventType: string;
  clientPayload: Record<string, unknown>;
}

// repository_dispatch 발사 — 영역 레포의 호출자 yml 트리거
//
// dispatch 권한은 Author 봇만 보유. Reviewer 봇 webhook이 들어와도 dispatch는
// Author 봇 인증으로 발사해야 하므로 installation ID 를 받아서 새 토큰 발급.
export async function fireRepositoryDispatch(
  app: Probot,
  authorInstallationId: number,
  options: RepositoryDispatchOptions
): Promise<void> {
  const octokit = await app.auth(authorInstallationId);
  await octokit.request("POST /repos/{owner}/{repo}/dispatches", {
    owner: options.owner,
    repo: options.repo,
    event_type: options.eventType,
    client_payload: options.clientPayload,
  });
}
