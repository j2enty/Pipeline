# Context md 생성 템플릿 (G7)

> Step 11(Context md 생성)에서 참조. 저장 경로는 SKILL.md 에서 config `docs-context-dir`
> 로 읽어 `<docs-context-dir>/<slug>-status.md` 로 결정한다.
> 세션 종료 직전(성공·혼합·에스컬·SIGINT 모두 포함) **항상** 로컬에서 생성한다.

## 템플릿

```markdown
# [status] <slug> — <parent 이슈 제목>

**최종 업데이트**: <ISO-8601 UTC>
**Parent**: https://github.com/<owner>/<parent-repo-name>/issues/<parent-N>
**실행 런타임**: <agent|team|serial|ultra>

## WHY
<parent 본문 요약 + requirements 기반 1~2 단락>

## 의사 결정
- <plan 문서에서 추출한 주요 결정>

## 영역별 진행 상태
| 영역 | Status | PR | 비고 |
|---|---|---|---|
| Backend | `Bot Review` | #12 | PR 생성 완료 · `/review` 대기/진행 중 |
| Frontend | `In Progress` (blocked) | — | 플레이키 3회 · <코멘트 URL> |

> `Bot Review → In Review` 전환은 `/review` APPROVE 시 자동. REQUEST_CHANGES 는 `Bot Review` 유지.

## 남은 작업
- [ ] <영역> <원인> 해결 후 `/kickoff` 재실행

## 블로커
- <영역>: <원인 요약>

## 참고
- 상태 파일: `.pipeline/state/sessions/<slug>.json`
- 플랜: Docs/claude/plans/<parent-N>-<slug>-*.md
```

## G7-c. Docs 커밋 트리거

**먼저 Docs 가 독립 git 레포 루트인지**(`--show-toplevel` 일치) 확인하고, 아니면(미클론·부모
git 하위 일반 dir 포함) 이 커밋 단계 전체를 스킵한다. 있을 때만 아래 트리거를 평가한다.

다음 중 하나 이상 충족 시만 Docs 레포에 커밋·push:
- (a) 한 영역 이상 `status=escalated`
- (b) SIGINT 캡처로 중단
- (c) 혼합 상태 (pr_created + escalated 또는 pr_created + skipped 동시 존재)

커밋 방식 (`cd` 금지 — `git -C Docs` 통일):

```bash
# Docs 가 "독립 git 레포 루트"인지 판정. rev-parse --git-dir 은 부모로 거슬러 올라가
# 워크스페이스 루트의 .git 을 잡아 오판하므로 쓰지 않는다.
# toplevel 이 Docs 자신과 일치할 때만 독립 Docs 레포로 인정.
docs_top="$(git -C Docs rev-parse --show-toplevel 2>/dev/null || true)"
docs_abs="$(cd Docs 2>/dev/null && pwd -P || true)"
if [ -n "$docs_top" ] && [ "$docs_top" = "$docs_abs" ]; then HAS_DOCS=1; else HAS_DOCS=0; fi

if [ "$HAS_DOCS" = "1" ]; then
  # 브랜치 존재 시 재사용, 없으면 생성.
  git -C Docs checkout context/<slug> 2>/dev/null || git -C Docs checkout -b context/<slug>
  git -C Docs add claude/context/<slug>-status.md
  git -C Docs commit -m "[context] <parent-title> 상태 업데이트 (#<parent-N>)"
  git -C Docs push -u origin context/<slug>
else
  echo "Docs 독립 레포 없음 — Context md 커밋 스킵 (Docs 미사용/미클론 프로젝트)"
fi
```

PR 생성 없음 — 브랜치 직접 push. 클린 성공(전부 pr_created, 스킵·에스컬 0건)은 Docs 커밋 생략.
