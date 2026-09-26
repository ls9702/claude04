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

## 2026-09-26 23:30 · 커밋 84484dc → (이번 커밋) · build.sh | test.sh | install-device.sh · R2-S2 3D 스티커·60종·선택 띠
결과: **성공** (build 오류 0 · test **232/232**, skip 1 = 개발용 미리보기). 실기기 설치 완료
사용자 실기기 관찰(40종 버전): 동작 OK, 렌즈 만족. 스티커가 얼굴에 비해 큼, 그림이 싸 보임(PPT 느낌), 효과 시트가 프리뷰를 가림
수정:
- 스티커: `Effects/Sticker3D`(StickerModels 16종 + StickerRenderer3D: SCNRenderer 오프스크린 스냅샷, 고개 5단계 캐시, 저장은 1400px 즉석 렌더), 크기 0.85배, 얼굴 평균 밝기 곱(CIAreaAverage를 그래프 안에서) + 부드러운 그림자. Fluent PNG·tools/stickers 삭제
- 발견: `UIBezierPath(roundedRect:cornerRadius:)`는 반경 ≥ 짧은 변/3이면 다른 곡선 경로를 만들고 **SCNShape가 이를 빈 도형으로 만든다** → 원호로 직접 그린 `StickerShapes.roundedRect` 사용
- 발견: `CIDroste`는 clampedToExtent(무한) 입력이면 출력 nil → 원본 크기 입력
- 선택 UI: 시트 → 셔터 위 가로 스크롤 띠(`EffectPickerStrip`), 스티커 타일은 3D 썸네일
실기기 확인할 것: 3D 스티커 첫 표시 지연(고르면 5각도 백그라운드 렌더), 고개 돌릴 때 각도 방향(`StickerRenderer3D.yawStep` 부호 TODO), 스티커 크기·위치, 라이브 fps·메모리, 저장본 스티커 화질

## 2026-09-26 21:00 · 커밋 e0726d4 → (이번 커밋) · build.sh | test.sh | install-device.sh · R2-S1 효과 40종·Fluent 그림·여러 명
결과: **성공** (build 오류 0 · test **231/231**, skip 1 = 개발용 스티커 미리보기 `EffectPreviewTests`(`TEST_RUNNER_EFFECT_PREVIEW_DIR` 줄 때만)). 실기기 설치 완료
사용자 실기기 관찰(20종 버전): 효과 동작 정상. 스티커 그림이 싸 보임, 두 명 이상일 때 일부 얼굴에 적용 안 됨
원인·수정:
- 여러 명: `FaceDetector.select`가 짧은 변 12% 미만 얼굴을 버림(인물 보정 기준) → `minFaceWidthFraction` 인자 추가, 효과는 3.5%·최대 8명(`EffectKind.maxFaces`), 라이브 효과 트래커도 같은 기준. 얼굴교환은 3명 이상이면 순환
- 그림: Fluent Emoji Color SVG(MIT) → Mac에서 4096 렌더·트림 → 720px PNG 25장(4.3MB, `Resources/Stickers`). 동물 귀·코는 얼굴 SVG 도형 번호로 합성(`tools/stickers/compose.py`)
- `EffectRenderer.filter`는 필터에 없는 키를 넣지 않음(없는 키 setValue는 예외로 앱 종료)
실기기 확인할 것: 스티커 위치(실제 얼굴·옆얼굴·기울임), 단체 사진에서 모든 얼굴 적용·fps, 새 렌즈 6종·팝아트·컬러포인트·눈내림 fps

## 2026-09-26 18:30 · 커밋 ebb558b → (이번 커밋) · build.sh | test.sh | install-device.sh · R1-S8d 메뉴·썸네일 + R2-S1 효과 20종
결과: **성공** (build 오류 0 · test **228/228**: 메뉴 3 + 효과 10 추가, `EnhanceTests.testStageOrderAndHooks` 기대값에 8단계 "effect" 추가). 실기기 설치 완료, 관찰 대기
- R1-S8d: 촬영 화면 [원본]/[인물 ▾]/[배경 ▾] 드롭다운(`CaptureViewModel.selectOriginal/selectPortrait/selectScene`, `look`), 인물 버튼 제거, 썸네일 = 보관함 최근 사진(`loadLatestLibraryThumbnail`), 항상 탭 가능
- R2-S1: `TripShot/Effects/`(EffectKind 20종·FaceAnchors·StickerArt·EffectRenderer·EffectPickerView), `PresetParams.effect`, 파이프라인 8단계 `effectStage`(라이브: 전용 SmoothedFaceTracker + LivePersonSegmenter .fast 2프레임마다 / 저장: 매번 검출·.accurate 분리). 셔터 오른쪽 [효과] 버튼 → 시트 45% 높이(프리뷰 보면서 고름)
실기기 확인할 것: 효과별 라이브 fps(특히 만화·얼굴교환·배경바꾸기), 스티커 위치·크기 계수(`EffectRenderer.stickerLayers`의 fromEyesUp·width 배수), 전면 카메라에서 스티커·거울 방향, 저장본에 효과 반영·사진 앱 되돌리기

