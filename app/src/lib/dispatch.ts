import { Octokit } from "@octokit/core";
import { createAppAuth } from "@octokit/auth-app";
import type { Probot } from "probot";
import { notifyFailure } from "./alert";

// repository_dispatch 이벤트 발사 옵션
export interface RepositoryDispatchOptions {
  owner: string;
  repo: string;
  eventType: string;
  clientPayload: Record<string, unknown>;
}

// Author 봇 자격의 Octokit 생성 — Probot 인증 우회
//
// Probot 의 app.auth() 는 Probot 이 시작된 App 자격으로만 토큰 발급 가능.
// Reviewer 봇 webhook 으로 진입한 핸들러에서 Author 봇 dispatch 를 발사하려면
// Author App 자격으로 직접 인증해야 한다.
function createAuthorOctokit(authorInstallationId: number): Octokit {
  const appId = process.env.APP_ID ?? process.env.AUTHOR_APP_ID;
  const privateKey = process.env.PRIVATE_KEY;

  if (!appId || !privateKey) {
    throw new Error(
      "Author 봇 인증 실패 — APP_ID/AUTHOR_APP_ID 또는 PRIVATE_KEY 미설정"
    );
  }

  return new Octokit({
    authStrategy: createAppAuth,
    auth: {
      appId: Number(appId),
      privateKey,
      installationId: authorInstallationId,
    },
  });
}

// repository_dispatch 발사 — 영역 레포의 호출자 yml 트리거
//
// DRY_RUN=true 환경변수 시 실제 발사 대신 로그만 찍음.
export async function fireRepositoryDispatch(
  app: Probot,
  authorInstallationId: number,
  options: RepositoryDispatchOptions
): Promise<void> {
  if (process.env.DRY_RUN === "true") {
    app.log.info(
      {
        owner: options.owner,
        repo: options.repo,
        eventType: options.eventType,
        clientPayload: options.clientPayload,
      },
      "DRY_RUN — dispatch 발사 skip (실제로는 보내지 않음)"
    );
    return;
  }

  const octokit = createAuthorOctokit(authorInstallationId);
  try {
    await octokit.request("POST /repos/{owner}/{repo}/dispatches", {
      owner: options.owner,
      repo: options.repo,
      event_type: options.eventType,
      client_payload: options.clientPayload,
    });
  } catch (err) {
    // 발사 실패 알림 후 re-throw — 상위(폴러 tick catch 등)가 기존 흐름 유지.
    await notifyFailure(app, {
      title: "dispatch 발사 실패",
      context: `${options.owner}/${options.repo} (${options.eventType}): ${String(err)}`,
    });
    throw err;
  }
}
