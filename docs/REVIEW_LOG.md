# 코드 리뷰 로그 (리뷰 세션이 기록, 최신이 위)

형식은 `docs/REVIEW_CHECKLIST.md` 하단 참조.

---

## R3-S5 음원·박자 맞춤·마무리 · 2026-09-27 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 없음)** — 릴리즈 3 체크포인트

### 필수 항목
- 사진 보관함: 내보내기는 기존 `ShortsAssembler.export` 경로 그대로. 음원은 앱 내부 `Documents/Music/`(설계 §4.6). 충족.
- 외부 패키지: YouTubeKit만(이미 선언). project.yml 변경 없음.
- 큐: 다운로드·박자 검출은 백그라운드, SwiftData insert·`@Published`는 메인. 충족.
- 오류 처리: 링크 오류·스트림 없음·다운로드 실패·추출 실패(YouTube 구조 변경) 모두 문구와 "파일 가져오기" 대체 경로. 음악 파일 삭제 시 `musicUnavailable` → 음악 없이 재조립. 충족.
- 설계 일치(§4.4·§4.6): 음악 + 끝 페이드아웃 1.5초, 원래 소리 더킹 0.3, 비트 컷 맞춤(±0.25초, 템플릿 bpm ±20%), 클립보드 제안(PasteButton, 사용자 동작 시만 읽음). 충족.

### 잘한 점
- `snapToBeats`가 전환 겹침을 유지하고 앞 칸 길이만 원본 범위 안에서 조정, 뒤 칸을 그만큼 이동(순수 함수·테스트).
- 박자 검출을 Python으로 같은 로직을 돌려 사전 검증(120/90/128bpm ±0.1).
- 기존 `build` 시그니처는 오버로드로 보존(호출부 무변경).

### 실기기 확인 (Mac, 릴리즈 3 체크포인트)
- YouTubeKit API 이름(`YouTube(videoID:)`, `streams`, `filterAudioOnly()`, `highestAudioBitrateStream()`, `metadata`) — 빌드 오류 시 패키지 소스에서 맞출 것. 실제 링크 가져오기·진행률·제목.
- 실제 곡 bpm 정확도(드럼 약한 곡은 반/두 배 가능), 90초 분석 시간, 비트 컷 템플릿 청감.
- 미리듣기가 `AVAudioSession`을 `.playback`으로 바꾼 뒤 카메라·녹화가 오디오 세션을 되찾는지.
- 음악 포함 내보내기 → 사진 앱 저장(완료 기준), 페이드아웃·더킹 비율.

### 컴파일 확신이 낮은 지점
- `MusicPreviewPlayer`(`@MainActor` + `AVAudioPlayerDelegate` nonisolated 콜백), `MusicTests.testMusicTrackBeatsRoundTrip`(컨테이너 없이 `@Model` 생성 — 문제 시 제외), `PasteButton(payloadType: URL.self)`.

## 릴리즈 1 전체 리뷰 · 2026-09-26 · 커밋 4e2729f · 결과: **통과 (필수 위반 없음 · 수정 권고 3건은 Mac 빌드 전후에 처리)**

범위: `TripShot/**/*.swift`·`*.metal`, `TripShotTests/**`, `project.yml` 전체(약 9,100줄). 기준: REVIEW_CHECKLIST 필수 5항+품질, PLAN §3·§5·§8.2, CLAUDE.md 코드 규칙, BUILD_LOG(시뮬레이터 121/121, iPhone 12 Pro 관찰). **주의: babd77c 이후 커밋(S8a·S8b·S8c, 38파일 +4,160/−271)은 아직 Mac에서 빌드되지 않았다.** 아래 "컴파일 의심"은 각 단계 REVIEW_LOG에 이미 적힌 것 밖의 지점만 적었다.

### 지휘 세션 반영 (커밋 fix(R1-S8c))
- 중간 ① 반영: `PortraitStrength.effective` custom 분기에서 `backgroundBlur = base.backgroundBlur`, 앨범 인물 슬라이더는 칩 5값이 바뀔 때만 `customPortrait` 갱신(`chipValuesDiffer`).
- 중간 ② 반영: `CameraService` 런타임 오류를 `NSError` domain/code로 판정.
- 중간 ③ 반영: 릴리즈 1에서 마이크 권한 요청 제거(릴리즈 2 영상 녹화 시 요청).
- 단계 간 불일치: 수평 자동 보정·JPEG 선택은 PLAN §9(미룬 것)에 명시. 낮음 5건과 죽은 코드 정리는 Mac 빌드 결과와 함께 처리.

### 필수 위반
- 없음.
  - 사진 보관함·앱 내부 저장: 사진이 앱 샌드박스에 남는 경로 없음. `Backup.writeTemporaryFile`은 JSON만, 썸네일·프리뷰는 메모리(NSCache 10장, `EnhanceViewModel.swift:221`)뿐.
  - EXIF·GPS·날짜: 비파괴(`PhotoSaver.swift:321-364`)는 에셋 유지+`ImageMetadata.preservedProperties`(Exif·GPS·TIFF·IPTC·ExifAux·MakerApple, Orientation 1) 복사, 사본(`373-411`)은 `creationDate`·`location` 명시, 촬영(`420-438`)은 바이트 그대로+`AVCapturePhotoSettings.metadata` GPS(`CameraService.swift:516-523`). 실기기에서 위치·날짜 확인됨(BUILD_LOG 09-26).
  - 원본 손상: 모든 경로가 `performChanges` 전에 throw, 삭제 API 호출 없음. 이전 TripShot 편집은 `canHandleAdjustmentData`로 원본에서 재렌더(누적 없음).
  - 외부 패키지: `project.yml` packages는 YouTubeKit만. S8a에서 `UIRequiresFullScreen` 제거 외 변경 없음.
  - 큐 분리: 세션 조작은 `sessionQueue`, 프레임은 `videoQueue`, `@Published`는 `DispatchQueue.main`/`@MainActor`/`onMain`/`receive(on:)`로만 변경(CameraService·LocationProvider·DeviceStatusMonitor·CaptureViewModel·EnhanceViewModel 확인). 비디오 큐 콜백은 `nonisolated static`으로 만들어 메인 액터 객체를 캡처하지 않음(`CaptureViewModel.swift:162-178`).
  - 권한 거부: 카메라(`CaptureView.swift:29,126-137` 안내 화면), 사진(`PhotoSaveError.notAuthorized` → 문구, `EnhanceViewModel.swift:281-285`), 위치(`LocationProvider` 조용히 nil), 마이크(무시). 크래시 경로 없음. 시뮬레이터(카메라 없음)는 `configured=false`로 start가 no-op.
  - 설계 일치: 파이프라인 순서 1~7 고정(`EnhancePipeline.swift:63-90`), 인물 순서 워프→피부→배경 흐림, 저조도·배경 흐림은 `.full`만, 프리뷰=저장 동일 params·context. 차이(라이브 clarity 생략·다운샘플 방식·자동 분석 주기)는 주석으로 문서화됨.

