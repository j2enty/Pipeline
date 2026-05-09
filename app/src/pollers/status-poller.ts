import type { Probot } from "probot";
import {
  fetchProjectV2ItemsForOrganization,
  type ProjectV2ItemSnapshot,
} from "../lib/project-graphql";
import { extractParentUrlFromIssueBody } from "../lib/parent-extractor";
import { findOpenPullRequestUrlForIssue } from "../lib/sub-issue-pr";
import { isWorkflowFileInProgress } from "../lib/workflow-runs";
import { fireRepositoryDispatch } from "../lib/dispatch";

// 폴러 설정 — App 외부에서 환경변수 → 옵션 객체로 변환 후 주입
export interface StatusPollerOptions {
  ownerLogin: string;
  projectNumbers: number[];
  modules: string[];
  authorInstallationId: number;
  intervalMs: number;
}

// Project v2 Status 필드 표준값
const STATUS_TRIGGERS_KICKOFF = "In Progress";
const STATUS_TRIGGERS_REVIEW = "Bot Review";

const WORKFLOW_FILE_KICKOFF = "auto-kickoff.yml";
const WORKFLOW_FILE_REVIEW = "auto-review.yml";

const EVENT_KICKOFF = "kickoff-triggered";
const EVENT_REVIEW = "review-triggered";

// 폴러 시작 — setInterval 핸들 반환 (테스트/종료 시 clearInterval 가능)
//
// 매 tick:
//   1. 등록된 모든 Project v2 아이템 조회 (배열 순회)
//   2. 각 아이템 → MODULES 에 포함된 영역 레포만 처리
//   3. Status 별 dispatch (이미 실행 중이면 스킵)
//
// tick 단위 에러는 잡아서 다음 tick 으로 흘려보냄 (한 tick 실패가 폴러 전체를 죽이지 않게).
export function startStatusPoller(
  app: Probot,
  options: StatusPollerOptions
): NodeJS.Timeout {
  app.log.info(
    {
      ownerLogin: options.ownerLogin,
      projectNumbers: options.projectNumbers,
      modules: options.modules,
      intervalMs: options.intervalMs,
    },
    "Status 폴러 시작"
  );

  const tick = async (): Promise<void> => {
    try {
      await runPollingTick(app, options);
    } catch (err) {
      app.log.error({ err }, "Status 폴러 tick 실패 — 다음 tick 까지 대기");
    }
  };

  // 부팅 직후 즉시 1회 실행 후 interval 시작 (5분 대기 없이 빠른 첫 sync)
  void tick();
  return setInterval(() => void tick(), options.intervalMs);
}

async function runPollingTick(
  app: Probot,
  options: StatusPollerOptions
): Promise<void> {
  for (const projectNumber of options.projectNumbers) {
    let items: ProjectV2ItemSnapshot[];
    try {
      items = await fetchProjectV2ItemsForOrganization(
        app,
        options.authorInstallationId,
        { ownerLogin: options.ownerLogin, projectNumber }
      );
    } catch (err) {
      app.log.error(
        { err, projectNumber },
        "Project v2 조회 실패 — 다른 프로젝트 계속 진행"
      );
      continue;
    }

    app.log.debug(
      { projectNumber, itemCount: items.length },
      "Project 아이템 조회"
    );

    for (const item of items) {
      try {
        await processProjectItem(app, options, item);
      } catch (err) {
        app.log.error(
          { err, itemNodeId: item.itemNodeId },
          "아이템 처리 실패 — 다음 아이템 계속"
        );
      }
    }
  }
}

async function processProjectItem(
  app: Probot,
  options: StatusPollerOptions,
  item: ProjectV2ItemSnapshot
): Promise<void> {
  if (!item.issue) return;
  if (item.issue.state === "CLOSED") return;
  if (!options.modules.includes(item.issue.repositoryName)) return;

  if (item.status === STATUS_TRIGGERS_KICKOFF) {
    await dispatchKickoffIfNotRunning(app, options, item);
  } else if (item.status === STATUS_TRIGGERS_REVIEW) {
    await dispatchReviewIfNotRunning(app, options, item);
  }
}

async function dispatchKickoffIfNotRunning(
  app: Probot,
  options: StatusPollerOptions,
  item: ProjectV2ItemSnapshot
): Promise<void> {
  const issue = item.issue!;
  const parentUrl = extractParentUrlFromIssueBody(issue.body);
  if (!parentUrl) {
    app.log.debug(
      { repo: issue.repositoryName, issue: issue.number },
      "kickoff 대상이지만 parent URL 추출 실패 — skip"
    );
    return;
  }

  const isRunning = await isWorkflowFileInProgress(
    app,
    options.authorInstallationId,
    {
      owner: issue.repositoryOwner,
      repo: issue.repositoryName,
      workflowFileName: WORKFLOW_FILE_KICKOFF,
    }
  );
  if (isRunning) {
    app.log.debug(
      { repo: issue.repositoryName, issue: issue.number },
      "auto-kickoff 실행 중 — skip"
    );
    return;
  }

  await fireRepositoryDispatch(app, options.authorInstallationId, {
    owner: issue.repositoryOwner,
    repo: issue.repositoryName,
    eventType: EVENT_KICKOFF,
    clientPayload: { parent_url: parentUrl },
  });

  app.log.info(
    {
      repo: issue.repositoryName,
      issue: issue.number,
      parentUrl,
    },
    "kickoff-triggered dispatch"
  );
}

async function dispatchReviewIfNotRunning(
  app: Probot,
  options: StatusPollerOptions,
  item: ProjectV2ItemSnapshot
): Promise<void> {
  const issue = item.issue!;
  const parentUrl = extractParentUrlFromIssueBody(issue.body);
  if (!parentUrl) {
    app.log.debug(
      { repo: issue.repositoryName, issue: issue.number },
      "review 대상이지만 parent URL 추출 실패 — skip"
    );
    return;
  }

  const prUrl = await findOpenPullRequestUrlForIssue(
    app,
    options.authorInstallationId,
    {
      owner: issue.repositoryOwner,
      repo: issue.repositoryName,
      issueNumber: issue.number,
    }
  );
  if (!prUrl) {
    app.log.debug(
      { repo: issue.repositoryName, issue: issue.number },
      "review 대상이지만 OPEN PR 없음 — skip"
    );
    return;
  }

  const isRunning = await isWorkflowFileInProgress(
    app,
    options.authorInstallationId,
    {
      owner: issue.repositoryOwner,
      repo: issue.repositoryName,
      workflowFileName: WORKFLOW_FILE_REVIEW,
    }
  );
  if (isRunning) {
    app.log.debug(
      { repo: issue.repositoryName, issue: issue.number },
      "auto-review 실행 중 — skip"
    );
    return;
  }

  await fireRepositoryDispatch(app, options.authorInstallationId, {
    owner: issue.repositoryOwner,
    repo: issue.repositoryName,
    eventType: EVENT_REVIEW,
    clientPayload: { pr_url: prUrl, parent_url: parentUrl },
  });

  app.log.info(
    {
      repo: issue.repositoryName,
      issue: issue.number,
      prUrl,
      parentUrl,
    },
    "review-triggered dispatch"
  );
}
