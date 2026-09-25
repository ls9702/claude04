# TripShot — 여행 사진·쇼츠 iPhone 앱 (개인용)

iPhone 12 Pro용 개인 앱. 라이브/앨범 사진 보정(인물 보정 포함)과 규격 기반 쇼츠 촬영 보조·조립.

- 계획서: [docs/PLAN.md](docs/PLAN.md) (v1.1 확정)
- Mac 빌드·설치: [docs/MAC_SETUP.md](docs/MAC_SETUP.md)
- 현재 단계: **R1-S0~S3 빌드·테스트 통과(2026-09-25)** → 다음 시작 지점은 `docs/HANDOFF.md` 참조
- 세션 규약: [CLAUDE.md](CLAUDE.md) (클라우드: Opus 5.5 서브에이전트 작성 + Fable 리뷰 · Mac: 빌드 위주)

## 구조
```
project.yml        XcodeGen 정의 (xcodegen generate → TripShot.xcodeproj)
TripShot/          앱 소스 (App, Capture, Enhance, Portrait, Shorts, Compose, Music, Library, Settings, Resources)
TripShotTests/     단위 테스트
docs/              계획서, 설정 가이드
```