### 버그
- 중간 — `TripShot/Enhance/EnhanceView.swift:384` + `TripShot/Portrait/PortraitStrength.swift:50-53`: 앨범 인물 슬라이더는 **배경 흐림을 포함한** `portrait` 전체를 `services.customPortrait`에 저장하고, `PortraitStrength.effective`는 custom이 있으면 custom의 `backgroundBlur`를 그대로 쓴다 → 앨범에서 배경 흐림을 만지면 촬영 탭 `params.portrait`(`CaptureViewModel.refreshPortrait`)에도 흐림이 들어가 이후 촬영 후처리에 **라이브에 보이지 않던 흐림이 저장**되고 칩이 "직접"으로 바뀐다(반대로 프리셋의 backgroundBlur는 custom이 있으면 사라진다). → `effective`에서 custom 분기에도 `c.backgroundBlur = base.backgroundBlur`, 바인딩은 칩 5값(피부·윤곽·눈·치아·피부톤)이 바뀔 때만 `customPortrait` 갱신. 배경 흐림은 사진별 값으로만 둔다.
- 중간 — `TripShot/Capture/CameraService.swift:212,217`: `note.userInfo?[AVCaptureSessionErrorKey] as? AVError` — userInfo 값은 `NSError`이고 `Any`→`AVError` 브리징 캐스트가 nil이면 `isReset`이 항상 false가 되어 미디어 서비스 재설정(통화 후 등)에서도 재시작을 한 번만 시도한다(추정, 런타임 동작 차이·컴파일은 될 가능성 높음). → `(… as? NSError).map { $0.domain == AVFoundationErrorDomain && $0.code == AVError.mediaServicesWereReset.rawValue }`로 판정.
- 중간 — `TripShot/Capture/CaptureView.swift:72`: 릴리즈 1(사진 전용)인데 첫 실행에 **마이크 권한 프롬프트**가 뜬다(`Permissions.requestMicrophone`). 거부돼도 동작에 영향 없지만 사용자에게 불필요. → 호출을 R2-S1(영상 녹화)로 옮긴다.
- 낮음 — `TripShot/Enhance/EnhanceViewModel.swift:341,668-673`: 비파괴 저장 성공 후에도 `touchedIDs`가 남아 `hasAdjustments == true` → 닫기(×)에서 "조정한 값이 사라집니다" 확인이 저장한 사진에도 뜬다. → `finishSave`에서 `succeededIDs`를 `touchedIDs`에서 제거.
- 낮음 — `TripShot/Settings/SettingsView.swift:182-185`: 설정 탭 첫 진입이 `services.lowLight`(lazy) → Core ML 모델 로드를 **메인에서** 유발(수십~수백 ms 멈칫). `AppServices.swift:43-48`. → `AppServices.init`에서 `Task.detached`로 프리로드하거나 설정 표시는 `Task`로 읽기.
- 낮음 — `TripShot/Library/PhotoSaver.swift:455-463,469-470`: 원본을 `Data`로 전부 읽은 뒤 `CIImage(data:)`로 다시 디코드, HEIF는 `.RGBA16` CGImage(4032×3024 ≈ 97MB)까지 동시 보유 → 12MP 한 장당 피크 약 150MB(잠금으로 1장씩이라 위험은 낮음). → 속성은 `CGImageSourceCreateWithURL`, 이미지는 `CIImage(contentsOf:)`로 바꾸면 Data 사본이 사라진다.
- 낮음 — `TripShot/Enhance/EnhanceViewModel.swift:413-420`: `updateCurrentPortrait`가 `updateCurrentParams`(디바운스 렌더 예약) 직후 `scheduleRender(debounce:false)`를 또 걸어 첫 예약을 취소함 — 결과는 맞지만 중복. → `updateCurrentParams` 호출을 직접 갱신으로 바꾸거나 두 번째 호출 제거.
- 낮음 — `TripShot/Capture/CaptureViewModel.swift:534-540`: 얼굴 마커 루프가 `rects`가 비면 `faceMarkerImageSize`를 갱신하지 않아 카메라 전환(3:4 유지)엔 문제없지만 프레임 크기가 바뀐 직후 첫 마커가 이전 크기 기준으로 한 프레임 그려질 수 있음(0.25초, 시각적 영향 미미).

