import crypto from "crypto";
import express from "express";
import type { Request, Response } from "express";
import type { ApplicationFunctionOptions, Probot } from "probot";
import { updateProjectV2ItemStatus } from "./project-graphql";
import {
  notifyFailure,
  resolveJanusTarget,
  sendJanusMessageUpdate,
  type JanusMessageTarget,
} from "./alert";

// Janus 콜백 수신부 — 사용자가 Slack 버튼을 1탭 하면 Janus(외부 게이트웨이)가
// 그 인터랙션을 HMAC 서명해 이 App 의 POST /janus/callback 으로 콜백해준다.
//
// 프론트로 치면: 예전엔 우리가 직접 Slack 소켓을 구독했다면, 이제 게이트웨이(Janus)가
// 소켓을 쥐고 버튼 클릭을 우리 웹훅 엔드포인트로 콜백하는 구조다(리스너 → 웹훅 전환).
//
// 참조: hermes-agent gateway/platforms/janus_callback_server.py (Python 원형). 이 모듈은
// 그 서명 스킴만 재현하고 Janus 코드를 import 하지 않는다(독립 모듈 원칙).
//
// 보안 3원칙:
//   1. fail-closed — 서명 시크릿(JANUS_CALLBACK_SIGNING_SECRET) 미설정 시 라우트를
//      아예 등록하지 않는다. 미검증 엔드포인트를 공개하지 않기 위함.
//   2. 위조·손상 요청("서명 불일치·stale·깨진 JSON") → 그 자리서 401/400.
//   3. 진짜지만 처리 불가한 요청("관심 없는 kind·미지원 action·value 검증 실패")
//      → 200 ack 후 무시(+관측 로그). Janus 재시도 폭주를 막기 위해 4xx 를 쓰지 않는다.

// ── Janus 서명 계약(hermes/Janus signing 과 동일해야 함) ─────────────────
// 헤더명·버전 태그가 어긋나면 모든 콜백이 401 로 떨어진다.
const SIGNATURE_HEADER = "x-janus-signature";
const TIMESTAMP_HEADER = "x-janus-timestamp";
const SIGNATURE_VERSION_PREFIX = "v0=";

// replay 윈도우 기본값(초). JANUS_CALLBACK_REPLAY_WINDOW_S env 로 조정.
const DEFAULT_REPLAY_WINDOW_S = 300;

// 멱등 dedupe TTL 기본값(ms). 더블클릭 방지용 — 5분이면 충분.
const DEFAULT_DEDUPE_TTL_MS = 300000;

// 처리 대상 action 화이트리스트 — 현재는 set-status 하나뿐.
const ACTION_SET_STATUS = "set-status";

// GraphQL Project v2 노드 ID prefix (전역 노드 ID 규약).
const PROJECT_ID_PREFIX = "PVT_";
const FIELD_ID_PREFIX = "PVTSSF_";
const ITEM_ID_PREFIX = "PVTI_";

// set-status value 의 items 허용 개수 범위(위조·오설정 방어).
const MIN_ITEMS = 1;
const MAX_ITEMS = 50;

