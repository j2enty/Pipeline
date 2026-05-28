import { describe, it, expect } from "vitest";
import { extractParentUrlFromIssueBody } from "../src/lib/parent-extractor";

// extractParentUrlFromIssueBody — issue body 의 "Parent: <ref>" 라인에서
// parent issue URL 을 뽑아낸다. 한 동작당 하나의 it 로 검증한다.
describe("extractParentUrlFromIssueBody", () => {
  it("절대 URL 은 그대로 반환한다", () => {
    const body = "Parent: https://github.com/org/repo/issues/123";
    expect(extractParentUrlFromIssueBody(body)).toBe(
      "https://github.com/org/repo/issues/123"
    );
  });

  it("짧은 참조(org/repo#123)는 절대 URL 로 변환한다", () => {
    const body = "Parent: org/repo#123";
    expect(extractParentUrlFromIssueBody(body)).toBe(
      "https://github.com/org/repo/issues/123"
    );
  });

  it("Parent 라인이 없으면 null 을 반환한다", () => {
    const body = "이 이슈는 parent 가 없습니다.\n본문만 있어요.";
    expect(extractParentUrlFromIssueBody(body)).toBeNull();
  });

  it("Parent 형식이지만 ref 가 매칭 불가하면 null 을 반환한다", () => {
    // https:// 도 아니고 org/repo#num 패턴도 아닌 토큰
    const body = "Parent: 그냥문자열";
    expect(extractParentUrlFromIssueBody(body)).toBeNull();
  });

  it("Parent: 와 ref 사이 공백이 여러 칸이어도 추출한다", () => {
    const body = "Parent:     org/repo#7";
    expect(extractParentUrlFromIssueBody(body)).toBe(
      "https://github.com/org/repo/issues/7"
    );
  });

  it("본문 중간 라인에 Parent 가 있어도 추출한다", () => {
    const body = [
      "## 작업 내용",
      "어쩌고 저쩌고",
      "Parent: https://github.com/acme/web/issues/42",
      "마무리",
    ].join("\n");
    expect(extractParentUrlFromIssueBody(body)).toBe(
      "https://github.com/acme/web/issues/42"
    );
  });

  it("ref 는 첫 공백 전까지만 취한다 (뒤 텍스트 무시)", () => {
    // \S+ 매칭이라 공백 뒤 주석은 ref 에 포함되지 않는다
    const body = "Parent: org/repo#9 (부모 이슈)";
    expect(extractParentUrlFromIssueBody(body)).toBe(
      "https://github.com/org/repo/issues/9"
    );
  });
});
