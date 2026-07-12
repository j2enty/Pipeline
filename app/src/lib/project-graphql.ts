import type { Probot } from "probot";

// Project v2 아이템 한 개의 정규화된 표현
export interface ProjectV2ItemSnapshot {
  itemNodeId: string;
  status: string;
  issue: {
    number: number;
    state: string;
    body: string;
    repositoryName: string;
    repositoryOwner: string;
  } | null;
}

interface ProjectQueryResponse {
  repositoryOwner: {
    projectV2: {
      items: {
        nodes: Array<{
          id: string;
          content:
            | {
                number?: number;
                state?: string;
                body?: string;
                repository?: {
                  name: string;
                  owner: { login: string };
                };
              }
            | null;
          fieldValues: {
            nodes: Array<{
              name?: string;
              field?: { name?: string };
            }>;
          };
        }>;
      };
    } | null;
  } | null;
}

// Project v2 아이템 50개 일괄 조회 + Status 필드 정규화
//
// owner 가 organization 이든 user 든 모두 지원한다.
// repositoryOwner(login:) 는 Organization·User 둘 다 반환하는 인터페이스이고,
// 두 타입 모두 ProjectV2Owner 인터페이스(projectV2 보유)를 구현하므로
// inline fragment 로 양쪽을 동일하게 커버한다.
// Status 필드 이름은 "Status" 고정 (Project v2 표준).
export async function fetchProjectV2Items(
  app: Probot,
  authorInstallationId: number,
  options: { ownerLogin: string; projectNumber: number }
): Promise<ProjectV2ItemSnapshot[]> {
  const octokit = await app.auth(authorInstallationId);
  const result = await octokit.graphql<ProjectQueryResponse>(
    `
    query($login: String!, $number: Int!) {
      repositoryOwner(login: $login) {
        ... on ProjectV2Owner {
          projectV2(number: $number) {
              items(first: 50) {
              nodes {
                id
                content {
                  ... on Issue {
                    number
                    state
                    body
                    repository {
                      name
                      owner { login }
                    }
                  }
                }
                fieldValues(first: 10) {
                  nodes {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      name
                      field { ... on ProjectV2FieldCommon { name } }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    `,
    { login: options.ownerLogin, number: options.projectNumber }
  );

  const rawNodes = result.repositoryOwner?.projectV2?.items?.nodes ?? [];

  return rawNodes.map((node) => {
    const statusFieldValue = node.fieldValues.nodes.find(
      (fv) => fv.field?.name === "Status"
    );
    const repository = node.content?.repository;
    return {
      itemNodeId: node.id,
      status: statusFieldValue?.name ?? "",
      issue: repository
        ? {
            number: node.content?.number ?? 0,
            state: node.content?.state ?? "",
            body: node.content?.body ?? "",
            repositoryName: repository.name,
            repositoryOwner: repository.owner.login,
          }
        : null,
    };
  });
}

// Project v2 아이템 한 개의 Status(단일 선택 필드) 값을 optionId 로 전환한다.
//
// fetchProjectV2Items 와 동일하게 Author 봇(authorInstallationId) 권한으로 실행한다.
// updateProjectV2ItemFieldValue mutation — singleSelectOptionId 로 Status 컬럼을 옮긴다.
// projectId/itemId/fieldId/optionId 는 전부 호출부(Janus 콜백 value)가 검증해 넘긴다.
export async function updateProjectV2ItemStatus(
  app: Probot,
  authorInstallationId: number,
  params: {
    projectId: string;
    itemId: string;
    fieldId: string;
    optionId: string;
  }
): Promise<void> {
  const octokit = await app.auth(authorInstallationId);
  await octokit.graphql(
    `
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { singleSelectOptionId: $optionId }
        }
      ) {
        projectV2Item { id }
      }
    }
    `,
    {
      projectId: params.projectId,
      itemId: params.itemId,
      fieldId: params.fieldId,
      optionId: params.optionId,
    }
  );
}
