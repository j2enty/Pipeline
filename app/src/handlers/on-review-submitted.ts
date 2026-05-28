import type { Probot } from "probot";
import { aggregateSiblingApprovalStatus } from "../lib/github";
import { fireRepositoryDispatch } from "../lib/dispatch";
import { notifyFailure } from "../lib/alert";

// pull_request_review.submitted 핸들러 등록
//
// 트리거: Reviewer 봇이 PR 에 APPROVE 리뷰 제출
// 결정 로직:
//   1. APPROVED 가 아니면 skip
//   2. Reviewer 봇 작성이 아니면 skip
//   3. 같은 parent 의 모든 sibling 이 APPROVED 인지 GraphQL 일괄 조회
//   4. 모두 APPROVED → critic-triggered dispatch 발사
//
// dispatch 대상: PR 레포 (auto-critic-dispatch.yml 이 받음)
export function registerOnReviewSubmitted(app: Probot): void {
  app.on("pull_request_review.submitted", async (context) => {
    const { review, pull_request: pullRequest, repository } = context.payload;

    // 1. APPROVED 만 처리
    if (review.state !== "approved") {
      app.log.debug(
        { reviewState: review.state, prUrl: pullRequest.html_url },
        "review state APPROVED 아님 — skip"
      );
      return;
    }

    // 2. Reviewer 봇 검증 — `[bot]` suffix 제거 후 prefix 비교
    const reviewerBotLoginEnv = process.env.REVIEWER_BOT_LOGIN ?? "";
    const reviewerBotLoginPrefix = reviewerBotLoginEnv.replace(/\[bot\]$/, "");
    if (!reviewerBotLoginPrefix) {
      app.log.warn(
        "REVIEWER_BOT_LOGIN 미설정 — review 핸들러 skip (AI 리뷰 미사용 환경?)"
      );
      return;
    }
    const reviewAuthorLogin = review.user?.login ?? "";
    if (!reviewAuthorLogin.startsWith(reviewerBotLoginPrefix)) {
      app.log.debug(
        { reviewAuthor: reviewAuthorLogin },
        "Reviewer 봇이 아님 — skip"
      );
      return;
    }

    // 3. sibling APPROVED 집계
    let modulesIgnore: string[] = [];
    try {
      modulesIgnore = JSON.parse(process.env.MODULES_IGNORE ?? "[]");
    } catch (err) {
      app.log.warn({ err }, "MODULES_IGNORE 파싱 실패 — 빈 배열로 처리");
    }

    const siblingStatus = await aggregateSiblingApprovalStatus(context, {
      prOwner: repository.owner.login,
      prRepo: repository.name,
      prNumber: pullRequest.number,
      reviewerBotLoginPrefix,
      modulesIgnore,
    });

    if (!siblingStatus) {
      app.log.info(
        { prUrl: pullRequest.html_url },
        "PR 이 sub-issue 를 닫지 않거나 parent 없음 — skip"
      );
      return;
    }

    app.log.info(
      {
        parentUrl: siblingStatus.parentUrl,
        approved: `${siblingStatus.approvedSiblings}/${siblingStatus.totalSiblings}`,
      },
      "sibling APPROVED 상태 집계"
    );

    // 단일 영역 → critic 불필요
    if (siblingStatus.totalSiblings <= 1) {
      app.log.info(
        { parentUrl: siblingStatus.parentUrl },
        "단일 영역 — critic 불필요"
      );
      return;
    }

    // 일부만 APPROVED → 다른 sibling 의 APPROVE 대기
    if (siblingStatus.approvedSiblings < siblingStatus.totalSiblings) {
      app.log.info(
        { parentUrl: siblingStatus.parentUrl },
        "일부 sibling 만 APPROVED — 대기"
      );
      return;
    }

    // 4. 모두 APPROVED → critic-triggered dispatch
    const authorInstallationIdRaw = process.env.AUTHOR_INSTALLATION_ID;
    if (!authorInstallationIdRaw) {
      app.log.error("AUTHOR_INSTALLATION_ID 미설정 — dispatch 발사 불가");
      await notifyFailure(app, {
        title: "review 핸들러 dispatch 불가",
        context: "AUTHOR_INSTALLATION_ID 미설정 — critic-triggered dispatch 발사 불가",
        url: pullRequest.html_url,
      });
      return;
    }
    const authorInstallationId = Number(authorInstallationIdRaw);

    await fireRepositoryDispatch(app, authorInstallationId, {
      owner: repository.owner.login,
      repo: repository.name,
      eventType: "critic-triggered",
      clientPayload: { parent_url: siblingStatus.parentUrl },
    });

    app.log.info(
      {
        parentUrl: siblingStatus.parentUrl,
        dispatchTarget: `${repository.owner.login}/${repository.name}`,
      },
      "critic-triggered dispatch 발사 완료"
    );
  });
}
