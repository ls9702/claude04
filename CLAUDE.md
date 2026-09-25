# TripShot — 작업 규약 (모든 Claude 세션 공통)

개인용 iPhone 앱. 계획: `docs/PLAN.md`. 두 세션이 같은 git 브랜치로 협업한다.

## 세션 역할
| 세션 | 환경 | 역할 |
|---|---|---|
| **클라우드 세션** | Linux, 컴파일 불가 | 계획·설계, 기능 코드 작성(A 단계), 문서. 빌드 결과를 `docs/BUILD_LOG.md`에서 읽고 수정 |
| **Mac 세션** | MacBook Air M2, Xcode | `scripts/build.sh`로 빌드·테스트, 컴파일 오류 수정, 실기기 설치, 실측 결과 기록. 튜닝(B 단계) |

역할은 고정이 아니다. 어느 세션이든 `docs/HANDOFF.md`의 "진행 중" 항목을 먼저 확인하고 겹치지 않는 일을 맡는다.

## 브랜치·커밋 규칙
- 공유 브랜치: **`claude/health-management-app-plan-bcq1hg`** (이름은 초기 세션에서 자동 생성된 것. 바꾸려면 두 세션 모두에 알린다.)
- 작업 시작 전 반드시 `git pull --rebase origin <브랜치>`. 작업 끝나면 바로 커밋·푸시. 오래 들고 있지 않는다.
- 커밋 메시지는 한국어, 접두어 `feat:` `fix:` `docs:` `build:` `chore:`. 어떤 단계(A1, B0 등)인지 본문에 적는다.
- 충돌이 나면 `docs/HANDOFF.md`와 `docs/BUILD_LOG.md`는 **양쪽 내용을 모두 살려** 합친다. 소스 충돌은 최신 빌드가 통과한 쪽을 우선한다.
- `TripShot.xcodeproj/`는 커밋하지 않는다(`project.yml`에서 생성). 프로젝트 구조를 바꿀 때는 `project.yml`을 수정한다.
- 비밀값·개인 경로·기기 UDID는 커밋하지 않는다(`.env.local`, `scripts/device.local` 사용, gitignore 됨).

## 핸드오프 절차
1. 작업을 마치면 `docs/HANDOFF.md`의 상태표를 갱신한다(단계, 상태, 다음 할 일, 막힌 것).
2. Mac 세션은 빌드·테스트를 돌릴 때마다 `docs/BUILD_LOG.md` 맨 위에 결과를 추가한다(날짜, 커밋, 성공/실패, 오류 요약, 실기기 관찰).
3. 클라우드 세션은 턴 시작 시 위 두 파일을 읽고 실패한 빌드가 있으면 그것부터 고친다.

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