### 컴파일 의심 (각 단계 로그에 없는 것만 · Mac 빌드에서 확인)
- `TripShot/Capture/CameraService.swift:212` — `as? AVError`(위 버그 항목). 컴파일은 되더라도 판정 실패 가능.
- `TripShot/Library/Backup.swift:215-217,269,288,306,342` — `FetchDescriptor<Preset>(sortBy: [SortDescriptor(\.sortOrder)])`의 축약 키패스 추론. 실패하면 `\Preset.sortOrder`처럼 루트 타입 명시(추정, 낮음).
- `TripShot/Capture/DeviceStatusMonitor.swift:121` — `center.publisher(for: .NSProcessInfoPowerStateDidChange)`: 이름은 `NSNotification.Name.NSProcessInfoPowerStateDidChange`로 존재. 추론 실패 시 `Notification.Name.NSProcessInfoPowerStateDidChange`로.
- `TripShot/Capture/DeviceStatusMonitor.swift:149-150` — `URLResourceValues.volumeAvailableCapacityForImportantUsage`(`Int64?`) 타입 일치(추정 OK).
- `TripShot/Capture/CaptureView.swift:264-289` — `@ViewBuilder var` 안 `if let … { let collapsed = … ; Button … }` 지역 `let`(Swift 5.4+ 허용, 추정 OK). `:100` `.onChange(of: [DeviceWarning.Kind])` Equatable OK.
- `TripShot/Settings/SettingsView.swift:44-52` — `confirmationDialog` message 클로저의 `if let`(ViewBuilder) / `:154` `ShareLink(item: URL)` / `:111,164,181-187` `LabeledContent(String, value: String)` — 모두 iOS 16+ API, 추정 OK.
- `TripShot/App/SigningInfo.swift:75-76` — `data.range(of: Data, in: Range)` 라벨(options 생략) 추정 OK.
- `TripShot/Capture/CaptureViewModel.swift:117-121,128-137` — `camera.$isFrontCamera`(S8a 기록됨)와 같은 패턴의 `deviceStatus.$thermalState`·`$isLowPowerMode`(`private(set)` @Published의 `$`). 하나가 실패하면 셋 다 같은 수정(`private(set)` 제거 또는 `objectWillChange` 경유).
- `TripShot/Enhance/EnhanceViewModel.swift:509-513,545-558` — `@MainActor` 클래스 안 `Task.detached` + `withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }`(S3에서 같은 패턴 컴파일됨, OK).
- `TripShot/Portrait/BackgroundBlur.swift:87-91` — `CIContext.render(_:toBitmap:rowBytes:bounds:format:colorSpace:)`에 `colorSpace: nil`(옵셔널 인자, OK).
- 테스트: `TripShotTests/ReleaseTests.swift`·`PortraitUXTests.swift`·`CameraLensTests.swift`·`SkinBrightenTests.swift`(+약 70개, 총 약 190개 추정) 미빌드. `AppServices(defaults: UserDefaults(suiteName:))`로 격리됨(`.standard` 오염 없음) 확인.

### 단계 간 불일치
- **PLAN §3.2 7단계 "수평 자동 보정(Vision 수평선 검출)" 미구현**: `PipelineContext.horizonAngle`을 채우는 코드가 없고 모든 저장 호출이 `horizonAngle: nil`(`EnhanceViewModel.swift:115,117,133,135`, `CaptureViewModel.swift:472`), `PresetParams.autoHorizon`(`Models.swift:21`)은 어디서도 true가 되지 않는다(`applyHorizon`·크롭 계산·테스트만 존재). R1-S1 완료 기준엔 "수평" 파이프라인 단계만 있었으므로 위반은 아니나, **릴리즈 1에서 빠진 기능**으로 PLAN §9(미룬 것) 또는 HANDOFF "논의 필요"에 명시 필요.
- PLAN §3.4 "촬영은 HEIF(기본) 또는 JPEG 선택", §5 설정 "촬영 옵션(해상도·포맷)": 포맷 선택 없음(`CameraService.swift:506-510` HEVC 가능하면 고정). 릴리즈 1 범위 결정 기록 필요.
- `CameraService.swift:159-161,638-652`: `locationProvider`·`photoSaver`가 옵셔널이고 미주입 시 폴백 저장 경로(PHAssetCreationRequest 직접)가 남아 있으나 앱은 항상 주입(`CaptureViewModel.configure`) → 죽은 코드. 폴백을 지우고 비옵셔널로 하면 `postCaptureHandler` 누락 경로도 사라진다.
- `PhotoSaving`(`EnhanceViewModel.swift:102-125`): 프로토콜 요구 `saveNonDestructive/saveAsCopy(3인자)`는 앱에서 기본 구현만 사용하고 FakeSaver는 `XCTFail`로 채움. ViewModel은 4인자 `save`를 호출하고 기본 구현이 3인자 요구사항으로 동적 디스패치 → 테스트 대역과 정합(확인). 정리하려면 요구사항을 `save(item:mode:params:context:)` 하나로 줄인다.
- hook·컨텍스트 시그니처 정합 확인(문제 없음): `PortraitStage.full(detector:kernels:segmentationPreview:)`·`.live(tracker:kernels:)` ↔ `AppServices.pipelineContext`; `LowLightStage.make(enhancer:)` ↔ `PipelineContext.lowLightStage`; `EnhanceRenderer.previewImage(from:params:maxDimension:context:)` ↔ `EnhanceViewModel.scheduleRender`; `PhotoSaver.saveNonDestructive(asset:params:horizonAngle:context:)` ↔ `CaptureViewModel.run`; `SmoothedFaceTracker.normalizedRects`·`lastFaceRects` ↔ `EnhanceViewModel.detectFaceRects`·`CaptureViewModel.startMarkers`; `MetalPreviewView.fitRect` ↔ `FaceZoomGeometry`·`FaceMarkerGeometry`; `PortraitParams` 필드 7개 ↔ `AdjustmentKind.keyPath`·`PortraitStrength`·`SettingsExport`; `CameraFormatPicker.pick`·`LensZoom` ↔ `CameraService`. `Mapping.referenceDimension`(1024)·`PreviewQuality.baseDimension`(768)·`EnhanceViewModel.previewDimension`(1024)은 `resolutionScale`로 정합.
- 오류 문구 위임(`PhotoSaveError`·`EnhanceSaveError`·`CameraError`·`BackupError`.`errorDescription` → `UserMessage.text(for:)`): `text(for:)`가 각 타입을 먼저 매칭하므로 재귀 없음(확인).

