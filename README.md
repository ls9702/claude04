# TripShot — 여행 사진·쇼츠 iPhone 앱 (개인용)

iPhone 12 Pro용 개인 앱. 라이브/앨범 사진 보정(인물 보정 포함)과 규격 기반 쇼츠 촬영 보조·조립.

- 계획서: [docs/PLAN.md](docs/PLAN.md) (v0.4 확정)
- Mac 빌드·설치: [docs/MAC_SETUP.md](docs/MAC_SETUP.md)
- 현재 단계: **P0 골격** — 탭 4개, SwiftData 모델·시드, 카메라 프리뷰·사진 촬영·저장, 앨범 선택, 쇼츠 프로젝트 생성

## 구조
```
project.yml        XcodeGen 정의 (xcodegen generate → TripShot.xcodeproj)
TripShot/          앱 소스 (App, Capture, Enhance, Portrait, Shorts, Compose, Music, Library, Settings, Resources)
TripShotTests/     단위 테스트
docs/              계획서, 설정 가이드
```
