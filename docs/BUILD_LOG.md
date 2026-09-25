# 빌드·테스트 로그 (Mac 세션이 기록, 최신이 위)

형식:
```
## YYYY-MM-DD HH:MM · 커밋 <hash> · build.sh | test.sh | install-device.sh
결과: 성공 / 실패
환경: macOS x.y, Xcode x.y, iOS x.y (기기)
오류 요약: (실패 시, 파일:줄 — 메시지. 전체 로그는 붙이지 말고 핵심만)
실기기 관찰: (설치 후 동작·성능·메타데이터 확인 결과)
```

---

## 2026-09-25 23:55 · 커밋 e0250fc(+fix) · build.sh | test.sh | 시뮬레이터 실행
결과: **성공** (build 오류 0 · test 59/59 통과 · 시뮬레이터 런치 정상). 실기기 설치는 이번 체크포인트에서 생략(아래 참고)
환경: macOS 26.6.2, Xcode 27.0 (27A266a), iOS 27.0 시뮬레이터 iPhone 17. XcodeGen 2.46.0. YouTubeKit 패키지 해석 정상
오류 요약 (Mac에서 수정, `fix(R1-S0)` 커밋):
- `project.yml` — TripShotTests 타깃에 `GENERATE_INFOPLIST_FILE`이 없어 테스트 번들 코드 서명 실패("target does not have an Info.plist"). 설정 추가
- `TripShot/Library/Models.swift:89` — `ShotSpec`의 합성 Codable은 `id: UUID = UUID()` 기본값이 있어도 JSON에 `id` 키를 요구 → `default-templates.json`(id 없음) 디코딩 실패 → `testDefaultTemplatesDecode` 실패. **앱에서도 기본 템플릿 3종 대신 fallback 1종("자유")만 로드되던 실제 버그.** `init(from:)`를 직접 구현해 `id`·`hint`를 선택 키로 처리
남은 경고 (동작 영향 없음, 미수정):
- `UIRequiresFullScreen` iOS 26부터 deprecated (project.yml info). 제거해도 무방
- `TripShotTests/EnhanceViewModelTests.swift:46,48` — FakeSaver가 async 컨텍스트에서 `NSLock.lock()` 사용. Swift 6 모드에서는 오류가 되므로 언젠가 `withLock` 등으로 교체 권장
- 테스트 수: HANDOFF에는 S1 25 + S2 21 + S3 17 = 63으로 적혀 있으나 실제 실행된 테스트는 59개(템플릿 2 포함)
시뮬레이터 관찰: 런치 즉시 촬영 탭, 사진/쇼츠 세그먼트, 탭 4개(촬영·보정·쇼츠·설정) 표시, 위치 권한 문구 정상. SwiftData 시드 크래시 없음. 시뮬레이터는 카메라가 없어 프리뷰는 검정
실기기 관찰: **미실시** — 사용자 결정으로 폰 설치는 R1-S4(라이브 보정 프리뷰, 카메라 중심) 체크포인트로 미룸. 촬영·GPS 기록·일괄 10장 성능·프리셋 전환 지연은 그때 측정

