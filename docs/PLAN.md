# TripShot — 여행 사진·쇼츠 iPhone 앱 개발 계획서

작성일: 2026-09-25 · 상태: **v0.5 (사진 중심 재구성, Mac 빌드 전·후 단계 분리)** · 결정 이력은 §10

---

## 1. 목표

**나 혼자 쓰는 iPhone 앱 하나로** 다음 두 가지를 끝낸다. 외부 앱(편집 앱, Mac 스크립트, 서드파티 스토어)에 기대지 않는다.

1. **사진 보정 (주 기능)** — 카메라 라이브 화면과 앨범 사진 모두. 자동 보정 + 여행용 프리셋 + 인물 보정(피부·얼굴 윤곽). **결과는 항상 내 사진 보관함에 저장되고, 촬영 위치·날짜·카메라 정보(EXIF/GPS)는 그대로 유지**된다.
2. **여행 쇼츠 (보조 기능)** — 영상 규격(9:16 등)을 고르면 그에 맞춰 촬영을 돕고, 찍은 클립을 음악과 함께 붙여 내보낸다. 음악은 YouTube 링크에서 앱이 직접 가져온다.

복잡한 기능은 넣지 않는다. 화면은 4개, 설정은 한 페이지.

### 전제
| 항목 | 내용 |
|---|---|
| 사용자 | 본인 1명. 로그인·서버 없음. 모든 처리는 기기 안 |
| 기기 | iPhone 12 Pro (A14, 광각·초광각·망원 2×, ProRAW 가능, ProRes 불가), iOS 27 → 최소 배포 iOS 26 |
| 개발 환경 | MacBook Air M2 + 최신 Xcode. 이 저장소에서 Swift 코드 작성 → Mac에서 pull·빌드·설치 |
| 서명 | 무료 Apple ID. **7일마다 Mac에서 재설치**(케이블 연결 후 Xcode Run 1회, 앱 데이터 유지됨). 유료는 연 129,000원이며 필요해지면 그때 전환 |
| 저장 | 사진·영상은 시스템 사진 앱에. 앱 DB(SwiftData)는 프리셋·프로젝트·음원 메타만 |

---

## 2. 기술 스택

| 계층 | 선택 |
|---|---|
| UI | Swift 6 / SwiftUI, 시스템 기본 컴포넌트 |
| 카메라 | AVFoundation (`AVCaptureSession`, `AVCapturePhotoOutput`, `AVCaptureMovieFileOutput`) |
| 사진 앱 | PhotoKit (`PHPickerViewController`, 비파괴 편집 `PHAdjustmentData`) |
| 이미지 처리 | Core Image + 커스텀 Metal 커널 (프리뷰는 `MTKView`) |
| 얼굴 | Vision (`VNDetectFaceLandmarksRequest`) |
| 위치 | Core Location (촬영 시 GPS를 사진 메타데이터에 기록) |
| 메타데이터 | ImageI/O (`CGImageSource`/`CGImageDestination`로 EXIF·GPS·TIFF 딕셔너리 보존) |
| 저조도 | Core ML (Zero-DCE++ 변환 모델) |
| 영상 조립 | AVFoundation Composition (`AVMutableComposition`, `AVVideoComposition`, `AVAssetExportSession`) |
| YouTube 음원 | **YouTubeKit** (Swift 패키지, MIT) — 앱 안에서 링크 → 오디오 스트림 URL 추출 → 다운로드 |
| 데이터 | SwiftData |
| 의존성 | Swift Package Manager. 외부 패키지는 YouTubeKit 하나만. 나머지는 Apple 프레임워크 |

---

## 3. 기능 ① 사진 보정

### 3.1 진입점
- **라이브**: 프리뷰에 선택한 프리셋을 실시간 적용(저해상도, Metal). 셔터를 누르면 Apple ISP 처리 원본을 받아 풀해상도에 같은 프리셋을 후처리 → 원본과 함께 사진 앱에 저장(비파괴).
- **앨범**: 사진 선택(여러 장 가능) → 자동 보정 또는 프리셋 → 전/후 비교 → 저장. 일괄 처리.

