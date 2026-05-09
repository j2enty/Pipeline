// issue.body 안의 "Parent: <ref>" 라인에서 parent issue URL 추출
//
// 지원하는 ref 포맷:
//   - 절대 URL: https://github.com/org/repo/issues/123
//   - 짧은 참조: org/repo#123
//
// 매칭 실패 시 null 반환.
export function extractParentUrlFromIssueBody(
  issueBody: string
): string | null {
  const parentLineMatch = issueBody.match(/Parent:\s*(\S+)/);
  if (!parentLineMatch) return null;

  const rawRef = parentLineMatch[1];

  if (rawRef.startsWith("https://")) {
    return rawRef;
  }

  const shortRefMatch = rawRef.match(/^([^/]+)\/([^#]+)#(\d+)$/);
  if (shortRefMatch) {
    const [, owner, repo, number] = shortRefMatch;
    return `https://github.com/${owner}/${repo}/issues/${number}`;
  }

  return null;
}
