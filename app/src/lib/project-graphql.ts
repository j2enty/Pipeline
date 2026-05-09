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
  organization: {
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
// Project 가 organization 소속이라고 가정 (user 소속 Project 는 GraphQL 쿼리가 다름).
// Status 필드 이름은 "Status" 고정 (Project v2 표준).
export async function fetchProjectV2ItemsForOrganization(
  app: Probot,
  authorInstallationId: number,
  options: { ownerLogin: string; projectNumber: number }
): Promise<ProjectV2ItemSnapshot[]> {
  const octokit = await app.auth(authorInstallationId);
  const result = await octokit.graphql<ProjectQueryResponse>(
    `
    query($login: String!, $number: Int!) {
      organization(login: $login) {
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
    `,
    { login: options.ownerLogin, number: options.projectNumber }
  );

  const rawNodes = result.organization?.projectV2?.items?.nodes ?? [];

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