### 권고
- (수정 권고, 릴리즈 전) 위 "중간" 3건: 배경 흐림의 custom 전파 차단, `AVError` 판정, 마이크 권한 R2로 이동.
- `EnhanceViewModel.startRestoreIfNeeded`(`:570-585`) → `PhotoImageLoader.previousAdjustment`가 표시하는 사진마다 `PHContentEditingInput`을 네트워크 허용으로 요청해 iCloud 전용 원본을 통째로 내려받는다(알려진 TODO). 여행 중 셀룰러를 고려해 복원 확인은 `isNetworkAccessAllowed = false`로 두고, 저장 시에만 내려받는 쪽을 권한다.
- 앨범 프리뷰 렌더가 `EnhanceRenderer` 잠금을 촬영 후처리(12MP, 1~3초)와 공유한다(`EnhanceRenderer.swift:55,87`). 촬영 직후 보정 탭으로 가면 슬라이더 반응이 후처리 끝날 때까지 멈춘다 — 실기기에서 체감되면 프리뷰 전용 `CIContext`(MetalPreviewView처럼) 분리.
- `MetalPreviewView.swift:122` 프리뷰 출력 sRGB(P3 화면) — 저장본과 채도 차이가 보이면 TODO대로 `CAMetalLayer.colorspace = displayP3`. `PhotoSaver.swift:468` 16비트→HEIC 10비트 기록 여부 TODO 유지.
- 죽은 코드: `CameraPreviewView.swift`(폴백으로 문서화됨, 유지 가능), `CameraService` 미주입 폴백(위), `EnhanceRenderer.previewImage(from:params:maxDimension:)` 컨텍스트 없는 오버로드(앱 미사용, 테스트 전용 추정).
- `try?` 점검: `SettingsView.swift:241` 프리셋 삭제 `save` 실패 무음, `Models.swift:77` 프리셋 디코드 실패 시 기본값으로 조용히 대체(손상 프리셋이 "자동"처럼 보임) — 낮음, 로그 한 줄 권장. 그 밖의 `try?`는 폴백·로그가 있다.
- 한국어 UI 문자열·주석: 전 파일 충족. 파일 위치: 모듈 폴더 규칙 충족, `.gitkeep` 없음.

### 종합 판단
- **릴리즈 1 체크포인트로 보낼 수 있다.** 필수 위반 없음, 원본·메타데이터 원칙 준수, 큐 규칙 준수. 다만 S8a·S8b·S8c 약 4,160줄이 미빌드이므로 "통과"는 리뷰 기준이며 Mac 빌드가 릴리즈 게이트다. 중간 3건은 클라우드 세션이 Mac 빌드 결과와 함께 `fix(R1-S8c)`로 처리하기를 권한다.
- Mac에서 먼저 볼 것 3개:
  1. **빌드**: `scripts/build.sh` → 오류는 S8a·S8b 로그의 "컴파일 확신이 낮은 지점" + 위 "컴파일 의심" 순으로(`$isFrontCamera`류 `private(set)` `$`, `PortraitParams` CodingKeys/extension `init(from:)`, `VNGeneratePersonSegmentationRequest.outputPixelFormat`, `as? AVError`, `SortDescriptor(\.sortOrder)`). `scripts/test.sh` 기대 약 190개.
  2. **실기기 낮**: 활성 포맷 로그 "1920x1440 … 사진 4032x3024"·"촬영 사진 크기 4032x3024", 768px에서 fps·버림·10분 발열 재측정, 렌즈 0.5×/1×/2×·전면 전환(프리뷰 미러·저장 사진 비반전·탭 노출 위치·얼굴 마커 좌우), 인물 모드에서 배경 흐림 방향(사람이 아니라 배경이 흐려지는지, `BackgroundBlur.swift:133` TODO)과 `hasPerson` 판정, 24fps 설정·저전력 모드 전환 시 예외 없음(`applyFrameRate` min/max 순서).
  3. **실기기 밤**: 야경 프리셋 저장 3초 이내·설정 "마지막 저조도 경로: 모델"·과노출/색 편이, 어두운 곳 프리뷰 밝기(최대 프레임 간격 1/15 수정 확인), 20분 연속 촬영 후 프리뷰 멈춤 감시(`PreviewStallDetector`)·세션 중단(전화) 복귀 안내.

## R1-S8b 인물 모드 기능·UX · 2026-09-26 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 없음)**

### 필수 항목
- 사진 보관함·메타데이터: 미접촉(저장 경로는 `PhotoSaver` 그대로). 외부 패키지·project.yml 변경 없음.
- 큐 분리: 라이브 바이패스는 기존 잠금 한 번에 함께 읽음(프레임당 추가 비용 없음). 얼굴 마커는 트래커의 잠금 보호 값을 0.25초마다 메인에서 읽음. 인물 분리는 `.full`에서만(라이브 호출 경로 없음, 테스트로 고정). 충족.
- 설계 일치(§3.3 갱신분): 강도 칩 3단계, 배경 흐림 저장·앨범 전용(프리뷰 `.balanced`/저장 `.accurate`), 워프 → 피부 → 배경 흐림 순서(워프 후 이미지로 분리해 줄어든 턱선 바깥이 배경으로 잡힘 — 타당), 얼굴 0명이어도 사람 분리로 배경 흐림 동작, UX 6건. 충족.
- 우선 규칙: 인물 모드 켜짐 시 칩/직접 값이 프리셋 값보다 우선하되 "원본"(enabled=false)은 덮어쓰지 않음 — 원본이 후처리 대상이 되는 것을 막는 예외로 타당.
- 프리셋 JSON 호환: `backgroundBlur` decodeIfPresent. 충족.

### 잘한 점
- 인물 분리 입력을 1536으로 줄여 Vision 비용 억제, 마스크 최대값으로 "사람 없음" 판정 후 nil.
- 프리뷰/저장 hook을 `PipelineContext.isPreview`로 고르는 구조(클로저가 컨텍스트 생성 시점에 정해지는 문제를 해결).
- 길게 누르기 직후 0.35초 탭 무시로 UIKit 탭 인식기와의 충돌 회피.

### 권고 (실기기 B4)
- 배경 흐림 강도 100의 반경(긴 변 × 1.2%)이 약하면 0.02로. 머리카락·어깨 경계 페더(0.3%) 확인.
- 촬영 후처리에서 배경 흐림 값이 있으면 프리뷰에 없던 흐림이 저장본에만 생김(설계상 의도). 사용자 혼란이 있으면 촬영 화면에 "저장 시 배경 흐림" 작은 표시 추가.
- 전면 카메라에서 얼굴 마커 좌우가 반대면 `mirrored: vm.isFrontCamera`로.

### 컴파일 확신이 낮은 지점
- `VNGeneratePersonSegmentationRequest.outputPixelFormat`, `CIAreaMaximum` 출력 원점, OneComponent8 → CIImage 채널 해석(grayscale이 흡수), `confirmationDialog` 바깥 탭 처리.