## 2026-09-26 16:40 · 커밋 16bbac0 → (이번 커밋) · build.sh | test.sh | install-device.sh · 릴리즈 1 체크포인트 1차 + 사용자 요청 2건
결과: **성공** (build 오류 0 · test **215/215** — 릴리즈 1 체크포인트 197/197 확인 후 새 테스트 18개 추가). 실기기 설치 완료, 실기기 관찰은 진행 중
환경: macOS 26.6.2, Xcode 27.0, iOS 27.0 시뮬레이터 iPhone 17 / iPhone 12 Pro iOS 27.0
오류 요약 (Mac에서 수정, `fix(R1-S8c)` 16bbac0):
- `PortraitUXTests.testEffectivePortraitCustomWinsOverStrength` — 988d8f4(배경 흐림을 칩·직접 값과 분리)에 테스트 기대값이 안 따라감(0 ≠ 15). 코드가 맞고 테스트를 갱신
- `scripts/test.sh` — 테스트가 하나라도 실패하면 xcodebuild가 `simctl diagnose`로 진단 수집하다 600초 타임아웃까지 멈춤 → `-collect-test-diagnostics never`. 이후 테스트 전체 19초
사용자 요청으로 Mac에서 바로 반영(설계 변경 — HANDOFF 결정 이력에 기록):
- **촬영 화면 전체화면**: 9:16 프리뷰를 화면 가운데 크게, 상단 바·하단 조작부는 그라디언트 위 오버레이. 카메라는 **16:9 활성 포맷**(1920×1080, 사진 4032×2268)을 먼저 고르고 없으면 4:3 폴백(`CameraFormatPicker.pick(aspect:)`, `AspectRatio`). 저장본 = 화면 구도. 프리뷰 프레임이 1440×1920 → 1080×1920으로 작아져 fps·발열 개선 기대
- **전신 보정(몸 슬림·다리 길게)**: `Portrait/BodyShape.swift` + Metal `bodyReshape` 워프 커널. Vision `VNDetectHumanBodyPoseRequest`로 어깨·엉덩이·발목 → 엉덩이 아래 세로 최대 +10%(머리가 잘리지 않게 제한, 발목·무릎이 없으면 안 함), 몸 중심선 쪽 가로 최대 약 11% 좁힘(어깨 위로 서서히 0). 강도 칩 자연 15/20·보통 30/40·강함 50/60, 앨범 인물 패널 슬라이더 2개. **저장·앨범 전용**(라이브 미적용)
실기기 확인할 것: 콘솔 "활성 포맷 1920x1080 … 사진 4032x2268", 촬영 사진 크기 4032x2268, 프리뷰 fps, 전체화면 레이아웃(버튼 가림·토스트 위치), 전신 사진 저장 결과(배경 세로선 휨·바닥 늘어남 정도), 강도별 자연스러움

## 2026-09-26 14:30 · 커밋 babd77c · install-device.sh · **iPhone 12 Pro 첫 설치·실기기 관찰**
결과: **성공** — 설치·실행 정상. 실기기 관찰 아래. 저조도(C)는 주간이라 미측정
환경: iPhone 12 Pro (iPhone13,3) iOS 27.0, 개발자 모드 켬, 무료 서명(Personal Team, 7일). Xcode 27.0 명령줄 빌드가 인증서·프로파일 자동 생성
설치 절차에서 만난 것 (모두 해결, `fix(R1-S7)` babd77c):
- 개발자 모드 메뉴는 Xcode가 있는 Mac에 케이블 연결·페어링 후에야 iPhone 설정에 나타남. Devices 창 없이 `xcrun devicectl list devices`로 인식 확인 가능
- `install-device.sh`: `project.yml`의 DEVELOPMENT_TEAM이 비어 있어 명령줄 서명 불가 → 팀 ID를 `scripts/team.local`(gitignore)에서 읽도록 수정. `-quiet` 빌드 성공 시 grep 무출력 → pipefail로 설치 전에 스크립트가 끊기던 버그 수정
- 첫 실행은 "신뢰하지 않는 개발자" → 설정 > 일반 > VPN 및 기기 관리에서 신뢰 후 정상
실기기 관찰 (사용자 확인):
- **S4 라이브**: 프리뷰 방향·색 정상, 탭 포커스·핀치 줌 동작, 촬영 → 사진 앱 "편집됨"·되돌리기·위치·날짜 정상, 가로 촬영 방향 정상, 연속 5장 정상. 프리셋 전환 시 프리뷰 즉시 반영(흑백 확인)
- **S4 성능**: DEBUG 통계 **`20fps · 버림 11+1 · 768px`** — 이미 열 상태 serious(1024→768px 하향)인데도 20fps, 초당 11프레임 GPU 백프레셔 버림 + 카메라 버림 1. **30fps 목표 미달, 발열 심함**(사용자: "발열이 심하긴 하나 되긴 함"). 프리셋별 fps 차이는 없음. 촬영 탭 10분 사용 후 발열 뚜렷
- **S5·S6 인물**: 라이브는 미확인. 앨범 사진 보정(full 경로)은 "잘 됨"
- **S7 저조도**: 설정 탭 "저조도 모델: **있음**" 확인(실기기 `.all` 경로 모델 로드 OK). 야경 저장 품질·3초 기준은 **야간 재측정 필요**. 출력이 0이 아닌지도 그때 확인
- **보정 탭 일괄 저장**: 동작함(소요 시간 미측정)
튜닝 제안(클라우드 세션 R1-S8 검토): (1) `PreviewQuality.baseDimension` 1024 → 768 또는 640을 기본으로(768에서도 20fps라 더 낮춰야 30fps 근접 가능성), (2) `LivePipeline.autoRefreshInterval` 15 → 30, (3) 라이브에서 clarity/sharpness(공간 필터) 반경 축소 또는 생략, (4) 프레임 처리 fps 자체를 30→24로 제한해 발열 완화. Mac 세션은 실측 없이 값을 바꾸지 않고 기록만 남김