### 3.2 보정 파이프라인 (순서 고정, 각 단계 강도 0~100)
| 단계 | 내용 | 구현 |
|---|---|---|
| 1 자동 | Apple 자동 개선(적목·얼굴 밸런스·색·톤) | `CIImage.autoAdjustmentFilters()` |
| 2 톤·색 | 노출, 대비, 하이라이트/섀도우, 화이트밸런스, 생동감 | Core Image 내장 필터 |
| 3 인물 | §3.3 | Vision + Metal |
| 4 선명도 | 언샤프 마스크 + 로컬 대비. 피부 마스크 바깥에만 | `CIUnsharpMask` + Metal 커널 |
| 5 저조도 | Zero-DCE++ (야경 프리셋에서만 켜짐) | Core ML |
| 6 색감 룩 | 3D LUT (.cube) | `CIColorCubeWithColorSpace` |
| 7 마무리 | 수평 자동 보정, 비네팅 | Vision 수평선 검출, `CIVignetteEffect` |

**프리셋**: 위 파라미터 묶음. 기본 6종(맑은 하늘, 골든아워, 야경, 음식, 실내, 흑백) + 직접 저장. 프리셋 하나가 라이브·앨범·영상에 동일하게 적용된다.

### 3.3 인물 보정
얼굴이 검출되면 켜지는 레이어. 기본값은 낮게(피부 30, 윤곽 20).

| 기능 | 방법 |
|---|---|
| 피부 부드럽게 | 얼굴 랜드마크 + 피부색 범위로 피부 마스크 → 마스크 안에만 하이패스 주파수 분리(질감 유지, 잡티·요철만 완화). 라이브에서는 양방향 필터로 가볍게 |
| 얼굴 날렵하게 | 턱선·광대 랜드마크 기준 메시 워프(Metal). 좌우 대칭, 배경 왜곡 감쇠 |
| 눈 키우기, 치아 미백 | 같은 워프·마스크 방식. 옵션 |
| 여러 명 | 얼굴별 독립 처리, 최대 5명. 모두 같은 강도 |

참조: YUCIHighPassSkinSmoothing(MIT, Core Image 구현), GPUPixel(얼굴 축소 셰이더 알고리즘만 참조해 Metal로 재작성).

### 3.4 저장 방식과 메타데이터 보존 (핵심 요구)
모든 결과는 **시스템 사진 보관함**으로 간다. 앱 안에 사진을 쌓지 않는다. 위치·날짜·카메라 정보는 아래 방식으로 유지한다.

| 경로 | 저장 방법 | 메타데이터 |
|---|---|---|
| **앨범 사진 보정** | PhotoKit **비파괴 편집**(`PHContentEditingInput/Output` + `PHAdjustmentData`). 같은 에셋에 보정본이 렌더링되고 원본은 사진 앱의 "되돌리기"로 복원 | 에셋이 그대로이므로 **촬영일·위치·EXIF 전부 자동 유지**. 앱은 렌더 출력 JPEG/HEIF에도 원본 `CGImageSource` 속성(EXIF·GPS·TIFF)을 `CGImageDestination`으로 복사해 넣는다 |
| **앨범 사진 보정 — 사본으로 저장(옵션)** | 새 에셋 생성(`PHAssetCreationRequest`) | 원본의 EXIF·GPS·TIFF 딕셔너리를 복사하고, `creationDate`·`location`을 원본 에셋 값으로 명시 설정 |
| **라이브 촬영** | `AVCapturePhoto.fileDataRepresentation()`에 담긴 카메라 메타데이터(EXIF, 렌즈, 노출) + 촬영 시각 그대로 저장. GPS는 Core Location으로 받아 `AVCapturePhotoSettings.metadata`의 `kCGImagePropertyGPSDictionary`에 넣어 촬영 시점에 기록 | 원본 에셋에 모두 포함. 보정본은 같은 에셋의 비파괴 편집으로 얹음 → 사진 앱에서 원본/보정본 전환 가능 |
| **쇼츠 내보내기** | `AVAssetExportSession` 출력에 `AVMetadataItem`(creationDate, location)을 첫 클립 값으로 기록 후 사진 앱 저장 | 영상도 촬영일·위치 표시됨 |