## R1-S8a 라이브 성능·렌즈·사용자 요청 4건 · 2026-09-26 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 1건)**

### 필수 항목
- 사진 보관함·메타데이터: 촬영 저장 경로 변경 없음. 활성 포맷을 작게 골라도 `photoOutput.maxPhotoDimensions`·`settings.maxPhotoDimensions`로 12MP 유지. 전면 사진은 미러 안 함(EXIF·방향 태그 정상). 충족.
- 외부 패키지·project.yml: `UIRequiresFullScreen` 제거만. 충족.
- 큐 분리: 카메라 전환·포맷·줌은 세션 큐, `@Published`는 메인, 미러 플래그는 잠금. 충족.
- 원본 손상·권한: 해당 없음.
- 설계 일치: PLAN §3.1 렌즈 한 줄 반영. 라이브에서 clarity 생략은 프리뷰 한정이며 후처리(.full)는 그대로(주석 명시). 충족.

### 직접 수정한 것
- `CameraService.applyFrameRate`: 최대 프레임 간격까지 1/fps로 고정하던 것을 **최소 간격만 1/fps, 최대 간격은 1/15(포맷 하한과 비교)**로 변경. 어두운 곳에서 자동 노출이 프레임 레이트를 낮춰 노출 시간을 늘릴 수 있게 함(야간 프리뷰 밝기·노이즈).

### 잘한 점
- 포맷 선택을 순수 함수로 분리하고 12MP 사진 지원을 필수 조건으로 둬 화질 손실 없이 폴백.
- 표시 배율↔videoZoomFactor 환산을 분리해 12 Pro 트리플 [2, 4] 기준 테스트.
- 피부톤 강도를 한 번만 곱함(이중 감쇠 방지), 닫기 확인은 사용자가 직접 손댄 값 기준.

### 실기기 재측정 (Mac, B3)
- 콘솔: "활성 포맷 1920x1440 … 사진 4032x3024", "프리뷰 프레임 크기 1440x1920", "촬영 사진 크기 4032x3024". 폴백 로그가 보이면 보고.
- fps 기대: nominal 768px에서 28~30fps, GPU 버림 0~2. 10분 사용 후 열 상태 비교.
- 렌즈 0.5×/1×/2× 전환·시작 1×, 핀치, 전면 미러·저장 사진 비반전·탭 노출 위치·가로 셀피 방향.
- 야간 프리뷰가 이전보다 어둡지 않은지(프레임 간격 수정 확인).

### 컴파일 확신이 낮은 지점
- `camera.$isFrontCamera`(`@Published private(set)`의 `$`), `{ @MainActor id in … }` 클로저 대입, `PortraitParams`의 CodingKeys(본문)+`init(from:)`(extension) 구성, `photos-redirect://` 동작.

## R1-S7 저조도 · 2026-09-26 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 없음)** — 모델 변환은 Mac 대기

### 필수 항목
- 사진 보관함·메타데이터: 미접촉. 외부 Swift 패키지·project.yml 변경 없음(`.gitignore`에 `*.mlmodelc` 추가만).
- 큐: `LowLightEnhancer`는 잠금으로 예측 직렬화, 입력 버퍼 재사용. 파이프라인 hook 호출 시점(그래프 구성 시)에 512 렌더·예측이 동기로 일어나며 `EnhanceRenderer` 잠금 안에서 실행됨 — 저장 경로에 적합. 충족.
- 실패 시 건너뜀: 모델 없음·커널 없음·예측 실패 모두 감마+섀도우 폴백으로 동작하고 사유를 로그·`lastPath`에 기록. 충족.
- 설계 일치(§3.2): 5단계 위치, `lowLight > 0`일 때만, 라이브(.live)에서는 비활성, 저장·앨범(.full)에서만. 모델 입력 512·타일 없음(곡선 적용은 픽셀 단위 커널이라 풀해상도 1패스)은 타당. 충족.
- 곡선 방향: 원 코드 `x + A·(x² − x)`에서 A<0이 밝힘. 지시안(A=1이 밝힘)이 틀렸고 서브에이전트가 코드 기준으로 바로잡음. 테스트도 그 기준.

### 잘한 점
- 작업 색공간이 선형 P3이므로 커널 안에서 감마 변환 후 곡선 적용, 0~1 밖 값은 보존(확장 색역).
- 변환 스크립트가 `CurveNet`으로 A 맵까지만 내보내고 업샘플·곡선은 Swift 담당 → 어떤 해상도에도 대응.
- 출력 dtype(float16/32)·입력 이름 폴백 처리.

### 권고 (Mac 변환·실기기 B5)
- `tools/convert_zero_dce.py` 실행 후 `--check`로 최대 오차 ≤ 0.02 확인, `.mlpackage` 커밋(약 40KB). XcodeGen이 `.mlpackage`를 단일 파일로 잡는지(`docs/MAC_SETUP.md` §10-5).
- 모델 입력 버퍼 방향(`testModelInputKeepsOrientation`)이 실패하면 `CIRenderDestination.isFlipped = true`.
- 야경 프리셋(lowLight 70)으로 어두운 장면 저장 3초 이내, 과노출·색 편이·노이즈 증폭 확인. 과하면 프리셋 값을 50으로.
- 첫 `.full` 컨텍스트 생성 시 모델을 메인에서 lazy 로드한다. 지연이 느껴지면 `AppServices.init`에서 백그라운드 프리로드.

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- `EnhanceKernels.metal`의 `static inline` 헬퍼·동적 반복문(`int(iterations)`)이 `-fcikernel`에서 허용되는지. 막히면 인라인·8회 고정.
- `CIRenderDestination(pixelBuffer:)` 기본 방향, `MLFeatureValue(pixelBuffer:)` 입력 이름 매칭.
- 스크립트의 레이어 이름(`e_conv1`~`e_conv7`)이 원 저장소와 같은지.

## R1-S6 인물 모드 ② 윤곽 · 2026-09-26 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 없음)**

