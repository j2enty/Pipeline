import { run } from "probot";
import fs from "fs";
import app from "./index";

// Probot 표준 변수명으로 매핑
if (!process.env.APP_ID && process.env.AUTHOR_APP_ID) {
  process.env.APP_ID = process.env.AUTHOR_APP_ID;
}
if (!process.env.PRIVATE_KEY && process.env.AUTHOR_PEM) {
  process.env.PRIVATE_KEY = fs.readFileSync(process.env.AUTHOR_PEM, "utf8");
}

run(app);