- 저장 포맷: 촬영은 HEIF(기본, 용량 절반) 또는 JPEG 선택. 보정 렌더 출력은 원본과 같은 포맷.
- ProRAW로 촬영한 경우 원본 DNG 유지, 보정본은 HEIF로 같은 에셋에 얹음.
- 사진 앱의 "편집됨" 표시가 뜨며, 다른 앱(Lightroom 등)에서 열어도 메타데이터가 보인다.
- 위치 권한은 "앱 사용 중"만 요청. 거부해도 나머지 기능은 동작(위치만 비어 있음).

---

## 4. 기능 ② 여행 쇼츠

### 4.1 흐름
```
규격 선택 → (템플릿 선택) → 촬영 보조 → 클립 목록 → 음악 붙여 조립 → 사진 앱에 저장
```

### 4.2 규격 (앱 내 테이블, 수정 가능)
| 규격 | 해상도 | 세이프존 |
|---|---|---|
| **세로 9:16 (기본)** | 1080×1920 | 상단 15%, 하단 20%, 우측 15% (Reels·Shorts·TikTok 공통 회피 영역) |
| 세로 4:5 | 1080×1350 | 없음 |
| 정사각 1:1 | 1080×1080 | 없음 |
| 가로 16:9 | 1920×1080 | 없음 |

촬영은 항상 **세로 4K 30fps SDR HEVC**로 저장하고 내보낼 때 규격에 맞춰 크롭. 한 번 찍은 것으로 어떤 규격이든 출력.

### 4.3 템플릿 (기본 3개 + 직접 편집)
| 이름 | 길이 | 샷 구성 |
|---|---|---|
| 짧게 | 15s | 오프닝 3s → 장면 4s × 2 → 엔딩 4s |
| 기본 | 30s | 오프닝 3s → 장면 4s × 5 → 음식/디테일 4s → 엔딩 3s |
| 자유 | – | 규격만 정하고 샷 제한 없음 |

샷마다 이름·목표 길이만 있다. 템플릿 편집은 샷 추가/삭제/길이 조정뿐.

### 4.4 촬영 보조 화면
- 선택 규격의 프레임만 밝게, 바깥은 어둡게. 세이프존은 반투명 표시.
- 현재 샷 이름 + 목표 길이 카운트다운. 초과하면 진동.
- 3분할 그리드, 수평계(기울면 빨강), 탭 포커스, 노출 슬라이더.
- 안정화 `.cinematicExtended`(미지원 시 `.cinematic`).
- 선택한 사진 프리셋을 프리뷰에 적용(저장은 원본, 조립 때 적용).
- 샷 촬영 완료 체크, 재촬영, 앨범 클립으로 대체.
- 배터리·저장공간·열 상태 경고.

### 4.5 조립 (최소 편집)
- 클립: 템플릿 길이대로 자동 트림(앞뒤 수동 조정), 순서 바꾸기, 무음.
- 전환: 컷 / 디졸브 0.3s 중 택일.
- 텍스트: 오프닝 제목 1개 (여행명·날짜 자동 채움).
- 음악: 음원 라이브러리에서 선택, 시작 지점 조정, 끝 페이드아웃.
- 내보내기: 선택 규격으로 HEVC 렌더 → 사진 앱 저장.

### 4.6 음원 라이브러리 (YouTube 링크에서 앱이 직접 가져오기)
| 항목 | 내용 |
|---|---|
| 방법 | 앱에 YouTube 링크 붙여넣기(또는 YouTube 앱 공유 시트 → TripShot) → **YouTubeKit**이 오디오 스트림 URL 추출 → m4a 다운로드 → 앱 내 저장 → 제목·길이 표시 |
| 위험 | YouTube가 내부 구조를 바꾸면 추출이 깨질 수 있음. YouTubeKit 업데이트 후 재빌드로 해결(과거 이력상 수 주 내 패치됨). 그동안은 파일 앱에서 음원 가져오기가 대체 경로 |
| 하지 않는 것 | 앱 안 YouTube 검색·재생, 업로드. 결과물은 어디에도 올리지 않는 개인용이므로 저작권 이슈 없음 |
| 파일 | 앱 내부 `Music/` 폴더. 삭제·이름 변경 가능 |

---

## 5. 화면 (하단 탭 4개)