// ── 순수 함수 1: 서명 검증 ────────────────────────────────────────────
// signature === "v0=" + hex(HMAC_SHA256(secret, `${timestamp}.${rawBody}`)).
//
// ⚠️ 구분자는 점(`.`)이다. Janus 엔 콜론 구분(`v0:{ts}:{body}`)의 다른 스킴(ingress
// 발사측)도 존재하는데 그건 이게 아니다 — 이 수신부는 점 스킴만 검증한다. 콜론 스킴으로
// 만든 서명은 반드시 실패해야 한다(테스트 고정 벡터로 박제).
//
// rawBody 는 반드시 바이트 원문(Buffer) — express.raw 가 준 body 를 파싱 전에 그대로 쓴다.
// 비교는 timingSafeEqual(타이밍 공격 방어). 길이 불일치 시 throw 하므로 길이를 먼저 확인해
// false 로 수렴시킨다 → `v0=` 접두 누락·비hex·길이 불일치 모두 throw 없이 false.
export function verifyJanusSignature(
  secret: string,
  timestamp: string,
  rawBody: Buffer | string,
  signatureHeader: string
): boolean {
  // 빈 secret/서명은 무조건 실패(설정 누락을 조용히 통과시키지 않음).
  if (!secret || !signatureHeader) {
    return false;
  }
  const bodyBuffer = Buffer.isBuffer(rawBody)
    ? rawBody
    : Buffer.from(rawBody, "utf8");
  const basestring = Buffer.concat([
    Buffer.from(`${timestamp}.`, "utf8"),
    bodyBuffer,
  ]);
  const expectedHex = crypto
    .createHmac("sha256", secret)
    .update(basestring)
    .digest("hex");
  const expected = SIGNATURE_VERSION_PREFIX + expectedHex;

  const expectedBuffer = Buffer.from(expected, "utf8");
  const providedBuffer = Buffer.from(signatureHeader, "utf8");
  // 길이가 다르면 timingSafeEqual 이 throw → 먼저 걸러 false 로 수렴.
  if (expectedBuffer.length !== providedBuffer.length) {
    return false;
  }
  return crypto.timingSafeEqual(expectedBuffer, providedBuffer);
}

// ── 순수 함수 2: timestamp 신선도 ─────────────────────────────────────
// |now - ts| <= windowS 면 신선(경계 포함). 정수 아님·비유한 → 신선하지 않음.
export function isTimestampFresh(
  ts: number,
  nowEpochS: number,
  windowS: number
): boolean {
  if (!Number.isFinite(ts)) {
    return false;
  }
  return Math.abs(nowEpochS - ts) <= windowS;
}

// ── 검증된 interaction 콜백의 정규화 표현 ──────────────────────────────
export interface JanusInteraction {
  kind: "interaction";
  sourceId: string;
  action: string;
  correlationId: string;
  user: string;
  channel: string;
  messageTs: string;
  // 원본 values(버튼 value 등). action_value 만 이 PR 에서 소비한다.
  actionValue: unknown;
}

