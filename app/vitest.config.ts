import { defineConfig } from "vitest/config";

// 단위 테스트 설정 — 순수 로직(파서·집계·env)만 노드 환경에서 검증.
// 컴파일 산출물(lib/)·node_modules 는 테스트 수집 대상에서 제외.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    exclude: ["node_modules", "lib"],
  },
});
