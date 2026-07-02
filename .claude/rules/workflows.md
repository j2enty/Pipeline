---
paths:
  - ".github/workflows/**"
---

# 워크플로 yml 작성 규칙

> `.github/workflows/` 작성 시 자동 로드되는 경로 규칙. input/secret/output 카탈로그·전달 모델은 **`docs/conventions.md`** 참조.

## yml 파일명

| 위치 | 패턴 | 예시 |
|---|---|---|
| Pipeline 본체 `.github/workflows/` | `<동작>.yml` (prefix 없음) | `kickoff.yml`, `review.yml`, `merge.yml`, `critic-dispatch.yml`, `parent-autoclose.yml` |
| 영역 레포 호출자 `.github/workflows/` | `auto-<동작>.yml` (권장, Pipeline이 강제 안 함) | `auto-kickoff.yml`, `auto-review.yml` |

- Pipeline 본체는 자동화 yml만 있어서 prefix redundant
- 영역 레포는 `ci.yml` 같은 일반 CI yml과 공존하므로 구분 위해 `auto-` prefix 권장

## 한 yml = 하나의 동작

- 한 yml 파일에 여러 동작을 욱여넣지 않는다. yml은 단순 executor로만 작동.
- 동작 추가 = 새 yml 추가
- 트리거(`on:`)와 동작(`jobs:`)이 1:1이 안 되면 yml을 쪼갠다. "이 워크플로는 무엇을 하는가"에 한 문장으로 답할 수 없으면 분리.
- chain 로직은 yml이 아니라 **App 안**에 있다 (yml은 호출만 받음)

## 새 yml 추가 시

- 다른 yml과 중복되는 로직이 있는지 먼저 확인. 있으면 **reusable workflow**(`workflow_call`)나 **composite action**(`actions/`)으로 먼저 빼고 나서 yml 추가
- 새 input/secret/output은 `docs/conventions.md` 표준 카탈로그에 먼저 추가 (yml 내에서 즉흥적으로 새 이름 만들지 않음)