// ── set-status value 의 검증된 표현 ───────────────────────────────────
export interface SetStatusValue {
  projectId: string;
  fieldId: string;
  optionId: string;
  items: string[];
  label: string;
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function hasPrefix(value: unknown, prefix: string): value is string {
  return typeof value === "string" && value.startsWith(prefix);
}

// ── 순수 함수 3: interaction 콜백 파싱 ─────────────────────────────────
// 입력은 이미 파싱된 객체 또는 원문 JSON 문자열(문자열이면 안전하게 parse).
//   - 깨진 JSON / 객체 아님 → null (throw 금지)
//   - kind !== "interaction"(interaction_raw/event/slash_command) → null
//   - 정상 interaction → 정규화 객체
export function parseInteractionPayload(input: unknown): JanusInteraction | null {
  let obj: unknown = input;
  if (typeof input === "string") {
    try {
      obj = JSON.parse(input);
    } catch {
      return null;
    }
  }
  if (!obj || typeof obj !== "object") {
    return null;
  }
  const rec = obj as Record<string, unknown>;
  // 이 PR 은 interaction 만 처리. 나머지 kind 는 null → 호출부가 200 ack 후 무시.
  if (rec.kind !== "interaction") {
    return null;
  }
  const values = rec.values;
  const actionValue =
    values && typeof values === "object"
      ? (values as Record<string, unknown>).action_value
      : undefined;
  return {
    kind: "interaction",
    sourceId: typeof rec.source_id === "string" ? rec.source_id : "",
    action: typeof rec.action === "string" ? rec.action : "",
    correlationId:
      typeof rec.correlation_id === "string" ? rec.correlation_id : "",
    user: typeof rec.user === "string" ? rec.user : "",
    channel: typeof rec.channel === "string" ? rec.channel : "",
    messageTs: typeof rec.message_ts === "string" ? rec.message_ts : "",
    actionValue,
  };
}

// ── 순수 함수 4: set-status value 검증(strict) ────────────────────────
// 입력은 버튼 value(JSON 문자열 또는 이미 파싱된 객체). 하나라도 어긋나면 null.
//   v===1, t==="set-status", projectId(PVT_)·fieldId(PVTSSF_)·optionId(non-empty),
//   items(PVTI_ prefix, 1~50개), label(string).
export function validateSetStatusValue(input: unknown): SetStatusValue | null {
  let obj: unknown = input;
  if (typeof input === "string") {
    try {
      obj = JSON.parse(input);
    } catch {
      return null;
    }
  }
  if (!obj || typeof obj !== "object") {
    return null;
  }
  const rec = obj as Record<string, unknown>;
  if (rec.v !== 1) {
    return null;
  }
  if (rec.t !== ACTION_SET_STATUS) {
    return null;
  }
  if (!hasPrefix(rec.projectId, PROJECT_ID_PREFIX)) {
    return null;
  }
  if (!hasPrefix(rec.fieldId, FIELD_ID_PREFIX)) {
    return null;
  }
  if (!isNonEmptyString(rec.optionId)) {
    return null;
  }
  if (typeof rec.label !== "string") {
    return null;
  }
  const items = rec.items;
  if (!Array.isArray(items) || items.length < MIN_ITEMS || items.length > MAX_ITEMS) {
    return null;
  }
  if (!items.every((item) => hasPrefix(item, ITEM_ID_PREFIX))) {
    return null;
  }
  return {
    projectId: rec.projectId,
    fieldId: rec.fieldId,
    optionId: rec.optionId,
    items: items as string[],
    label: rec.label,
  };
}

// ── 순수 함수 5: 멱등 dedupe ──────────────────────────────────────────
// 같은 key 가 TTL 내면 false(이미 처리됨), 아니면 기록하고 true.
// alert.ts 의 shouldSend 와 동형이되, 이쪽은 "처리 1회 보장"이라 기록 부수효과를 가진다.
// map 은 호출부 주입 → 테스트에서 독립 Map 으로 검증 가능.
export function shouldProcessOnce(
  key: string,
  now: number,
  map: Map<string, number>,
  ttlMs: number
): boolean {
  const last = map.get(key);
  if (last !== undefined && now - last < ttlMs) {
    return false;
  }
  // 기록 + 만료 항목 정리(무한 성장 방지). 저트래픽이라 O(n) 정리로 충분.
  map.set(key, now);
  for (const [k, t] of map) {
    if (now - t >= ttlMs) {
      map.delete(k);
    }
  }
  return true;
}

// ── 처리 코어에 주입되는 의존성(전부 주입 → 네트워크 없이 결정적 테스트) ──
export interface JanusCallbackDeps {
  app: Probot;
  // Author 봇 installation id — Status mutation 실행 권한. 미설정 시 null.
  authorInstallationId: number | null;
  // Status 단일 아이템 전환. 기본 구현은 project-graphql.updateProjectV2ItemStatus.
  updateItemStatus?: typeof updateProjectV2ItemStatus;
  // Janus 발송 타깃 해석. 기본 구현은 alert.resolveJanusTarget.
  resolveJanusTarget?: typeof resolveJanusTarget;
  // Janus 원본 메시지 교체(버튼 제거). 기본 구현은 alert.sendJanusMessageUpdate.
  sendMessageUpdate?: typeof sendJanusMessageUpdate;
  // 실패 알림. 기본 구현은 alert.notifyFailure.
  notifyFailure?: typeof notifyFailure;
  // 현재 시각(epoch ms) — 테스트 결정성. 기본 Date.now.
  now?: () => number;
  // 멱등 dedupe 맵 — 미주입 시 모듈 공유 맵 사용.
  dedupeMap?: Map<string, number>;
  // dedupe TTL(ms) — 미주입 시 기본값.
  dedupeTtlMs?: number;
}

// 모듈 공유 dedupe 맵 — registerJanusCallback 경로가 쓰는 기본 맵.
const moduleDedupeMap = new Map<string, number>();

interface ResolvedDeps {
  app: Probot;
  authorInstallationId: number | null;
  updateItemStatus: typeof updateProjectV2ItemStatus;
  resolveJanusTarget: typeof resolveJanusTarget;
  sendMessageUpdate: typeof sendJanusMessageUpdate;
  notifyFailure: typeof notifyFailure;
  now: () => number;
  dedupeMap: Map<string, number>;
  dedupeTtlMs: number;
}

function resolveDeps(deps: JanusCallbackDeps): ResolvedDeps {
  return {
    app: deps.app,
    authorInstallationId: deps.authorInstallationId,
    updateItemStatus: deps.updateItemStatus ?? updateProjectV2ItemStatus,
    resolveJanusTarget: deps.resolveJanusTarget ?? resolveJanusTarget,
    sendMessageUpdate: deps.sendMessageUpdate ?? sendJanusMessageUpdate,
    notifyFailure: deps.notifyFailure ?? notifyFailure,
    now: deps.now ?? (() => Date.now()),
    dedupeMap: deps.dedupeMap ?? moduleDedupeMap,
    dedupeTtlMs: deps.dedupeTtlMs ?? DEFAULT_DEDUPE_TTL_MS,
  };
}

// ── 처리 코어(ack 이후 백그라운드에서 도는 비즈니스 로직) ──────────────
// 전 구간 try/catch 로 감싸 어떤 예외도 밖으로 새지 않게 한다(throw 유출 시 server.ts 의
// unhandledRejection fatal 핸들러가 프로세스를 죽인다 — 절대 유출 금지). 실패는 notifyFailure 로 수렴.
//
// 이미 파싱된 콜백 객체를 받는다(HTTP 계층에서 JSON.parse 로 400 판정 후 넘김).
export async function processInteractionCallback(
  parsedBody: unknown,
  deps: JanusCallbackDeps
): Promise<void> {
  const d = resolveDeps(deps);
  const log = d.app.log;
  try {
    // kind 분기 — interaction 만 처리, 나머지는 무시(후속 확장점이라 분기 구조 유지).
    const kind = (parsedBody as Record<string, unknown> | null)?.kind;
    switch (kind) {
      case "interaction":
        break;
      case "interaction_raw":
      case "event":
      case "slash_command":
      default:
        log.debug({ kind }, "관심 대상 아닌 Janus 콜백 kind — 무시");
        return;
    }

    const interaction = parseInteractionPayload(parsedBody);
    if (!interaction) {
      // kind 는 interaction 인데 필수 필드가 이상한 경우 — 위조 가능성, 관측만.
      log.warn("Janus interaction 콜백 파싱 실패 — 무시");
      await d.notifyFailure(d.app, {
        title: "Janus 콜백 파싱 실패",
        context: "kind=interaction 이나 payload 정규화 실패",
        key: "janus-callback-parse",
      });
      return;
    }

    // action 화이트리스트 — 현재 set-status 만.
    if (interaction.action !== ACTION_SET_STATUS) {
      log.warn(
        { action: interaction.action },
        "지원하지 않는 Janus action — 무시"
      );
      return;
    }

    const value = validateSetStatusValue(interaction.actionValue);
    if (!value) {
      log.warn(
        { correlationId: interaction.correlationId },
        "set-status value 검증 실패 — 무시"
      );
      await d.notifyFailure(d.app, {
        title: "Janus set-status value 검증 실패",
        context: `correlation=${interaction.correlationId}`,
        key: "janus-callback-value",
      });
      return;
    }

    // 멱등성 — correlation_id + action 키. 더블클릭 시 mutation 1세트만.
    const dedupeKey = `${interaction.correlationId}:${interaction.action}`;
    if (
      !shouldProcessOnce(dedupeKey, d.now(), d.dedupeMap, d.dedupeTtlMs)
    ) {
      log.debug({ dedupeKey }, "Janus 콜백 중복 — 멱등 스킵");
      return;
    }

    // Author 봇 미설정이면 mutation 권한이 없다 — 관측만 하고 종료.
    if (d.authorInstallationId === null) {
      log.warn("AUTHOR_INSTALLATION_ID 미설정 — Status 전환 불가");
      await d.notifyFailure(d.app, {
        title: "Janus set-status 실행 불가",
        context: "AUTHOR_INSTALLATION_ID 미설정",
        key: "janus-callback-no-auth",
      });
      return;
    }

    // items 루프로 개별 Status mutation 실행 → 실패 집계.
    const results = await Promise.allSettled(
      value.items.map((itemId) =>
        d.updateItemStatus(d.app, d.authorInstallationId as number, {
          projectId: value.projectId,
          itemId,
          fieldId: value.fieldId,
          optionId: value.optionId,
        })
      )
    );
    const failedCount = results.filter((r) => r.status === "rejected").length;

    // 원본 메시지 교체(버튼 제거) — Janus 타깃이 있을 때만.
    const janusTarget = d.resolveJanusTarget();
    if (failedCount === 0) {
      const text = `✅ ${value.label} 이동 완료 (${interaction.user})`;
      await updateOriginalMessage(d, janusTarget, interaction, text);
    } else {
      const text = `⚠️ ${failedCount}건 실패`;
      await updateOriginalMessage(d, janusTarget, interaction, text);
      await d.notifyFailure(d.app, {
        title: "Janus set-status 일부 실패",
        context: `실패 ${failedCount}/${value.items.length} (correlation=${interaction.correlationId})`,
        key: `janus-callback-fail:${interaction.correlationId}`,
      });
    }
  } catch (err) {
    // 어떤 예외도 여기서 수렴 — 프로세스로 유출 금지.
    log.warn({ err }, "Janus 콜백 처리 중 예외 — 수렴(본 로직 보호)");
    try {
      await d.notifyFailure(d.app, {
        title: "Janus 콜백 처리 예외",
        context: String(err),
        key: "janus-callback-exception",
      });
    } catch {
      // notifyFailure 자체가 never-throw 지만 이중 방어.
    }
  }
}

// 원본 메시지 교체 — 타깃 없으면(=Janus 발송 설정 미비) 조용히 스킵.
async function updateOriginalMessage(
  d: ResolvedDeps,
  janusTarget: JanusMessageTarget | null,
  interaction: JanusInteraction,
  text: string
): Promise<void> {
  if (!janusTarget) {
    d.app.log.warn(
      "Janus 발송 타깃 미설정 — 원본 메시지 교체 스킵 (Status 전환은 수행됨)"
    );
    return;
  }
  await d.sendMessageUpdate(janusTarget, {
    channel: interaction.channel,
    ts: interaction.messageTs,
    text,
  });
}

// ── HTTP 핸들러(검증 동기 → 즉시 ack → 처리 백그라운드) ─────────────────
export function createJanusCallbackHandler(
  config: { signingSecret: string; replayWindowS: number },
  deps: JanusCallbackDeps
): (req: Request, res: Response) => void {
  return (req: Request, res: Response) => {
    const signatureHeader = readHeader(req, SIGNATURE_HEADER);
    const timestampHeader = readHeader(req, TIMESTAMP_HEADER);

    // 헤더 존재 확인 — 없으면 위조/오배선 → 401.
    if (!signatureHeader || !timestampHeader) {
      res.status(401).json({ ok: false, error: "서명 헤더 누락" });
      return;
    }

    // express.raw 후 body 는 Buffer. 비어있으면 빈 버퍼로 방어.
    const rawBody = Buffer.isBuffer(req.body) ? req.body : Buffer.from("");

    // timestamp 신선도 — replay 컷.
    const nowEpochS = Math.floor((deps.now?.() ?? Date.now()) / 1000);
    if (
      !isTimestampFresh(Number(timestampHeader), nowEpochS, config.replayWindowS)
    ) {
      res.status(401).json({ ok: false, error: "timestamp 신선도 실패" });
      return;
    }

    // HMAC 검증 — 원문 바이트로.
    if (
      !verifyJanusSignature(
        config.signingSecret,
        timestampHeader,
        rawBody,
        signatureHeader
      )
    ) {
      res.status(401).json({ ok: false, error: "서명 검증 실패" });
      return;
    }

    // JSON 파싱 — 깨진 바디는 위조/손상 → 400.
    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(rawBody.toString("utf8"));
    } catch {
      res.status(400).json({ ok: false, error: "잘못된 JSON 바디" });
      return;
    }

    // 검증 통과 → 즉시 200 ack. 나머지는 백그라운드(ack 지연 방지).
    res.status(200).json({ ok: true });

    // 백그라운드 — processInteractionCallback 은 내부에서 모든 예외를 수렴하지만,
    // 이중 방어로 .catch 도 단다(unhandledRejection → 프로세스 종료 원천 차단).
    void processInteractionCallback(parsedBody, deps).catch((err) => {
      deps.app.log.warn(
        { err },
        "Janus 콜백 백그라운드 처리 예외 — 수렴(예상 밖)"
      );
    });
  };
}

