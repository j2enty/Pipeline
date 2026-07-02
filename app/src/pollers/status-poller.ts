import type { Probot } from "probot";
import {
  fetchProjectV2Items,
  type ProjectV2ItemSnapshot,
} from "../lib/project-graphql";
import { extractParentUrlFromIssueBody } from "../lib/parent-extractor";
import { findOpenPullRequestUrlForIssue } from "../lib/sub-issue-pr";
import { isWorkflowFileInProgress } from "../lib/workflow-runs";
import { fireRepositoryDispatch } from "../lib/dispatch";
import { notifyFailure } from "../lib/alert";
import { recordTick } from "../lib/poller-state";

// 폴러 설정 — App 외부에서 환경변수 → 옵션 객체로 변환 후 주입
export interface StatusPollerOptions {
  ownerLogin: string;
  projectNumbers: number[];
  modules: string[];
  authorInstallationId: number;
  intervalMs: number;
  // 폴러가 kickoff/review 를 트리거할 Project v2 Status 컬럼값.
  // 프로젝트마다 컬럼명이 다를 수 있어 하드코딩하지 않고 주입받는다(#106 app-p5).
  // env 미설정 시 lib/env.ts 가 기본값("In Progress"/"Bot Review")을 채운다.
  statusTriggersKickoff: string;
  statusTriggersReview: string;
}

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
      // 트리거 컬럼명을 로그에 남긴다 — 컬럼명 오설정으로 폴러가 무음 정지할 때
      // 운영자가 "무슨 컬럼값을 보고 있었나"를 즉시 확인할 수 있게(#106 app-p5).
      statusTriggersKickoff: options.statusTriggersKickoff,
      statusTriggersReview: options.statusTriggersReview,
    },
    "Status 폴러 시작"
  );

  const tick = async (): Promise<void> => {
    try {
      await runPollingTick(app, options);
      // 성공 tick 시각 기록 — 헬스체크가 "살아있음" 판단에 사용.
      recordTick();
    } catch (err) {
      app.log.error({ err }, "Status 폴러 tick 실패 — 다음 tick 까지 대기");
      // tick 전체 실패만 알림 (부분 실패는 기존 로그 유지). 쿨다운이 스팸 방지.
      await notifyFailure(app, {
        title: "Status 폴러 tick 실패",
        context: String(err),
      });
    }
  };

  // 부팅 직후 즉시 1회 실행 후 interval 시작 (5분 대기 없이 빠른 첫 sync)
  void tick();
  return setInterval(() => void tick(), options.intervalMs);
}

// 매 tick 의 실제 작업 본체.
//
// 실패 처리 원칙 — "조용한 실패 → 시끄러운 실패":
//   - 프로젝트 '실패' 판정: (a) 조회 자체가 throw, 또는 (b) 조회는 성공했으나
//     아이템이 1건 이상인데 '전부' 처리 실패(진전 전무). 둘 다 프로젝트 실패로 집계.
//     부분 실패(일부 아이템만 throw)는 진전으로 보고 실패로 세지 않는다(오탐 금지).
//   - 프로젝트 '일부'만 실패 → 알림(쿨다운) + 로그 후 계속 (부분 실패는 tick 성공).
//   - 프로젝트 '전부' 실패 → throw 로 승격 → tick() 의 catch 가 잡아
//     recordTick() 을 건너뛰게 만든다. lastTickAt 이 정체되면 evaluateHealth 가
//     두 주기 뒤 'degraded' 로 승격 → 헬스체크가 무음 정지를 드러낸다.
//
// 이 함수는 테스트에서 직접 호출·검증하기 위해 export 한다.
export async function runPollingTick(
  app: Probot,
  options: StatusPollerOptions
): Promise<void> {
  let failedProjectCount = 0;

  for (const projectNumber of options.projectNumbers) {
    let items: ProjectV2ItemSnapshot[];
    try {
      items = await fetchProjectV2Items(
        app,
        options.authorInstallationId,
        { ownerLogin: options.ownerLogin, projectNumber }
      );
    } catch (err) {
      failedProjectCount += 1;
      app.log.error(
        { err, projectNumber },
        "Project v2 조회 실패 — 다른 프로젝트 계속 진행"
      );
      // 프로젝트별 알림 — 쿨다운 키를 프로젝트 단위로 분리해 한 프로젝트의
      // 지속 실패가 다른 프로젝트 알림을 삼키지 않게 한다.
      await notifyFailure(app, {
        title: "Project v2 조회 실패",
        context: `projectNumber=${projectNumber} ${String(err)}`,
        key: `project-fetch-fail-${projectNumber}`,
      });
      continue;
    }

    app.log.debug(
      { projectNumber, itemCount: items.length },
      "Project 아이템 조회"
    );

    // 아이템별 처리 실패 집계 — "조회는 성공했지만 그 프로젝트의 모든 아이템이
    // 처리 실패"하는 무음 정지를 잡기 위함. 부분 실패(일부만 throw)는 진전으로
    // 보고 프로젝트 실패로 세지 않는다(오탐 금지).
    let processFailureCount = 0;
    for (const item of items) {
      try {
        await processProjectItem(app, options, item);
      } catch (err) {
        processFailureCount += 1;
        app.log.error(
          { err, itemNodeId: item.itemNodeId },
          "아이템 처리 실패 — 다음 아이템 계속"
        );
      }
    }

    // 아이템이 1건 이상인데 전부 처리 실패 → 이 프로젝트는 진전이 전무 → 실패로 승격.
    // (아이템 0개 = 할 일 없음 = 정상 진전, 1건이라도 성공 = 진전 있음 → 실패 아님)
    if (items.length > 0 && processFailureCount === items.length) {
      failedProjectCount += 1;
      app.log.error(
        { projectNumber, itemCount: items.length },
        "Project 항목 전부 처리 실패 — 프로젝트 실패로 승격"
      );
      await notifyFailure(app, {
        title: "Project 항목 전부 처리 실패",
        context: `projectNumber=${projectNumber} items=${items.length} 전부 처리 실패`,
        key: `project-process-fail-${projectNumber}`,
      });
    }
  }

  // 전 프로젝트 실패(조회 실패 또는 항목 전부 처리 실패) → tick 실패로 승격
  // (recordTick 스킵 유도 → degraded).
  if (
    options.projectNumbers.length > 0 &&
    failedProjectCount === options.projectNumbers.length
  ) {
    throw new Error(
      `전 프로젝트(${failedProjectCount}/${options.projectNumbers.length}) 실패 — tick 실패로 승격`
    );
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

  if (item.status === options.statusTriggersKickoff) {
    await dispatchKickoffIfNotRunning(app, options, item);
  } else if (item.status === options.statusTriggersReview) {
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
