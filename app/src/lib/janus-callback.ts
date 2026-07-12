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

// label 최대 길이 — Slack 메시지에 그대로 반영되므로 새니타이즈 후 절단한다.
const MAX_LABEL_LENGTH = 80;

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

// label 새니타이즈 — Slack 메시지에 그대로 들어가므로 개행을 공백으로 접고
// 최대 길이로 절단한다(메시지 레이아웃 파괴·과대 payload 방어).
function sanitizeLabel(label: string): string {
  const singleLine = label.replace(/[\r\n]+/g, " ").trim();
  return singleLine.length > MAX_LABEL_LENGTH
    ? singleLine.slice(0, MAX_LABEL_LENGTH)
    : singleLine;
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
    // 중복 아이템 제거(유니크화) — 같은 아이템에 mutation 을 두 번 쏘지 않는다.
    items: [...new Set(items as string[])],
    // Slack 메시지 반영 대상이라 새니타이즈(개행 제거 + 최대 80자).
    label: sanitizeLabel(rec.label),
  };
}

// ── 순수 함수 5: 멱등 dedupe (in-flight / completed 2단계) ─────────────
// "성공 후 확정" 모델 — 처리 시작 시 in-flight 로만 마킹하고, 전건 성공했을 때만
// completed 로 확정(TTL 적용)한다. 실패하면 키를 해제해 사용자가 버튼 재클릭으로
// 복구할 수 있다(실행 전 확정 방식은 전건 실패 후에도 TTL 내 재시도가 스킵되는 함정).
//
// in-memory 수용 근거: 단일 인스턴스 배포 + mutation 자체가 멱등(같은 optionId
// 재설정은 무해)이라 재시작·중복 실행이 무해 — 외부 저장소 dedupe 는 불필요(수용).
// map 은 호출부 주입 → 테스트에서 독립 Map 으로 검증 가능.
export interface DedupeEntry {
  state: "in-flight" | "completed";
  at: number;
}

// 처리 시작 시도 — true 면 이 호출이 처리 소유권을 가진다(in-flight 마킹).
//   - in-flight 존재 → false (동시 더블클릭 차단)
//   - completed & TTL 내 → false (이미 성공 처리됨)
//   - 그 외(기록 없음·completed 만료) → in-flight 마킹 후 true
// in-flight 는 TTL 정리 대상이 아니다 — 처리부의 confirm/release 가 반드시 정리한다
// (예외 경로 포함: processInteractionCallback 의 outer catch 가 release 로 수렴).
export function beginProcessingOnce(
  key: string,
  now: number,
  map: Map<string, DedupeEntry>,
  ttlMs: number
): boolean {
  // 만료된 completed 항목 정리(무한 성장 방지). 저트래픽이라 O(n) 정리로 충분.
  for (const [k, entry] of map) {
    if (entry.state === "completed" && now - entry.at >= ttlMs) {
      map.delete(k);
    }
  }
  const existing = map.get(key);
  if (existing) {
    if (existing.state === "in-flight") {
      return false;
    }
    if (now - existing.at < ttlMs) {
      return false;
    }
  }
  map.set(key, { state: "in-flight", at: now });
  return true;
}

// 전건 성공 시에만 호출 — completed 확정(TTL 시작점 = now).
export function confirmProcessed(
  key: string,
  now: number,
  map: Map<string, DedupeEntry>
): void {
  map.set(key, { state: "completed", at: now });
}

// 실패(부분·전체·예외) 시 호출 — 키 해제로 버튼 재클릭 복구를 허용한다.
export function releaseProcessing(
  key: string,
  map: Map<string, DedupeEntry>
): void {
  map.delete(key);
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
  dedupeMap?: Map<string, DedupeEntry>;
  // dedupe TTL(ms) — 미주입 시 기본값.
  dedupeTtlMs?: number;
}

// 모듈 공유 dedupe 맵 — registerJanusCallback 경로가 쓰는 기본 맵.
const moduleDedupeMap = new Map<string, DedupeEntry>();

