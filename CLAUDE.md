# Pipeline

이식 가능한 AI 자동화 파이프라인 프레임워크.


## 정체성

AI 에이전트(Claude Code 등)와 GitHub Actions를 연결해서 개발 워크플로 — 기획·실행·리뷰·머지 — 를 자동화하는 도구 모음.

이 레포의 본질적 가치는 **재사용 가능한 자산**이라는 점이다. 첫 적용 대상은 Reclip 프로젝트지만, 다른 어떤 프로젝트에도 그대로 이식 가능해야 한다. 장기적으로 오픈소스화 가능성을 염두에 둔다.


## 핵심 원칙

### 1. 프로젝트 종속성 제로

레포 본체 코드(`workflows/`, `scripts/`)에는 **어떠한 특정 프로젝트 식별자도 하드코딩하지 않는다**.

- 레포 owner / 레포명
- GitHub App ID, Installation ID
- 토큰 이름 (`RECLIP_*` 같은 prefix 금지)
- 슬랙 채널, 알림 대상
- 영역 이름 (`Backend`, `iOS` 등)

이 모든 값은 **외부 설정**(env, secrets, config 파일)으로 주입받는다. 새 프로젝트로 이식할 때 바꿔야 할 것은 설정값뿐이어야 한다.

### 2. 한 곳에서 전체 파이프라인 가시성

`.github/workflows/` 한 디렉토리에서 모든 스텝을 한눈에 본다. 디렉토리 트리는 깊이 1단계로 유지. 클릭 한 번으로 전체 파이프라인 구조 파악 가능해야 한다.

### 3. 각 스텝 = 하나의 yml

한 yml 파일에 여러 스텝을 욱여넣지 않는다.

- 스텝 추가 = 새 yml 추가
- 스텝 수정 = 해당 yml 1개만 변경
- 파일명 컨벤션: `<동작>-<대상>.yml` (예: `trigger-plan.yml`, `dispatch-review.yml`, `escalate-blocked.yml`)

### 4. 공통 로직은 reusable로

워크플로 간 중복은 즉시 추출:

- 반복되는 job → **reusable workflow** (`workflow_call`)
- 반복되는 step → **composite action** (`actions/`)
- 반복되는 쉘 로직 → `scripts/` 단일 파일

### 5. 한 yml은 한 가지만 한다

트리거(`on:`)와 동작(`jobs:`)이 1:1이 안 되면 yml을 쪼갠다. "이 워크플로는 무엇을 하는가"에 한 문장으로 답할 수 없으면 분리.


## 디렉토리 구조

```
Pipeline/
├── .github/workflows/   # 모든 자동화 yml — 한 디렉토리, 한 단계
├── actions/             # composite actions (재사용 step)
├── scripts/             # yml에서 호출하는 쉘/노드 헬퍼
├── config/              # 프로젝트별 설정 예시 (이식 시 채워서 쓰는 템플릿)
└── examples/            # 첫 적용 사례 (Reclip 등)
```

- 본체는 `.github/workflows/` + `actions/` + `scripts/` 세 디렉토리만
- 프로젝트별 설정·예시는 본체와 분리


## 비-목표

- 특정 프로젝트 전용 자동화 (Reclip은 첫 적용 사례일 뿐)
- 비즈니스 로직 (각 프로젝트 레포 소관)
- 백오피스 / 관리 UI


## 첫 적용 사례

Reclip 프로젝트(상위 워크스페이스). Reclip에서 학습한 패턴을 일반화해서 본체에 반영하고, Reclip 전용 설정은 `examples/reclip/` 또는 외부 secrets로만 둔다.

본체 코드에 Reclip 식별자가 들어가는 순간, 즉시 추출해서 일반화한다. **"이 프로젝트를 위해 만든 코드"는 본체에 들어갈 자격이 없다.**


## 규칙

- 모든 문서·주석·커밋은 한국어
- 커밋 메시지 prefix: `[워크플로]`, `[액션]`, `[스크립트]`, `[설정]`, `[문서]`, `[기타]`
- 새 yml 추가 시 — 다른 yml과 중복되는 로직이 있는지 먼저 확인. 있으면 reusable로 먼저 빼고 나서 yml 추가
- 본체 코드(`/.github/workflows/`, `/actions/`, `/scripts/`)에 프로젝트 식별자 하드코딩 시도 시 — 즉시 거부하고 설정 주입 방식으로 변경