### 필수 항목
- 사진 보관함·메타데이터: 미접촉. 외부 패키지·project.yml 변경 없음. 큐: 순수 함수 + 무상태 커널. 권한: 해당 없음.
- 설계 일치(§3.3): 턱선·광대 좌우 3점을 얼굴 축 기준 대칭으로 축 쪽에 밀기, 눈 원형 확대, 반경 밖 변위 0(배경 보호), 강도 0에서 입력 그대로(같은 객체). 다인 최대 5명·겹침 감쇠. 충족.
- 부호 검증: 커널 `p' = p − d·k·w` → 입력 q의 내용이 출력 q + d·k에 나타나므로 내용이 d(축 쪽) 방향으로 이동 = 턱 축소. 확대는 `p' = c + (p−c)(1 − s·w)` → 중심부 확대. `forwardMap = q − Δ(q)`도 일치. 정확.
- 순서: 워프 → 랜드마크·박스를 순방향 근사로 이동 → 피부 마스크. R1-S5 권고 반영.

### 잘한 점
- 워프 커널을 영향 사각형에서만 계산하고 원본 위에 합성(풀해상도 비용 억제). ROI 콜백이 최대 변위만큼 확장.
- 밀기 중심을 얼굴 안쪽으로 6% 이동해 배경에 걸리는 반경 축소.
- 기울인 얼굴에서도 축을 랜드마크로 계산해 대칭 유지(30° 테스트 포함).

### 권고 (실기기 B4)
- 기본 `faceSlim 20`이 모든 프리셋에 켜져 있어 인물 모드를 켜면 항상 윤곽 축소가 들어간다. 과하면 기본을 10으로.
- 반경 0.28·강도 0.035·안쪽 이동 0.06은 셀피로 튜닝. 턱선 주변 배경(문틀·수평선) 휨 확인.
- Vision `faceContour` 점 순서(귀→턱→귀)·개수 가정 확인. 라이브에서 추적 떨림에 따른 워프 흔들림 확인(필요하면 랜드마크 EMA α를 낮춤).
- 단체 사진 겹침 감쇠가 과한지 확인(붙어 선 경우 10~20% 감쇠).

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- 인자 14개 `CIWarpKernel`에 `CIVector` 2·4성분 전달, `-fcikernel`의 inline 헬퍼(R1-S5와 동일 조건). `testWarpKernelChangesOnlyInsideRadius`가 검증.
- SF Symbol `face.dashed`.
- `PortraitTests.testPortraitStageFullWithZeroStrengthIsIdentity`는 기본 faceSlim 20으로 Vision 검출을 거친다(체스판이라 얼굴 없음 → 입력 그대로 기대).

## R1-S5 인물 모드 ① 피부 · 2026-09-26 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 없음)**

### 필수 항목
- 사진 보관함·메타데이터: 저장 경로 변경 없음(§3.4 미접촉). 앨범 저장이 `PhotoSaver`의 `context:` 경로로 프리뷰와 같은 컨텍스트를 넘기도록 연결(R1-S3 권고 반영). 충족.
- 원본 손상 경로: 없음(순수 함수).
- 외부 패키지: 없음. `project.yml`은 사전 허용한 Metal 컴파일 플래그 2줄만 변경(`MTL_COMPILER_FLAGS=-fcikernel`, `MTLLINKER_FLAGS=-cikernel`).
- 큐 분리: `SmoothedFaceTracker`는 비디오 큐 전용 상태 + 잠금 보호 `faceCount`. `FaceDetector`는 무상태. 충족.
- 권한: 해당 없음.
- 설계 일치(§3.2·§3.3): 3단계 위치, 선명도는 피부 마스크 바깥에만(`applySharpen(skinMask:)`), 얼굴 없으면 무동작, 다인 최대 5명, 눈·입 안쪽 제외, 라이브 경량 경로. 충족. 주파수 분리를 "밴드 제거(low + input − mid)"로 바꾼 것은 지시안(선형 블러라 질감까지 잃음)보다 타당.

### 잘한 점
- 마스크를 얼굴 주변 영역만 원본 해상도로 그리고 블러도 그 영역에서만 계산(풀해상도 비용 억제).
- 검출은 1024(저장)/640(라이브) 다운샘플로 하고 좌표를 원본 스케일로 환산.
- "원본" 프리셋에서 인물 보정을 끔 → 라이브 프리뷰와 촬영 후처리(identity 건너뜀) 일치.

### 권고 (실기기·다음 단계)
- (B4 실기기) 라이브 검출이 비디오 큐에서 동기로 돌아(3프레임마다) Vision 지연(A14에서 수십 ms)만큼 프레임이 버려진다. fps가 부족하면 검출을 별도 큐에서 비동기로 돌리고 마지막 결과를 쓰는 구조로 바꿀 것.
- (B4 실기기) 앨범 프리뷰는 렌더마다 검출한다(슬라이더 조작 시 80ms 디바운스마다). 지연이 느껴지면 사진별 검출 결과 캐시.
- (B4 실기기) `Cr ≤ 173` 상한으로 붉은 잡티가 마스크에서 빠질 수 있음. 12% 최소 얼굴 너비도 단체 사진에서 확인.
- (R1-S6) `PortraitStage.isActive`에 `faceSlim`·`eyeEnlarge` 추가. 워프는 피부 보정 **전에**(랜드마크 좌표가 원본 기준이므로 워프 후 마스크는 워프된 좌표로 다시 그리거나, 워프를 마지막에 적용하고 마스크도 같은 워프를 통과시킴) 순서를 정할 것.

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- Metal: `-fcikernel` 빌드에서 커널 네임스페이스 밖 `inline` 헬퍼 허용 여부, `default.metallib` 생성. `testSkinLikelihoodKernel` 실패 시 여기부터.
- `CGContext` 8비트 `linearGray` + alpha none 생성 여부(실패 시 `CGColorSpaceCreateDeviceGray()`).
- `VNImageRequestHandler(ciImage:orientation:options: [.ciContext: ...])`, `CIColorKernel(functionName:fromMetalLibraryData:)`, `CIFilter.multiplyCompositing()`, SF Symbol `mouth`.

## R1-S4 라이브 보정 프리뷰 · 2026-09-26 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 1건)**