## 2026-09-26 10:30 · 커밋 f61c7ac(+fix) · build.sh | test.sh | 모델 변환 · 시뮬레이터
결과: **성공** (build 오류 0 · test **121/121** 통과, skip 0 · Zero-DCE++ 모델 변환·번들 확인). 실기기 설치는 **아직**(아래)
환경: macOS 26.6.2, Xcode 27.0 (27A266a) + **Metal Toolchain 27A266a 추가 설치**, iOS 27.0 시뮬레이터 iPhone 17. Python 3.12 venv(torch 2.14, coremltools 9.x)
오류 요약 (Mac에서 수정, `fix(R1-S7)` 커밋):
- 빌드: `error: cannot execute tool 'metal' due to missing Metal Toolchain` — Xcode 26+는 Metal 컴파일러가 별도 다운로드. `xcodebuild -downloadComponent MetalToolchain` 후 해결. MAC_SETUP §1에 추가 필요(아래 메모)
- `TripShot/Enhance/LowLight.swift:84` — **iOS 27 시뮬레이터에서 Core ML GPU 경로(.all / .cpuAndGPU)가 이 FP16 mlprogram 출력을 전부 0으로 반환** → `testBundledModelEnhancesDarkImage` 실패(출력 = 입력). `.cpuOnly`로는 정상(A −0.336~−0.216, PyTorch와 일치). `#if targetEnvironment(simulator)`에서만 `.cpuOnly`로 변경. 실기기는 `.all` 그대로 — **iPhone 12 Pro에서 실제 출력이 0이 아닌지 확인 필요**(설정 탭 "저조도 모델: 있음" + 야경 저장 결과)
- `scripts/test.sh` — 테스트 호스트 앱이 띄운 **위치 권한 대화상자가 홈 화면에 남아** 다음 xcodebuild가 종료 대기로 10분 이상 멈춤(2회 재현). 테스트 전에 시뮬레이터 부팅 + `simctl privacy grant`(location·camera·photos·microphone)로 해결, 57초에 완료
- `docs/MAC_SETUP.md` §10, `tools/convert_zero_dce.py` 주석 — Zero-DCE++ 코드·가중치는 `Zero-DCE` 저장소가 아니라 **`Zero-DCE_extension`** 저장소에 있음. 주소 정정
모델 변환: `tools/convert_zero_dce.py` 스크립트는 원본 `model.py`와 일치, 수정 없이 동작. 파라미터 10,561개, 합성 야경 샘플에서 PyTorch vs Core ML A 맵 최대 오차 **0.00156**(평균 0.00076, FP16 기준 0.02 이내). `ZeroDCEpp.mlpackage` 52KB 커밋. XcodeGen이 파일 하나로 인식해 `project.yml` 수정 불필요, 앱 번들에 `ZeroDCEpp.mlmodelc` 포함 확인
남은 경고(미수정): `UIRequiresFullScreen` deprecated · `EnhanceViewModelTests.swift:277,296` "no 'async' operations occur within 'await'"(클로저 안 `await vm.cancelBatch()`; 컴파일러가 이 줄 때문에 -quiet 모드에서 `error: … exit code 0 but produced no further output`을 찍지만 빌드·테스트는 정상)
시뮬레이터 관찰: 121개 모두 0.3초 이내. 실기기 측정 항목(fps·발열·인물 워프·10장 일괄·저조도 3초)은 시뮬레이터로 불가
실기기 관찰: **미실시** — 개발자 모드·UDID 등록 후 `scripts/install-device.sh` 예정. HANDOFF "Mac 세션이 할 일" 4번 항목 그대로 남음
메모(MAC_SETUP 보강 제안): §1에 "Xcode 26+는 `xcodebuild -downloadComponent MetalToolchain`" 추가, §9에 "시뮬레이터 테스트 전 `simctl privacy grant`는 test.sh가 자동 처리" 추가 → 이번 커밋에 반영

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

