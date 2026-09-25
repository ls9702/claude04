# TripShot — 작업 규약 (모든 Claude 세션 공통)

개인용 iPhone 앱. 계획: `docs/PLAN.md`. 두 세션이 같은 git 브랜치로 협업한다.

## 세션 역할 (모델별)
| 세션 | 모델/환경 | 역할 |
|---|---|---|
| **개발 세션** | Opus 5.5, 클라우드(컴파일 불가) | `docs/HANDOFF.md`의 "다음 시작 지점" 단계 **하나만** 맡아 코드·테스트 작성, 커밋 `feat(R1-S1): …`, HANDOFF를 "리뷰 대기"로 갱신 |
| **리뷰 세션** | Fable, 클라우드 | "리뷰 대기" 단계의 diff를 `docs/REVIEW_CHECKLIST.md`로 검토, `docs/REVIEW_LOG.md` 기록. 작은 문제는 직접 `fix(...)` 커밋, 큰 문제는 "수정 필요"로 되돌림. 계획서 관리 |
| **Mac 세션** | Mac Claude Code, Xcode | 빌드 체크포인트에서 `scripts/build.sh`·`test.sh`·`install-device.sh`, 컴파일 오류 최소 수정, `docs/BUILD_LOG.md` 기록, 실기기 관찰 |

세션 시작 시 항상: `CLAUDE.md` → `docs/HANDOFF.md` → (리뷰/빌드 세션은) `docs/REVIEW_LOG.md`/`docs/BUILD_LOG.md` 순으로 읽는다. 단계 정의는 `docs/PLAN.md` §8.

## 단계 진행·재개 규칙
- 릴리즈 1(카메라 R1-S1~S8) → 릴리즈 2(동영상 R2-S1~S5). 단계는 순서대로, 한 번에 하나.
- 단계 시작: HANDOFF "진행 중"에 세션·단계·시작일 기록. 단계 종료: 커밋·푸시 → HANDOFF "단계 상태"와 "다음 시작 지점" 갱신.
- 토큰 소진 대비: 30분마다 `wip(단계): …` 커밋. 마지막 커밋이 재개 지점. 다음 세션은 `git log -5`와 HANDOFF만 보고 이어간다.
- 완료 기준을 못 채운 채 세션이 끝나면 HANDOFF "진행 중"에 "어디까지 했고 무엇이 남았는지" 3줄로 남긴다.

## 브랜치·커밋 규칙
- 공유 브랜치: **`claude/health-management-app-plan-bcq1hg`** (이름은 초기 세션에서 자동 생성된 것. 바꾸려면 두 세션 모두에 알린다.)
- 작업 시작 전 반드시 `git pull --rebase origin <브랜치>`. 작업 끝나면 바로 커밋·푸시. 오래 들고 있지 않는다.
- 커밋 메시지는 한국어, 접두어 `feat:` `fix:` `docs:` `build:` `chore:`. 어떤 단계(A1, B0 등)인지 본문에 적는다.
- 충돌이 나면 `docs/HANDOFF.md`와 `docs/BUILD_LOG.md`는 **양쪽 내용을 모두 살려** 합친다. 소스 충돌은 최신 빌드가 통과한 쪽을 우선한다.
- `TripShot.xcodeproj/`는 커밋하지 않는다(`project.yml`에서 생성). 프로젝트 구조를 바꿀 때는 `project.yml`을 수정한다.
- 비밀값·개인 경로·기기 UDID는 커밋하지 않는다(`.env.local`, `scripts/device.local` 사용, gitignore 됨).

## 핸드오프 절차
1. 개발 세션: 단계 완료 → HANDOFF "리뷰 대기". 리뷰 세션: 검토 → REVIEW_LOG → "리뷰 완료" 또는 "수정 필요(항목)". 수정 필요면 개발 세션이 반영 후 다시 리뷰 대기.
2. 빌드 체크포인트 단계(PLAN §8 표의 ✔)는 리뷰 완료 후 Mac 세션이 빌드·설치 → BUILD_LOG. 실패면 개발 세션이 수정.
3. 어느 세션이든 턴 시작 시 HANDOFF·REVIEW_LOG·BUILD_LOG의 미해결 항목을 먼저 처리한다.

## 빌드·테스트 (Mac)
```bash
scripts/build.sh          # xcodegen + 시뮬레이터 빌드
scripts/test.sh           # 단위 테스트 (시뮬레이터)
scripts/install-device.sh # 연결된 iPhone에 설치 (scripts/device.local에 UDID)
scripts/sync.sh           # pull --rebase → push
```
빌드 오류를 고칠 때는 최소 수정. 기능 코드의 설계 의도(`docs/PLAN.md` §3·§4)를 바꾸지 않는다. 설계 변경이 필요하면 `docs/HANDOFF.md` "논의 필요"에 적는다.

## 코드 규칙
- Swift 5 언어 모드, SwiftUI, Apple 프레임워크 우선. 외부 패키지는 YouTubeKit만.
- 사진 결과는 반드시 사진 보관함으로, EXIF·GPS·날짜 보존(`docs/PLAN.md` §3.4). 이 원칙을 깨는 코드는 넣지 않는다.
- 파일은 모듈 폴더(`TripShot/<Module>/`)에 둔다. 새 폴더를 만들면 `project.yml`은 자동 인식(폴더 소스)하므로 수정 불필요.
- 한국어 UI 문자열, 주석은 한국어.
