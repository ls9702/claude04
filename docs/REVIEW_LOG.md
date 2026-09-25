# 코드 리뷰 로그 (리뷰 세션이 기록, 최신이 위)

형식은 `docs/REVIEW_CHECKLIST.md` 하단 참조.

---

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