| 탭 | 내용 |
|---|---|
| **촬영** | 사진/쇼츠 모드 토글. 사진 모드: 프리셋 선택·셔터. 쇼츠 모드: 규격·템플릿·샷 카드·세이프존 |
| **보정** | 앨범 선택 → 프리셋/자동/슬라이더 → 전/후 → 저장(단일·일괄) |
| **쇼츠** | 프로젝트 목록 → 클립 목록 → 조립 → 내보내기 |
| **설정** | 프리셋 관리, 템플릿 관리, 음원 라이브러리, 촬영 옵션(해상도·포맷), 백업(프리셋·템플릿 JSON 내보내기/가져오기) |

디자인: SwiftUI 기본 컴포넌트, 촬영 화면은 검정 배경·최소 UI. 시스템 카메라와 같은 제스처(탭 포커스, 핀치 줌).

---

## 6. 구조

```
TripShot/
├─ App/          탭, 설정
├─ Capture/      AVCaptureSession, Metal 프리뷰, 사진·영상 저장
├─ Enhance/      프리셋 모델, Core Image/Metal 파이프라인, LUT, Core ML
├─ Portrait/     얼굴 랜드마크, 피부 마스크, 메시 워프
├─ Shorts/       규격·템플릿, 촬영 보조 오버레이, 프로젝트·클립
├─ Compose/      AVComposition 빌더, 내보내기
├─ Music/        YouTubeKit 다운로드, 음원 목록
├─ Library/      PhotoKit, SwiftData
└─ Resources/    LUT(.cube), Core ML 모델, 기본 템플릿 JSON
```

데이터(SwiftData): `Preset`, `FormatPreset`, `Template(shots)`, `ShortsProject`, `Clip`, `MusicTrack`.

---

## 7. 참고 오픈소스

| 이름 | 용도 | 라이선스 |
|---|---|---|
| YouTubeKit — https://github.com/alexeichhorn/YouTubeKit | YouTube 오디오 추출 | MIT |
| YUCIHighPassSkinSmoothing — https://github.com/YuAo/YUCIHighPassSkinSmoothing | 피부 보정 구현 참조 | MIT |
| GPUPixel — https://github.com/pixpark/gpupixel | 얼굴 축소·눈 확대 알고리즘 참조(자체 Metal 구현) | 저장소 확인 |
| GPUImage3 — https://github.com/BradLarson/GPUImage3 | 선명도·로컬 대비 셰이더 참조 | BSD-3 |
| Zero-DCE++ — https://github.com/Li-Chongyi/Zero-DCE | 저조도 모델(Core ML 변환) | 연구용, 개인 사용 |
| MetalPetal — https://github.com/MetalPetal/MetalPetal | Core Image로 부족할 때 대안 | MIT |

원칙: Apple 프레임워크 우선. 오픈소스는 알고리즘 참조 후 자체 코드로 유지(의존 패키지는 YouTubeKit 하나).

---

## 8. 실행 계획 — Mac 빌드 전 / 후

이 환경(Linux)에서는 컴파일이 불가하므로, **Mac 빌드 없이 작성할 수 있는 것**과 **실기기에서 돌려 봐야 하는 것**을 나눈다. A 단계는 지금 바로 진행하고, 첫 빌드 결과가 오면 B 단계로 넘어간다. 사진 기능이 주 기능이므로 A·B 모두 사진을 먼저 한다.