// 검증 실패(서명은 통과했지만 내용 불량) 누적 카운터 — 관측성.
// notifyFailure 는 쿨다운으로 반복 알림이 가려지므로, warn 로그에 누적 수치를 실어
// "얼마나 자주 일어나는지"를 로그만으로 추적 가능하게 한다(모듈 내 단순 카운터로 충분).
const rejectCounters = {
  parseFailed: 0, // kind=interaction 인데 정규화 실패
  requiredFieldMissing: 0, // correlation_id 등 필수 필드 누락
  sourceIdMismatch: 0, // source_id 가 기대값과 불일치
  valueInvalid: 0, // set-status value strict 검증 실패
};

interface ResolvedDeps {
  app: Probot;
  authorInstallationId: number | null;
  updateItemStatus: typeof updateProjectV2ItemStatus;
  resolveJanusTarget: typeof resolveJanusTarget;
  sendMessageUpdate: typeof sendJanusMessageUpdate;
  notifyFailure: typeof notifyFailure;
  now: () => number;
  dedupeMap: Map<string, DedupeEntry>;
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
  // outer catch 에서 dedupe 키를 해제할 수 있도록 try 밖에 선언 —
  // in-flight 마킹 후 예외가 나면 반드시 release 해 재클릭 복구를 보장한다.
  let inFlightDedupeKey: string | null = null;
  try {
    // kind 분기 — 후속 확장점 문서화 목적의 스위치(어떤 kind 가 오는지 여기서 보인다).
    // kind 의 실검증(불변식 소유)은 parseInteractionPayload 가 담당한다 — 여기서
    // interaction 이 통과해도 parse 가 다시 확인하므로 이 스위치는 관측·확장용이다.
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
      // kind 는 interaction 인데 정규화 실패 — 위조 가능성, 관측만.
      rejectCounters.parseFailed += 1;
      log.warn(
        { rejectedTotal: rejectCounters.parseFailed },
        "Janus interaction 콜백 파싱 실패 — 무시"
      );
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

    // source_id 대조 — 다른 소스로 발급된 콜백이 흘러들어오면 무시(방어심층).
    // alert.ts 와 동일하게 JANUS_SOURCE_ID(기본 "pipeline") 를 재사용한다.
    const expectedSourceId = process.env.JANUS_SOURCE_ID || "pipeline";
    if (interaction.sourceId !== expectedSourceId) {
      rejectCounters.sourceIdMismatch += 1;
      log.warn(
        {
          sourceId: interaction.sourceId,
          rejectedTotal: rejectCounters.sourceIdMismatch,
        },
        "Janus 콜백 source_id 불일치 — 무시"
      );
      return;
    }

    // 필수 필드 강제 — correlation_id 가 비면 dedupeKey 가 ":set-status" 로 고정되어
    // 서로 다른 정상 클릭이 TTL 내 조용히 유실된다. user/channel/message_ts 도
    // 메시지 교체·귀속에 필수라 non-empty 를 강제한다. 누락 = 200 ack 후 무시+관측.
    if (
      !interaction.correlationId ||
      !interaction.user ||
      !interaction.channel ||
      !interaction.messageTs
    ) {
      rejectCounters.requiredFieldMissing += 1;
      log.warn(
        {
          correlationId: interaction.correlationId,
          rejectedTotal: rejectCounters.requiredFieldMissing,
        },
        "Janus interaction 필수 필드 누락(correlation_id/user/channel/message_ts) — 무시"
      );
      await d.notifyFailure(d.app, {
        title: "Janus 콜백 필수 필드 누락",
        context: "correlation_id/user/channel/message_ts 중 빈 값 존재",
        key: "janus-callback-required-field",
      });
      return;
    }

    const value = validateSetStatusValue(interaction.actionValue);
    if (!value) {
      rejectCounters.valueInvalid += 1;
      log.warn(
        {
          correlationId: interaction.correlationId,
          rejectedTotal: rejectCounters.valueInvalid,
        },
        "set-status value 검증 실패 — 무시"
      );
      await d.notifyFailure(d.app, {
        title: "Janus set-status value 검증 실패",
        context: `correlation=${interaction.correlationId}`,
        key: "janus-callback-value",
      });
      return;
    }

    // 멱등성 — correlation_id + action 키로 in-flight 마킹(동시 더블클릭 차단).
    // completed 확정은 전건 성공 후에만 — 실패 시 release 로 재클릭 복구 허용.
    const dedupeKey = `${interaction.correlationId}:${interaction.action}`;
    if (!beginProcessingOnce(dedupeKey, d.now(), d.dedupeMap, d.dedupeTtlMs)) {
      log.debug({ dedupeKey }, "Janus 콜백 중복 — 멱등 스킵");
      return;
    }
    inFlightDedupeKey = dedupeKey;

    // Author 봇 미설정이면 mutation 권한이 없다 — 관측 후 키 해제(설정 복구 후 재클릭 허용).
    if (d.authorInstallationId === null) {
      log.warn("AUTHOR_INSTALLATION_ID 미설정 — Status 전환 불가");
      await d.notifyFailure(d.app, {
        title: "Janus set-status 실행 불가",
        context: "AUTHOR_INSTALLATION_ID 미설정",
        key: "janus-callback-no-auth",
      });
      releaseProcessing(dedupeKey, d.dedupeMap);
      inFlightDedupeKey = null;
      return;
    }

    // items 를 직렬로 mutation 실행 → 개별 실패 집계.
    // GitHub 는 단일 토큰의 동시 mutation 을 secondary rate limit 대상으로 권고하지
    // 않는다(직렬 권장) — 최대 50건이라 직렬 루프로 충분하고 동시성 풀은 불필요.
    let failedCount = 0;
    for (const itemId of value.items) {
      try {
        await d.updateItemStatus(d.app, d.authorInstallationId, {
          projectId: value.projectId,
          itemId,
          fieldId: value.fieldId,
          optionId: value.optionId,
        });
      } catch (err) {
        failedCount += 1;
        log.warn({ err, itemId }, "Status mutation 개별 실패");
      }
    }

    // dedupe 확정/해제는 mutation 결과 직후에 — 이후 단계(메시지 교체)의 예외가
    // 멱등 상태를 오염시키지 않게 한다.
    if (failedCount === 0) {
      // 전건 성공 → completed 확정(TTL 내 재클릭은 멱등 스킵).
      confirmProcessed(dedupeKey, d.now(), d.dedupeMap);
    } else {
      // 부분·전체 실패 → 키 해제(버튼 재클릭으로 복구 가능. mutation 은 멱등이라
      // 이미 성공한 아이템의 재실행도 무해).
      releaseProcessing(dedupeKey, d.dedupeMap);
    }
    inFlightDedupeKey = null;

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
    // in-flight 로 남은 키가 있으면 해제(영구 차단 방지 — 재클릭 복구 보장).
    if (inFlightDedupeKey !== null) {
      releaseProcessing(inFlightDedupeKey, d.dedupeMap);
    }
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

    // express.raw 후 body 는 반드시 Buffer 다. Buffer 가 아니면 상위 미들웨어가 body 를
    // 먼저 소비한 배선 사고 — 조용히 빈 버퍼로 대체하면 전 요청이 무증상 401 로 죽는
    // "기능 무음 사망"이 되므로, 500 + error 로그로 시끄럽게 실패시킨다.
    if (!Buffer.isBuffer(req.body)) {
      deps.app.log.error(
        { bodyType: typeof req.body },
        "Janus 콜백 body 가 Buffer 가 아님 — 상위 미들웨어가 raw body 를 선소비 (배선 오류)"
      );
      res.status(500).json({ ok: false, error: "raw body 계약 위반" });
      return;
    }
    const rawBody = req.body;

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
  // inflate:false — 압축(gzip 등) 요청을 거부해 "서명 대상 바이트" 경계를 명확히 한다.
  router.post("/callback", express.raw({ type: "*/*", inflate: false }), handler);
  deps.app.log.info("Janus 콜백 라우트 등록 — POST /janus/callback");
}

// ── 테스트 격리용 ─────────────────────────────────────────────────────
export function resetJanusDedupeForTest(): void {
  moduleDedupeMap.clear();
  rejectCounters.parseFailed = 0;
  rejectCounters.requiredFieldMissing = 0;
  rejectCounters.sourceIdMismatch = 0;
  rejectCounters.valueInvalid = 0;
}
