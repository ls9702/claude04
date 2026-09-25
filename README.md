# TripShot — 여행 사진·쇼츠 iPhone 앱 (개인용)

iPhone 12 Pro용 개인 앱. 라이브/앨범 사진 보정(인물 보정 포함)과 규격 기반 쇼츠 촬영 보조·조립.

- 계획서: [docs/PLAN.md](docs/PLAN.md) (v0.5)
- Mac 빌드·설치: [docs/MAC_SETUP.md](docs/MAC_SETUP.md)
- 현재 단계: **A0 골격 완료** → A1 사진 보정 파이프라인 진행 예정 (Mac 빌드 전 단계)

## 구조
```
project.yml        XcodeGen 정의 (xcodegen generate → TripShot.xcodeproj)
TripShot/          앱 소스 (App, Capture, Enhance, Portrait, Shorts, Compose, Music, Library, Settings, Resources)
TripShotTests/     단위 테스트
docs/              계획서, 설정 가이드
```