### A. Mac 빌드 전 (코드·문서 작성, 컴파일 검증 없음)
| 단계 | 내용 | 산출물 |
|---|---|---|
| **A0 골격** ✅ | XcodeGen 정의, 탭 4개, SwiftData 모델·시드, 카메라 프리뷰·촬영, Mac 가이드 | 완료 (커밋 8318c82) |
| **A1 사진 보정 파이프라인** | `PresetParams → CIImage` 변환 엔진(§3.2 1·2·4·6·7단계), LUT(.cube) 파서, 기본 프리셋 6종 값, 렌더러(프리뷰용 저해상도 / 저장용 풀해상도) | `Enhance/` 소스, 단위 테스트(파서·파라미터 직렬화) |
| **A2 메타데이터 보존·저장** | §3.4 구현: `CGImageSource` 속성 복사, PhotoKit 비파괴 편집 출력, 사본 저장 옵션, Core Location → GPS 딕셔너리 | `Library/PhotoSaver.swift`, `Library/MetadataCopier.swift`, 테스트(딕셔너리 복사) |
| **A3 보정 화면** | 앨범 선택 → 프리셋 스트립 → 슬라이더(노출·대비·하이라이트·섀도우·WB·생동감·선명도) → 전/후 비교(길게 누르기) → 저장(비파괴/사본) → 일괄 처리 진행 표시 | `Enhance/EnhanceView.swift` 등 |
| **A4 라이브 보정 골격** | `AVCaptureVideoDataOutput` → `CIImage` → `MTKView` 렌더 루프, 프리셋 실시간 적용, 촬영 후 풀해상도 후처리 → A2 경로로 저장 | `Capture/MetalPreviewView.swift`, `Capture/LivePipeline.swift` |
| **A5 인물 보정 골격** | Vision 랜드마크 → 피부 마스크 생성, 하이패스 피부 보정 필터, 메시 워프 Metal 셰이더(턱선·광대·눈), 파이프라인 3단계에 연결 | `Portrait/` 소스, Metal 셰이더 |
| **A6 쇼츠 촬영 보조** | 규격 프레임·세이프존 오버레이, 샷 카드·카운트다운, 수평계, 영상 녹화(`AVCaptureMovieFileOutput`, 4K30 HEVC), 클립 저장·목록 | `Shorts/`, `Capture/VideoRecorder.swift` |
| **A7 조립·내보내기** | `AVMutableComposition` 빌더, 자동 트림·순서·전환·제목, 규격별 렌더, 메타데이터 기록, 사진 앱 저장 | `Compose/` 소스, 빌더 단위 테스트 |
| **A8 음원** | YouTubeKit 연동(링크 붙여넣기·공유 시트), 다운로드, 음원 목록, 조립에 합성 | `Music/` 소스 |

A 단계는 순서대로 커밋한다. 각 단계는 컴파일 오류 가능성이 있으므로 **A1~A3까지 작성한 시점에 첫 Mac 빌드를 권장**한다(사진 기능만으로 앱이 쓸모 있어지는 지점).

### B. Mac 빌드 후 (실기기 검증·튜닝, 빌드 로그 왕복)
| 단계 | 내용 | 완료 기준 |
|---|---|---|
| **B0 첫 빌드 통과** | 컴파일 오류·서명·권한 문구 수정 | iPhone에 설치되고 4개 탭이 뜸 |
| **B1 사진 보정 검증** | 실제 여행 사진으로 프리셋 6종 값 조정, 전/후 자연스러움, 일괄 100장 속도 | 저장 후 사진 앱에서 위치·날짜·"편집됨" 확인, 되돌리기 동작 |
| **B2 메타데이터 검증** | 라이브 촬영본에 GPS·EXIF 기록 확인, 비파괴 편집 후 메타 유지 확인, HEIF/JPEG/ProRAW 각각 | 사진 앱 정보 패널과 Mac 미리보기 앱에서 동일하게 보임 |
| **B3 라이브 보정 성능** | 프리뷰 30fps 유지, 발열 시 해상도 자동 하향, 촬영 지연 측정 | 5분 연속 프리뷰에 프레임 드롭 없음 |
| **B4 인물 보정 튜닝** | 피부 마스크 경계, 워프 강도·자연스러움, 다인·측면 얼굴, 라이브 경량 모드 | 셀피·단체 사진에서 과보정 없이 동작 |
| **B5 저조도 모델** | Mac에서 Zero-DCE++ → Core ML 변환(coremltools), 통합, 야경 프리셋 연결 | 야경 사진 개선, 풀해상도 3초 이내 |
| **B6 쇼츠 검증** | 촬영 보조 UX, 4K 녹화 안정성, 조립 렌더 시간, 음원 다운로드 | 30초 9:16 쇼츠가 음악과 함께 저장됨 |
| **B7 마무리** | 열·배터리 경고, 백업(프리셋·템플릿 JSON), 오류 처리, 20분 연속 사용 | 여행에서 바로 쓸 수 있는 상태 |

### 예상 기간
A 단계 약 12일(작성), B 단계 약 10일(왕복 포함). B1·B2가 끝나면 사진 기능은 실사용 가능하다.