### 필수 항목
- 사진 보관함·메타데이터: 촬영 원본은 재인코딩 없이 저장, 보정본은 `PhotoSaver.saveNonDestructive(context:)`로 같은 에셋 비파괴. 충족.
- 원본 손상 경로: 없음(후처리 실패 시 원본은 이미 저장됨, 메시지에 명시).
- 외부 패키지: 없음. project.yml 변경 없음.
- **큐 분리**: 세션 큐(구성·촬영·줌·포커스), 비디오 큐(프레임 → LivePipeline → Coordinator.submit), 메인(`@Published`·MTKView draw). 프레임 콜백은 `nonisolated static`으로 만들어 메인 액터를 캡처하지 않음. 잠금 보호 상태(handlerLock, LiveSettings, Coordinator lock) 분리 적절. 충족.
- **백프레셔**: 1차 `alwaysDiscardsLateVideoFrames`, 2차 `LockedFrameGate(limit 1)`로 "프레임 도착 ~ GPU 완료" 구간에 1장만. GPU 완료 핸들러에서 해제, draw 미호출·비활성·뷰 분리 경로에서도 해제. 충족.
- 회전·미러: `videoRotationAngle = 90`(세로), 미지원 시 `.oriented(.right)` 폴백, 미러 명시적 off. 사진은 `RotationCoordinator`로 기기 방향 반영. 충족.
- 권한 거부: 기존 화면 유지. 충족.
- 설계 일치: 프리뷰·후처리가 같은 params·context로 `EnhancePipeline.apply` 호출("보이는 대로 저장"). 셔터 순간 설정을 tag로 보관해 연속 촬영 중 프리셋 변경에도 정확. 자동 보정 분석을 15프레임마다 재사용하는 것은 성능상 타당(적용 코드는 저장과 동일). 충족.

### 직접 수정한 것
- `MetalPreviewView.Coordinator.render(in:)`: `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)`는 Core Image 좌하단 원점이 Metal 텍스처 좌상단에 매핑되어 **위아래가 뒤집혀 보이는 알려진 동작**. `CIRenderDestination(mtlTexture:commandBuffer:)` + `isFlipped = true` + `startTask(toRender:to:)`로 교체. 실기기에서 반대로 보이면 `isFlipped`만 뒤집으면 됨.

### 권고 (다음 단계·실기기)
- (B3 실기기) DEBUG 상단 통계로 프리셋별 fps 확인. 30fps 미달이면 `PreviewQuality.baseDimension`을 768로 낮추는 것이 첫 조치, 다음은 `autoRefreshInterval` 증가.
- (B3 실기기) `.photo` 프리셋의 프레임 크기 로그 확인. 4032×3024로 오면 `EnhanceRenderer.downsample`(Lanczos) 비용이 큼 → `session.sessionPreset`을 `.hd1920x1080` 또는 `activeFormat` 선택으로 바꾸고 촬영 화질은 `AVCapturePhotoOutput`이 별도로 보장하는지 확인.
- (B3 실기기) 프리뷰 색: sRGB 출력. 채도가 사진 앱 원본과 다르면 CAMetalLayer colorspace를 P3로.
- (R1-S5) 인물 모드 hook이 실제 필터로 바뀌면 라이브 경량 경로(양방향 필터)는 `LiveSettings.context.portraitStage`에 별도 클로저를 넣는 방식으로 분기.

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- `AVCaptureDevice.RotationCoordinator(device:previewLayer: nil)`, `videoRotationAngleForHorizonLevelCapture`.
- `MainActor.assumeIsolated`, `MTKViewDelegate`의 액터 격리 표시 여부(별도 `ViewDelegate`로 우회).
- `CIRenderDestination` API(리뷰에서 교체한 부분), `MTKView.draw()` 수동 호출 시 `draw(in:)` 동기 호출 여부.
- `MagnifyGesture`(iOS 17+).

## R1-S3 앨범 보정 화면 · 2026-09-25 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 1건, 문구)**

### 필수 항목
- 사진 보관함·메타데이터: 저장은 전부 R1-S2 `PhotoSaver` 경유. 읽기는 `PHImageManager`(다운샘플)와 `PHContentEditingInput`(편집값 복원)뿐. 충족.
- 원본 손상 경로: 없음. 일괄 저장 취소는 현재 장 완료 후 중단(트랜잭션 도중 취소 없음). 충족.
- 외부 패키지: 없음. project.yml 변경 없음.
- 큐 분리: ViewModel `@MainActor`, 렌더는 `Task.detached`, 결과 반영은 메인. PhotoKit 콜백은 continuation으로 한 번만 재개(ImageRequestBox). 충족.
- 권한 거부: 사진 권한 거부 시 목록 비우고 안내. 충족.
- 설계 일치: 인물 모드 스위치는 `AppServices.portraitModeEnabled`(앱 상태)로 hook을 nil/placeholder 전환(R1-S1 권고 반영). 프리셋 스트립·슬라이더 7종·전/후 길게 누르기·비파괴/사본/일괄 저장·진행률·취소 모두 있음. 충족.

### 직접 수정한 것
- `CaptureView`의 쇼츠 모드 안내 문구 "P1에서" → "릴리즈 2에서".

### 잘한 점
- 메모리: ViewModel은 1024px 다운샘플만 보관(NSCache 10장). 풀해상도는 PhotoSaver가 파일에서 한 장씩.
- 이전 TripShot 편집이 있는 사진은 `.unadjusted` 원본으로 프리뷰해 저장(원본에서 재렌더)과 일치.
- 사용자가 손댄 사진은 늦게 도착한 복원값이 덮어쓰지 않음(`touchedIDs`).

### 권고 (다음 단계)
- (R1-S5) 저장 경로는 렌더러의 공유 컨텍스트(portraitStage=nil)를 쓴다. 인물 보정이 실제로 생기면 `PhotoSaver`가 `PipelineContext`를 인자로 받도록 확장(ViewModel에 TODO 표시됨).
- (B1 실기기) iCloud 전용 사진의 편집값 복원이 원본 전체를 내려받는다. 체감이 크면 로컬 사진만 복원.
- (R1-S4) `AppServices.selectedPresetID`를 촬영 탭 프리셋 스트립과 공유할 것.

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- `PhotosPicker(selection:maxSelectionCount:selectionBehavior:matching:preferredItemEncoding:photoLibrary:label:)` 인자 순서, `.ordered`.
- `withTaskCancellationHandler { } onCancel: { }` 트레일링 클로저 문법, `@escaping @MainActor () -> PipelineContext` 기본값.
- `PHContentEditingInput.adjustmentData` 옵셔널 여부.
- 동기 `@MainActor` XCTest 메서드.

