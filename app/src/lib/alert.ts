import type { Probot } from "probot";

// 장애 알림 — Slack incoming webhook 으로 "시끄러운 실패" 알림 발송
//
// 설계 원칙:
//   - 알림 실패가 본 로직(폴러 tick·dispatch·핸들러)을 절대 죽이면 안 된다.
//     → SLACK_WEBHOOK_URL 미설정/전송 실패 모두 조용히 삼키고 warn 로그만 남긴다.
//   - 같은 장애가 연속 폭주하면 Slack 스팸 → 쿨다운으로 동일 키 재전송을 막는다.
//   - 프로젝트 식별자(웹훅 URL·채널 등)는 전부 env 주입. 하드코딩 금지.

// 동일 키 알림이 마지막으로 전송된 시각 (epoch ms) 기록.
// 모듈 내부 캡슐화 — 쿨다운 판단의 순수 함수(shouldSend)와 분리.
const lastSentAtByKey = new Map<string, number>();

// 쿨다운 기본값 (5분). ALERT_COOLDOWN_MS env 로 덮어쓸 수 있다.
const DEFAULT_COOLDOWN_MS = 300000;

// fetch 타임아웃 기본값 (5초). ALERT_TIMEOUT_MS env 로 덮어쓸 수 있다.
// Slack endpoint 가 hang 하면 notifyFailure 가 무기한 대기 → exitOnFatalError 의
// process.exit(1) 이 지연돼 "죽지도 재기동되지도 않는" 상태 발생.
// AbortSignal.timeout 으로 상한을 둬 치명적 종료 지연 위험을 없앤다.
const DEFAULT_TIMEOUT_MS = 5000;

// 쿨다운 판단 (순수 함수) — 부수효과 없이 "지금 보낼지" 만 반환.
//
//   - 해당 key 의 마지막 전송 기록이 없으면 → 전송 (true)
//   - now - last <= cooldownMs (쿨다운 내) → 스킵 (false)
//   - cooldownMs 경과 → 전송 (true)
//
// lastMap 은 호출부가 주입 → 테스트에서 독립 Map 으로 검증 가능.
export function shouldSend(
  key: string,
  now: number,
  lastMap: Map<string, number>,
  cooldownMs: number
): boolean {
  const lastSentAt = lastMap.get(key);
  if (lastSentAt === undefined) {
    return true;
  }
  return now - lastSentAt > cooldownMs;
}

// env 에서 쿨다운 ms 읽기 — 미설정/비정상 값이면 기본값.
function resolveCooldownMs(): number {
  const raw = process.env.ALERT_COOLDOWN_MS;
  if (!raw) {
    return DEFAULT_COOLDOWN_MS;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : DEFAULT_COOLDOWN_MS;
}

// env 에서 fetch 타임아웃 ms 읽기 — 미설정/비정상 값이면 기본값.
// resolveCooldownMs 와 동일 패턴.
function resolveTimeoutMs(): number {
  const raw = process.env.ALERT_TIMEOUT_MS;
  if (!raw) {
    return DEFAULT_TIMEOUT_MS;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TIMEOUT_MS;
}

// 알림 본문 텍스트 구성 — slack-notify.sh 스타일.
//   "🚨 *<title>*\n<context>" (+ url 있으면 "\n👀 <url>")
function buildAlertText(opts: {
  title: string;
  context: string;
  url?: string;
}): string {
  let text = `🚨 *${opts.title}*\n${opts.context}`;
  if (opts.url) {
    text += `\n👀 ${opts.url}`;
  }
  return text;
}

// Janus 경로 활성화에 반드시 필요한 env 3종.
//   JANUS_SOURCE_ID 는 기본값("pipeline")이 있어 필수가 아니므로 여기서 제외한다.
const JANUS_REQUIRED_ENV_KEYS = [
  "JANUS_BASE_URL",
  "JANUS_AUTH_TOKEN",
  "JANUS_ALERT_CHANNEL",
] as const;

// 부분 설정(오설정) 감지 — 관측성용.
//   필수 3키 중 '일부만' 채워져 Janus 가 조용히 비활성화되는 상황을 잡아낸다.
//   - 0개 설정(완전 미설정) → 정상 시나리오 → [] (경고 대상 아님)
//   - 3개 모두 설정(완전 설정) → 정상 → []
//   - 1~2개만 설정(오설정) → 누락된 키 '이름'만 반환 (값·토큰은 절대 노출 안 함)
function findPartialJanusMisconfig(): string[] {
  const missingKeys = JANUS_REQUIRED_ENV_KEYS.filter((key) => !process.env[key]);
  if (
    missingKeys.length === 0 ||
    missingKeys.length === JANUS_REQUIRED_ENV_KEYS.length
  ) {
    return [];
  }
  return [...missingKeys];
}

// Janus 게이트웨이 발송 타깃 — 아웃바운드 알림을 Slack 대신 Janus REST 로 보낸다.
//   JANUS_BASE_URL/JANUS_AUTH_TOKEN/JANUS_ALERT_CHANNEL 이 모두 있어야 활성화.
//   컨테이너에서 호스트 Janus 는 http://host.docker.internal:8700 로 닿는다.
//   source_id 는 JANUS_SOURCE_ID(기본 "pipeline") — 하드코딩 대신 env 주입.
function resolveJanusTarget(): {
  url: string;
  token: string;
  sourceId: string;
  channel: string;
} | null {
  const baseUrl = process.env.JANUS_BASE_URL;
  const token = process.env.JANUS_AUTH_TOKEN;
  const channel = process.env.JANUS_ALERT_CHANNEL;
  if (!baseUrl || !token || !channel) {
    return null;
  }
  return {
    url: baseUrl.replace(/\/+$/, ""),
    token,
    sourceId: process.env.JANUS_SOURCE_ID || "pipeline",
    channel,
  };
}

// Janus 로 발송(POST /messages). 비 2xx 면 throw → 호출부가 webhook 폴백을 태운다.
async function sendViaJanus(
  target: { url: string; token: string; sourceId: string; channel: string },
  opts: { title: string; context: string; url?: string }
): Promise<void> {
  const response = await fetch(`${target.url}/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${target.token}`,
    },
    body: JSON.stringify({
      source_id: target.sourceId,
      channel: target.channel,
      text: buildAlertText(opts),
    }),
    signal: AbortSignal.timeout(resolveTimeoutMs()),
  });
  if (!response.ok) {
    throw new Error(`Janus 응답 비정상 status=${response.status}`);
  }
}

