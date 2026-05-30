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

**권한**:
- Repository → Contents: Read & Write
- Repository → Issues: Read & Write
- Repository → Pull requests: Read & Write
- Repository → Actions: Read (auto-merge 가 CI workflow 결과 확인)
- **Organization → Projects: Read & Write** (폴러가 Project v2 조회 + Status 전환 — 누락 시 폴러가 Project 를 못 읽어 kickoff 자동화가 조용히 멈춤)

**이벤트 구독**:
- Issues, Issue comment, Pull request

등록 후 → App ID·Private Key·Installation ID 를 `.env`에 입력.

### 2. Reviewer 봇 등록 (AI 리뷰 사용 시)

동일 방법, 다른 이름 (`<project>-review-bot`).

**권한**:
- Repository → Pull requests: Read & Write
- Repository → Contents: Read (diff 읽기용)

**이벤트 구독**: Pull request review

## 운영 배포 (Docker)

```bash
# 이미지 빌드 + 실행
docker compose up -d --build

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

## finding 추적 (Tech Debt)

리뷰·critic이 낸 major/minor 지적을 GitHub 이슈로 자동 추적하는 기능이다.

### 무엇을 하는가

- **review yml** 이 끝난 뒤 major/minor 지적 항목을 영역 레포 이슈로 자동 생성
- **critic yml** 이 종합 지적을 낸 경우 parent 레포 이슈로 생성
- 이슈에 `major-issue` 또는 `minor-issue` 라벨이 붙어 GitHub Project 뷰에서 집계 가능

### 켜는 법

`config/pipeline-config.example.yml`의 `tracking:` 섹션을 채운다:

```yaml
tracking:
  enabled: true
  major_label: major-issue   # 생략 시 기본값 사용
  minor_label: minor-issue   # 생략 시 기본값 사용
```

`install.sh`를 실행하면:
1. 각 영역 레포에 `major-issue` / `minor-issue` 라벨 자동 등록 (`register_labels()`)
2. org variables `PIPELINE_TRACKING_*` 자동 등록

### Tech Debt 뷰 만들기 (프로젝트당 1회, 수동)

GitHub Project에 필터 뷰를 만들면 쌓인 finding을 한눈에 볼 수 있다.

1. GitHub Project 열기 → **New view** 클릭
2. **Table** 레이아웃 선택
3. 상단 Filter 입력창에 `label:major-issue,minor-issue` 입력
4. 뷰 이름 저장 (예: `Tech Debt`)

이후 리뷰가 이슈를 생성할 때마다 이 뷰에 자동으로 집계된다.

### 이슈 닫기

finding 이슈는 수동으로 close한다. 수정 완료 후 PR에서 `Closes #<이슈번호>`를 명시하거나 직접 이슈를 close.