## R1-S2 저장·메타데이터 · 2026-09-25 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 없음)**

### 필수 항목
- **사진 보관함·메타데이터 보존(§3.4)**: 비파괴 편집은 `PHContentEditingOutput`+`PHAdjustmentData`로 같은 에셋에 얹어 촬영일·위치·EXIF가 자동 유지되고, 렌더 파일에도 Exif/GPS/TIFF/IPTC/ExifAux/MakerApple을 복사. 사본 저장은 `creationDate`·`location`을 원본 에셋(없으면 파일 메타)에서 설정. 촬영은 재인코딩 없이 원본 바이트 저장 + 촬영 시 GPS를 `AVCapturePhotoSettings.metadata`에 기록. **충족.**
- **원본 손상 경로 없음**: 원본 파일은 읽기만, 쓰기는 PhotoKit이 준 URL에만, `performChanges`는 렌더·인코딩·파일 쓰기 후 마지막 한 번. 충족.
- 외부 패키지: 없음. project.yml 변경 없음.
- 큐 분리: `pendingLocations`는 세션 큐에서만 접근, `@Published`는 메인에서만 변경. LocationProvider 델리게이트 → 메인 디스패치. 충족.
- 권한 거부: 사진 보관함 거부는 `notAuthorized`로 throw, 위치 거부는 nil 유지. 충족.
- 설계 일치: 충족. 요청과 다르게 한 10개 항목 모두 타당(course→GPSTrack, 고도 유효성 검사, 수평각을 adjustContext로 전달 등).

### 권고 (다음 단계)
- (R1-S3) `LocationProvider`·`PhotoSaver`를 앱에서 생성해 `CameraService`에 주입하는 연결이 아직 없음. R1-S3에서 앱 수준 의존성 컨테이너(`AppServices`)를 만들어 연결할 것.
- (R1-S3) 비파괴 편집 입력이 이전 TripShot 편집이면 `input.adjustmentData`에서 `AdjustmentPayload`를 복원해 슬라이더 초기값으로 쓸 것(현재는 읽지 않음).
- (B2 실기기) 16비트 렌더 → HEIC가 실제 10비트로 기록되는지, 사진 앱 정보 패널에 위치·날짜가 유지되는지, "원본으로 되돌리기"가 동작하는지 확인.

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- `PHContentEditingOutput.supportedRenderedContentTypes` / `renderedContentURL(for:)` (iOS 17+) 이름·throws 여부.
- `#available(iOS 17, *)` 분기는 배포 대상이 26이라 경고 가능(오류 아님).
- `CGImageSourceCopyPropertiesAtIndex` 결과의 하위 딕셔너리를 `as? [CFString: Any]`로 캐스팅하는 부분.

## R1-S1 보정 엔진 · 2026-09-25 · 서브에이전트(Opus 5.5) 작성분 · 결과: **통과 (수정 1건 반영)**

### 필수 항목
- 사진 보관함·메타데이터: 이 단계는 CGImage까지만 만들고 저장은 R1-S2 담당. 위반 없음.
- 외부 패키지: 추가 없음. project.yml 변경 없음.
- 큐 분리: 렌더러는 NSLock으로 직렬화, UI 미접촉. 해당 없음.
- 원본 손상 경로: 없음(순수 함수).
- 권한: 해당 없음.
- 설계 일치: PLAN §3.2 순서(1~7) 고정, 강도 0 = 무적용 보장. 일치.

### 직접 수정한 것
- `EnhancePipeline.applyAuto`: `autoAdjustmentFilters` 옵션에 `.crop: false, .level: false` 추가. 자동 크롭·기울기 필터가 섞여 7단계 수평 보정과 겹치는 것을 방지.

### 권고 (다음 단계에서 처리)
- (R1-S3/S4) `PresetParams.portrait.enabled`는 프리셋 속성이고, 화면의 **인물 모드 스위치**는 앱 상태다. 스위치가 꺼지면 `PipelineContext.portraitStage = nil`로 두는 방식으로 구현해 프리셋 값과 무관하게 동작하도록 한다.
- (R1-S3) `applyAuto`는 이미지 내용을 분석하므로 프리뷰(다운샘플)와 풀해상도 결과가 미세하게 다를 수 있음. 프리뷰에서 얻은 필터 값을 저장 시 재사용할지 실기기에서 판단.
- (R1-S2) 10비트 HEIF 원본은 `renderFullResolution`의 `.RGBA8`에서 계조가 줄어듦. 인코더와 함께 `.RGBA16` 옵션 검토.
- (B1 실기기) `applyTemperature`의 +값이 따뜻해지는 방향인지 확인. 반대면 neutral/targetNeutral 교체.
- (B1 실기기) `LUT.supportedSizes` 상한 128이 CIColorCube 최대 크기와 맞는지 확인(65 크기 .cube 파일 로드 테스트).
- (R1-S5) 선명도를 피부 마스크 바깥에만 적용하는 블렌드는 아직 없음(주석에 TODO 표시됨).
- 하이라이트 +값(밝히기)은 `CIHighlightShadowAdjust`로 불가해 현재 무효과. 필요 시 톤 커브로 별도 구현.

### 컴파일 확신이 낮은 지점 (Mac 빌드 시 우선 확인)
- `LUT.ciFilter`: `CIFilter.colorCubeWithColorSpace().colorSpace` 프로퍼티 타입.
- `EnhanceTests.testRendererColorSpaceOfKeepsRGB`: `CGColorSpace.name as String?` 캐스트.
- `LUT.parse`: `split(omittingEmptySubsequences:whereSeparator:)`에서 `"\r\n"` Character 비교.
- `.cube` 파일이 XcodeGen 폴더 소스에서 리소스로 번들에 포함되는지(`testBundledMonoLUTLoads`가 실패하면 이것부터).

