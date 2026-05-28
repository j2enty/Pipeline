import { run, type Probot } from "probot";
import fs from "fs";
import app from "./index";
import { notifyFailure } from "./lib/alert";

// Probot 표준 변수명으로 매핑
if (!process.env.APP_ID && process.env.AUTHOR_APP_ID) {
  process.env.APP_ID = process.env.AUTHOR_APP_ID;
}
if (!process.env.PRIVATE_KEY && process.env.AUTHOR_PEM) {
  process.env.PRIVATE_KEY = fs.readFileSync(process.env.AUTHOR_PEM, "utf8");
}

// 프로세스 레벨 치명적 에러 — Probot app 컨텍스트 밖에서 발생하므로
// notifyFailure 가 요구하는 log 인터페이스(warn/debug)만 갖춘 콘솔 백업 shim 을 쓴다.
const processLevelApp = {
  log: {
    warn: (...args: unknown[]) => console.warn(...args),
    debug: (...args: unknown[]) => console.debug(...args),
  },
} as unknown as Probot;

// 치명적 에러 → best-effort 알림 후 종료.
// docker restart:unless-stopped 가 재기동을 받아 "죽은 채 방치" 를 막는다.
function exitOnFatalError(title: string, err: unknown): void {
  // 알림은 best-effort — 실패해도(그리고 끝나기 전에라도) 반드시 종료한다.
  void notifyFailure(processLevelApp, { title, context: String(err) }).finally(
    () => process.exit(1)
  );
}

process.on("unhandledRejection", (reason) => {
  console.error("unhandledRejection:", reason);
  exitOnFatalError("미처리 Promise rejection", reason);
});

process.on("uncaughtException", (err) => {
  console.error("uncaughtException:", err);
  exitOnFatalError("미처리 예외 (uncaughtException)", err);
});

run(app);
