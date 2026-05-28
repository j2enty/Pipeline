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

// Slack payload 구성 — slack-notify.sh 스타일 모방.
//   "🚨 *<title>*\n<context>" (+ url 있으면 "\n👀 <url>")
// JSON.stringify 로 escape 되므로 따옴표·특수문자 안전.
function buildSlackPayload(opts: {
  title: string;
  context: string;
  url?: string;
}): string {
  let text = `🚨 *${opts.title}*\n${opts.context}`;
  if (opts.url) {
    text += `\n👀 ${opts.url}`;
  }
  return JSON.stringify({ text });
}

// 장애 알림 발송.
//
//   - SLACK_WEBHOOK_URL 미설정 → warn 로그만 찍고 조용히 return (throw 금지).
//   - 쿨다운 내 동일 키 → 스킵 (debug 로그).
//   - 전송 실패(네트워크·HTTP 에러) → try/catch 로 삼키고 warn (절대 throw 금지).
//
// key 미지정 시 title 을 쿨다운 키로 사용한다.
export async function notifyFailure(
  app: Probot,
  opts: { title: string; context: string; url?: string; key?: string }
): Promise<void> {
  const webhookUrl = process.env.SLACK_WEBHOOK_URL;
  if (!webhookUrl) {
    app.log.warn(
      { title: opts.title },
      "SLACK_WEBHOOK_URL 미설정 — 장애 알림 스킵 (로그만 남김)"
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

  try {
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: buildSlackPayload(opts),
      // Slack endpoint hang 시 무기한 대기 방지 — AbortSignal.timeout 이 발동하면
      // fetch 가 AbortError 로 reject → 아래 catch 가 흡수 (never-throw 불변식 유지).
      signal: AbortSignal.timeout(resolveTimeoutMs()),
    });
    if (!response.ok) {
      app.log.warn(
        { title: opts.title, status: response.status },
        "Slack 장애 알림 전송 실패 (HTTP 비정상 — 본 로직은 계속)"
      );
    }
  } catch (err) {
    app.log.warn(
      { err, title: opts.title },
      "Slack 장애 알림 전송 실패 (네트워크·타임아웃 등 — 본 로직은 계속)"
    );
  }
}

// 테스트 격리용 — 쿨다운 기록 초기화.
export function resetAlertCooldownForTest(): void {
  lastSentAtByKey.clear();
}