## 9. 나중으로 미룬 것 (v1에 넣지 않음)
비트 싱크 자동 컷, 레퍼런스 쇼츠 분석, Live Photo 변환, 사진 슬라이드 쇼츠, 촬영 품질 판정, 얼굴별 보정 프로필, 타임랩스, 다중 규격 자동 크롭, HDR 유지, 자동 자막, Watch 리모컨, 단축어 연동.

---

## 10. 결정 이력

| 날짜 | 결정 |
|---|---|
| 09-25 | Mac(M2 Air) 보유, 무료 Apple ID, iPhone 12 Pro/iOS 27, 9:16 기본, 4K30 SDR, 저조도 딥러닝 포함, 자동 자막 제외, 인물 보정 추가 |
| 09-25 | YouTube는 **음원만** 가져오기(업로드 없음). **외부 앱·Mac 스크립트 없이 앱 안에서** 처리 → YouTubeKit 채택 |
| 09-25 | 쇼츠 레퍼런스 분석(따라 찍기) 폐기. 복잡한 부가 기능 모두 §9로 이동. 템플릿은 3개로 축소 |
| 09-25 | **v0.4 확정.** 라이브 보정은 필수. 무료 Apple ID 7일 갱신 방식 적용 |
| 09-25 | **v0.5.** 사진 보정이 주 기능, 쇼츠는 보조. 결과는 사진 보관함에 저장하고 EXIF·GPS·날짜 보존(§3.4). 실행 계획을 Mac 빌드 전(A)·후(B)로 분리, 사진 먼저 |

## 11. 두 세션 협업 방식 (클라우드 ↔ Mac)

Mac에서 별도의 Claude Code 세션을 열어 같은 저장소로 작업한다. 연결 고리는 **git 브랜치 하나 + 문서 두 개**다.

```
클라우드 세션 (Linux)                        Mac 세션 (MacBook Air M2)
  코드 작성 (A 단계) ─── push ──▶ 공유 브랜치 ◀── pull ─── scripts/build.sh 빌드·테스트
  BUILD_LOG 읽고 수정 ◀── pull ── 공유 브랜치 ◀── push ─── 컴파일 오류 최소 수정, BUILD_LOG 기록
                                                      scripts/install-device.sh → iPhone 설치
                                                      실기기 관찰·튜닝 (B 단계)
```

| 파일 | 역할 |
|---|---|
| `CLAUDE.md` | 두 세션 공통 규약: 역할, 브랜치·커밋 규칙, 핸드오프 절차, 코드 원칙. Claude Code가 세션 시작 시 자동으로 읽는다 |
| `docs/HANDOFF.md` | 현재 누가 무엇을 하는지, 단계별 상태, 논의 필요 항목. 작업 전 읽고 후 갱신 |
| `docs/BUILD_LOG.md` | Mac 세션이 빌드·테스트·설치 결과를 기록. 클라우드 세션이 읽고 고침 |
| `scripts/build.sh` `test.sh` `install-device.sh` `sync.sh` | Mac 세션이 명령 한 줄로 빌드·테스트·설치·동기화. Xcode GUI 없이도 동작 |
| `.claude/settings.json` | Mac 세션이 위 스크립트와 xcodebuild·git을 확인 없이 실행하도록 허용 |

규칙 요약: 작업 전 `pull --rebase`, 작업 후 즉시 push. Mac 세션은 컴파일 오류를 최소 수정으로 고치고 설계 변경은 HANDOFF "논의 필요"에 적는다. 클라우드 세션은 턴 시작마다 BUILD_LOG를 읽고 실패부터 고친다.

## 12. 다음 행동
1. **Mac 세션 시작**: `docs/MAC_SETUP.md` §1 준비 → 저장소 clone → Claude Code 실행 → "HANDOFF.md의 'Mac 세션이 처음 할 일'을 진행해" 지시. A0 골격 첫 빌드·설치 → BUILD_LOG 기록.
2. **클라우드 세션**: 동시에 A1 사진 보정 파이프라인 → A2 메타데이터 → A3 보정 화면 작성. BUILD_LOG에 실패가 오면 그것부터 수정.
3. A3까지 빌드 통과하면 B1·B2로 사진 기능을 실기기에서 확정.