// Slack Incoming Webhook 으로 발송(폴백 경로). 비 2xx 면 throw.
async function sendViaWebhook(
  webhookUrl: string,
  opts: { title: string; context: string; url?: string }
): Promise<void> {
  const response = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: buildAlertText(opts) }),
    signal: AbortSignal.timeout(resolveTimeoutMs()),
  });
  if (!response.ok) {
    throw new Error(`Slack webhook 응답 비정상 status=${response.status}`);
  }
}

// 장애 알림 발송.
//
//   - 발송 경로: Janus 게이트웨이 우선(설정 시), 실패하면 Slack webhook 폴백.
//     둘 다 미설정 → warn 로그만 찍고 조용히 return (throw 금지).
//   - 쿨다운 내 동일 키 → 스킵 (debug 로그).
//   - 전송 실패(네트워크·HTTP 에러) → try/catch 로 삼키고 warn (절대 throw 금지).
//
// Janus 를 우선하되 webhook 을 폴백으로 남기는 이유: 장애 알림은 유실되면 안 되므로,
// Janus 가 잠깐 죽어도 webhook 으로라도 반드시 나가게 한다(never-lose-alert).
//
// key 미지정 시 title 을 쿨다운 키로 사용한다.
export async function notifyFailure(
  app: Probot,
  opts: { title: string; context: string; url?: string; key?: string }
): Promise<void> {
  const janus = resolveJanusTarget();

  // 부분 설정(오설정) 관측성 — 필수 3키 중 일부만 채워져 Janus 가 비활성화되면
  // 조용히 넘어가지 않고 한 줄 경고를 남긴다(누락 키 '이름'만, 값·토큰은 미노출).
  const partialJanusMissingKeys = findPartialJanusMisconfig();
  if (partialJanusMissingKeys.length > 0) {
    app.log.warn(
      { missing: partialJanusMissingKeys },
      `Janus 부분 설정 감지 — 비활성화 (누락: ${partialJanusMissingKeys.join(", ")})`
    );
  }

  const webhookUrl = process.env.SLACK_WEBHOOK_URL;
  if (!janus && !webhookUrl) {
    app.log.warn(
      { title: opts.title },
      "Janus/SLACK_WEBHOOK_URL 둘 다 미설정 — 장애 알림 스킵 (로그만 남김)"
    );
    return;
  }

  const cooldownKey = opts.key ?? opts.title;
  const now = Date.now();
  if (!shouldSend(cooldownKey, now, lastSentAtByKey, resolveCooldownMs())) {
    app.log.debug(
      { title: opts.title },
      "장애 알림 쿨다운 — 재전송 스킵 (스팸 방지)"
    );
    return;
  }

  // 전송 시도 전에 시각을 기록 — 실패해도 쿨다운은 적용 (재시도 폭주 방지).
  lastSentAtByKey.set(cooldownKey, now);

  // 1순위: Janus. 실패(예외)하면 webhook 폴백을 태운다.
  if (janus) {
    try {
      await sendViaJanus(janus, opts);
      return;
    } catch (err) {
      if (!webhookUrl) {
        app.log.warn(
          { err, title: opts.title },
          "Janus 장애 알림 전송 실패 (webhook 폴백 없음 — 본 로직은 계속)"
        );
        return;
      }
      app.log.warn(
        { err, title: opts.title },
        "Janus 전송 실패 → Slack webhook 폴백 시도"
      );
    }
  }

  // 2순위(또는 Janus 미설정): Slack webhook.
  try {
    await sendViaWebhook(webhookUrl as string, opts);
  } catch (err) {
    app.log.warn(
      { err, title: opts.title },
      "Slack webhook 장애 알림 전송 실패 (네트워크·타임아웃·HTTP 등 — 본 로직은 계속)"
    );
  }
}

// 테스트 격리용 — 쿨다운 기록 초기화.
export function resetAlertCooldownForTest(): void {
  lastSentAtByKey.clear();
}
