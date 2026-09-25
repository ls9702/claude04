# 코드 리뷰 로그 (리뷰 세션이 기록, 최신이 위)

형식은 `docs/REVIEW_CHECKLIST.md` 하단 참조.

---

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

