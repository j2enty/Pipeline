# Design placeholder 템플릿

> Design 영역 선택 시 Step 6a 에서 `<parent-N>-<slug>-design.md` 내용으로 쓰는 고정 템플릿이다.
> Design 은 planner 호출 없이 이 "껍데기 + 체크리스트"로 시작한다.
> `<parent-N>`·`<slug>`·`<N>` 은 실행 시점 값으로, `<owner>`·`<parent-repo-name>` 은
> 위 주입된 설정(`pipeline-config.sh --dump` 의 `owner`·`parent-repo-name`)에서 채운다.

```markdown
# [plan] <parent-N>-<slug> — Design

## 상태
TBD — 디자이너(사용자)가 작성 예정.

## Parent
<owner>/<parent-repo-name>#<N>

## 요구사항 (parent 이슈에서 자동 요약)
{parent 본문에서 핵심 요구사항 3~5줄 추출}

## 산출물 (작성 예정)
- [ ] 와이어프레임
- [ ] 시안 (Figma)
- [ ] 인터랙션/애니메이션 스펙
- [ ] 에셋 (아이콘·이미지)

## 리스크
TBD

## 다른 영역과의 인터페이스
TBD — 다른 영역 플랜과 UI/UX 일관성 검토 예정.
```

*실제 디자인 프로세스가 확정되면 이 템플릿을 업데이트. 지금은 "껍데기 + 체크리스트"로 시작.*