// express 헤더는 문자열 | 문자열배열 — 첫 값을 소문자 키로 읽는다.
function readHeader(req: Request, headerName: string): string {
  const value = req.headers[headerName];
  if (Array.isArray(value)) {
    return value[0] ?? "";
  }
  return value ?? "";
}

// env → replay 윈도우(초). 미설정/비정상 → 기본값(alert.ts resolveTimeoutMs 패턴).
function resolveReplayWindowS(): number {
  const raw = process.env.JANUS_CALLBACK_REPLAY_WINDOW_S;
  if (!raw) {
    return DEFAULT_REPLAY_WINDOW_S;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_REPLAY_WINDOW_S;
}

// ── 라우트 등록(index.ts 진입점) ──────────────────────────────────────
// getRouter 가 없으면(테스트/임베드) 조용히 스킵 — registerHealthcheck 와 동형.
// 서명 시크릿 미설정 시 라우트를 등록하지 않는다(fail-closed) — info 1줄만.
export function registerJanusCallback(
  getRouter: ApplicationFunctionOptions["getRouter"],
  deps: JanusCallbackDeps
): void {
  if (!getRouter) {
    return;
  }
  const signingSecret = process.env.JANUS_CALLBACK_SIGNING_SECRET;
  if (!signingSecret) {
    // fail-closed — 미검증 엔드포인트를 공개하지 않는다.
    deps.app.log.info(
      "JANUS_CALLBACK_SIGNING_SECRET 미설정 — Janus 콜백 라우트 미등록 (fail-closed)"
    );
    return;
  }

  const replayWindowS = resolveReplayWindowS();
  const handler = createJanusCallbackHandler({ signingSecret, replayWindowS }, deps);

  const router = getRouter("/janus");
  // ⚠️ HMAC 검증에 raw body(바이트 원문)가 필수 → 이 라우터에만 raw 파서를 단다.
  // 전역 JSON 미들웨어를 쓰면 원문이 소실돼 서명이 깨진다.
  router.post("/callback", express.raw({ type: "*/*" }), handler);
  deps.app.log.info("Janus 콜백 라우트 등록 — POST /janus/callback");
}

// ── 테스트 격리용 ─────────────────────────────────────────────────────
export function resetJanusDedupeForTest(): void {
  moduleDedupeMap.clear();
}
