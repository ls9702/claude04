# TripShot — 작업 규약 (모든 Claude 세션 공통)

개인용 iPhone 앱. 계획: `docs/PLAN.md`. 두 세션이 같은 git 브랜치로 협업한다.

## 세션 역할
| 세션 | 역할 |
|---|---|
| **클라우드 세션** (컴파일 불가) | 단계마다 **작성 → 리뷰**를 한 세트로 끝낸다. 작성은 Opus 5.5, 리뷰는 Fable(사용자가 `/model`로 전환). 리뷰는 `docs/REVIEW_CHECKLIST.md` 기준으로 `docs/REVIEW_LOG.md`에 기록하고 지적 사항을 반영한 뒤 커밋·푸시, `docs/HANDOFF.md` 갱신 |
| **Mac 세션** (Xcode) | 빌드 체크포인트에서 `scripts/build.sh`·`test.sh`·`install-device.sh`, 컴파일 오류 최소 수정(`fix(단계): …`), `docs/BUILD_LOG.md` 기록, 실기기 관찰. 기능 코드·설계 변경은 하지 않고 HANDOFF "논의 필요"에 적는다 |

세션 시작 시 항상: `CLAUDE.md` → `docs/HANDOFF.md` → `docs/BUILD_LOG.md`(실패 기록이 있으면 그것부터). 단계 정의는 `docs/PLAN.md` §8.

## 단계 진행·재개 규칙
- 릴리즈 1(카메라 R1-S1~S8) → 릴리즈 2(동영상 R2-S1~S5). 단계는 순서대로, 한 번에 하나.
- 한 단계의 흐름: 작성(코드+테스트) → 리뷰(체크리스트) → 수정 → 커밋 `feat(R1-S1): …` → HANDOFF "단계 상태"·"다음 시작 지점" 갱신.
- 토큰 소진 대비: 30분마다 `wip(단계): …` 커밋. 마지막 커밋이 재개 지점. 작성 중/리뷰 중 어디서 끊겼는지 HANDOFF "진행 중"에 3줄로 남긴다.

## 브랜치·커밋 규칙
- 공유 브랜치: **`claude/health-management-app-plan-bcq1hg`** (이름은 초기 세션에서 자동 생성된 것. 바꾸려면 두 세션 모두에 알린다.)
- 작업 시작 전 반드시 `git pull --rebase origin <브랜치>`. 작업 끝나면 바로 커밋·푸시. 오래 들고 있지 않는다.
- 커밋 메시지는 한국어, 접두어 `feat:` `fix:` `docs:` `build:` `chore:`. 어떤 단계(A1, B0 등)인지 본문에 적는다.
- 충돌이 나면 `docs/HANDOFF.md`와 `docs/BUILD_LOG.md`는 **양쪽 내용을 모두 살려** 합친다. 소스 충돌은 최신 빌드가 통과한 쪽을 우선한다.
- `TripShot.xcodeproj/`는 커밋하지 않는다(`project.yml`에서 생성). 프로젝트 구조를 바꿀 때는 `project.yml`을 수정한다.
- 비밀값·개인 경로·기기 UDID는 커밋하지 않는다(`.env.local`, `scripts/device.local` 사용, gitignore 됨).

## 핸드오프 절차
1. 클라우드 세션: 단계 작성+리뷰 완료 → 커밋·푸시 → HANDOFF 갱신.
2. 빌드 체크포인트 단계(PLAN §8 표의 ✔)는 Mac 세션이 빌드·설치 → BUILD_LOG. 실패면 클라우드 세션이 다음 턴에 수정.
3. 어느 세션이든 턴 시작 시 HANDOFF·BUILD_LOG의 미해결 항목을 먼저 처리한다.

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
