# Pipeline App

Pipeline의 GitHub App 본체. webhook 수신 + chain orchestrator.

## 요구사항

- Node.js 20+
- Docker (운영 배포 시)
- GitHub App 2개 (Author 봇, Reviewer 봇)

## 로컬 개발 설정

```bash
# 의존성 설치
npm install

# 환경변수 설정
cp .env.example .env
# .env 파일 편집 — App ID, PEM 경로, Webhook Secret 입력

# 개발 서버 실행
npm run dev
```

## GitHub App 등록

### 1. Author 봇 등록

GitHub 조직 설정 → Developer settings → GitHub Apps → New GitHub App

| 항목 | 값 |
|---|---|
| App name | `<project>-automation-bot` |
| Webhook URL | `https://<your-domain>/api/github/webhooks` |
| Webhook secret | `.env`의 `WEBHOOK_SECRET` 값 |

**권한 (Repository permissions)**:
- Contents: Read & Write
- Issues: Read & Write
- Pull requests: Read & Write
- Actions: Read

**이벤트 구독**:
- Issues, Pull request, Pull request review, Workflow run

등록 후 → App ID·Private Key·Installation ID 를 `.env`에 입력.

### 2. Reviewer 봇 등록 (AI 리뷰 사용 시)

동일 방법, 다른 이름 (`<project>-review-bot`).

**권한**: Pull requests: Read & Write

## 운영 배포 (Docker)

```bash
# 이미지 빌드 + 실행
docker compose up -d

# 로그 확인
docker compose logs -f app
```

## 환경 변수

| 변수 | 필수 | 설명 |
|---|---|---|
| `AUTHOR_APP_ID` | ✅ | Author 봇 App ID |
| `AUTHOR_PEM` | ✅ | Author 봇 PEM 파일 절대경로 |
| `AUTHOR_INSTALLATION_ID` | ✅ | Author 봇 Installation ID |
| `REVIEWER_APP_ID` | - | Reviewer 봇 App ID (AI 리뷰 사용 시) |
| `REVIEWER_PEM` | - | Reviewer 봇 PEM 경로 |
| `REVIEWER_INSTALLATION_ID` | - | Reviewer 봇 Installation ID |
| `SLACK_WEBHOOK_URL` | - | Slack Incoming Webhook URL |
| `WEBHOOK_SECRET` | ✅ | GitHub App Webhook Secret |
| `PORT` | - | 포트 (기본값: 3000) |
| `LOG_LEVEL` | - | 로그 레벨 (기본값: info) |
