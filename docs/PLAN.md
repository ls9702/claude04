# 여행 사진·쇼츠 iPhone 앱 개발 계획서

작성일: 2026-09-25 · 상태: **논의용 초안 (v0.1)** · 결정 필요 항목은 §11 참조

---

## 1. 목표와 범위

### 1.1 한 줄 요약
**나 혼자 쓰는 iPhone 네이티브 앱.** ① 카메라 라이브 화면과 앨범 사진에 적용되는 **사진 보정** ② 쇼츠 플랫폼 규격(Reels/Shorts/TikTok 등)을 먼저 고른 뒤 그 규격에 맞게 **촬영을 보조**하고 클립을 조립해 내보내는 **여행 쇼츠 제작** 기능을 제공한다.

### 1.2 전제 (개인용이라 단순해지는 것)
| 항목 | 결정 |
|---|---|
| 사용자 | 본인 1명. 로그인·서버·동기화 없음. **모든 처리는 기기 내(on-device)** |
| 배포 | App Store 미배포. Xcode로 내 iPhone에 직접 설치 |
| 데이터 | 사진·영상은 시스템 사진 앱(PhotoKit)에 그대로 저장. 앱 자체 DB는 프로젝트/프리셋 메타데이터만 |
| 개인정보/과금 | 외부 서버 전송 없음 → 개인정보 이슈 없음, 운영 비용 0 |

### 1.3 범위 밖
- Android, 웹 버전
- 다중 사용자, 클라우드 동기화, 소셜 업로드 자동화(각 플랫폼 앱의 공유 시트로 넘기는 것까지만)
- 음악 저작권 처리(본인 보유 음원·무료 음원 파일을 직접 넣는 방식)

---

## 2. 반드시 먼저 확인할 제약

| 제약 | 내용 | 대응 |
|---|---|---|
| **Mac + Xcode 필수** | iOS 앱은 macOS의 Xcode에서만 빌드·설치 가능. 이 개발 환경(Linux)에서는 Swift 코드 작성·구조 검토는 가능하지만 **빌드·시뮬레이터·실기기 테스트는 불가**. | 코드는 이 저장소에서 작성 → 사용자 Mac에서 `git pull` 후 Xcode로 빌드·설치. 빌드 오류 로그를 붙여 주시면 수정하는 순환 방식. |
| **서명 방식** | 무료 Apple ID: 설치 후 **7일마다 재설치** 필요, 앱 3개 제한. 유료 Apple Developer Program($99/년): **1년 유효**, TestFlight 사용 가능. | 개인용 장기 사용이면 **유료 계정 권장**. 초기 개발은 무료로 시작 가능. |
| **최소 iOS 버전** | iOS 17 이상이면 SwiftUI·SwiftData·최신 AVFoundation API 사용 가능. iOS 18이면 더 단순. | **iOS 17.0** 최소, 사용 기기 버전에 맞춤(§11 Q3). |
| **실시간 처리 성능** | 라이브 보정은 30fps 이상 유지해야 함. 딥러닝 보정(Zero-DCE 등)은 프리뷰 해상도에서만 실시간. | 프리뷰: 저해상도 + 가벼운 필터. 촬영 결과: 풀해상도에 무거운 필터 적용(수 초 허용). |
| **발열·배터리** | 4K 촬영 + 실시간 필터 + 안정화는 발열이 큼. | 프리뷰 필터는 Metal로, 촬영 시 필터는 후처리로 분리. 열 상태(`ProcessInfo.thermalState`) 감시해 품질 자동 하향. |
| **오픈소스 라이선스** | 참조 코드 라이선스 확인 필요(§9). 개인용이라 배포 의무는 사실상 없지만 기록은 남김. | BSD/MIT/Apache 위주 사용. GPL은 참고만. |

---

## 3. 기술 스택

| 계층 | 선택 | 이유 |
|---|---|---|
| 언어/UI | **Swift 5.10+ / SwiftUI** (iOS 17+) | 네이티브 성능, 카메라·사진 프레임워크 직접 접근 |
| 카메라 | **AVFoundation** (`AVCaptureSession`, `AVCapturePhotoOutput`, `AVCaptureMovieFileOutput`/`AVAssetWriter`) | 라이브 프리뷰 프레임 접근, 4K/60fps, 안정화, HDR, ProRes(Pro 모델) |
| 사진 접근 | **PhotoKit** (`PHPickerViewController`, `PHAssetChangeRequest`, `PHAdjustmentData`) | 앨범 읽기·쓰기, **비파괴 편집**(사진 앱에서 원본 복원 가능) |
| 이미지 처리 | **Core Image + Metal** (기본), 필요 시 **MetalPetal** 추가 | Core Image 내장 필터 200+개, 커스텀 Metal 커널 작성 가능. MetalPetal은 실시간 파이프라인이 더 쉬움 |
| 딥러닝 보정 | **Core ML** (Zero-DCE++ 등 변환 모델) | 저조도 개선을 기기 내에서 수행 |
| 분석 | **Vision** (얼굴·수평선·현저성 saliency), **Core Motion** (수평계) | 자동 크롭·구도 가이드·수평 보정 |
| 영상 조립 | **AVFoundation Composition** (`AVMutableComposition`, `AVMutableVideoComposition`, `AVAssetExportSession`) + Core Image 비디오 필터 | 클립 트림·순서·전환·텍스트 오버레이·음악 합성·규격별 내보내기 |
| 자막 | **Speech** 프레임워크(기기 내 음성 인식) | 한국어 자동 자막 초안 |
| 로컬 데이터 | **SwiftData** | 프로젝트(여행)·템플릿·프리셋·클립 메타 |
| 패키지 관리 | Swift Package Manager | Xcode 기본 |
| 테스트 | XCTest(필터 파이프라인 단위 테스트, 스냅샷 비교) | Mac에서 실행 |

---

## 4. 기능 ① 사진 보정

### 4.1 두 가지 진입점
| 모드 | 흐름 |
|---|---|
| **라이브(카메라)** | 프리뷰 프레임(`AVCaptureVideoDataOutput`) → 선택한 보정 레시피를 Metal로 실시간 적용 → 화면 표시. 셔터를 누르면 `AVCapturePhotoOutput`으로 **Apple ISP 처리(Smart HDR/Deep Fusion)를 거친 원본**을 받고, 같은 레시피를 풀해상도에 후처리 적용 → 원본 + 보정본을 사진 앱에 저장(원본은 `PHAdjustmentData`로 연결해 비파괴). |
| **앨범(기존 사진)** | `PHPickerViewController`로 1장 또는 여러 장 선택 → 자동 보정 또는 프리셋 적용 → 전/후 비교 → 저장(비파괴 편집 또는 사본). **일괄 처리** 지원. |

### 4.2 보정 레이어 (아래 순서로 파이프라인 구성)
| 단계 | 기법 | 구현 | 참조 |
|---|---|---|---|
| 1. 자동 기본 보정 | Apple 자동 개선 (적목·얼굴 밸런스·색감·톤 곡선) | `CIImage.autoAdjustmentFilters()` — 사진 앱 "자동" 버튼과 동일 계열 | Apple Core Image |
| 2. 노출/톤 | 노출, 대비, 하이라이트/섀도우, 화이트밸런스, 채도/생동감 | `CIExposureAdjust`, `CIHighlightShadowAdjust`, `CITemperatureAndTint`, `CIVibrance`, `CIToneCurve` | Apple |
| 3. 선명도 | 언샤프 마스크, 로컬 대비(Clarity) | `CIUnsharpMask` + 커스텀 Metal 커널(가우시안 차이 기반 로컬 대비) | GPUImage3의 UnsharpMask 참조 |
| 4. 저조도 개선 | **Zero-DCE++** (10K 파라미터, 경량 곡선 추정) | PyTorch → Core ML 변환(coremltools). 프리뷰는 512px, 저장은 풀해상도 | Li-Chongyi/Zero-DCE, john-rocky/CoreML-Models |
| 5. 안개 제거(Dehaze) | Dark Channel Prior | 커스텀 Metal 커널(공개 알고리즘, 구현 단순) | He et al. 2009 |
| 6. 룩(색감 프리셋) | **3D LUT (.cube)** | `CIColorCubeWithColorSpace`. 무료 LUT 파일 가져오기·직접 저장 | 표준 포맷, 무료 LUT 다수 |
| 7. 기하 | 수평 보정, 자동 크롭, 원근 보정 | Vision `VNDetectHorizonRequest`, `CIPerspectiveCorrection` | Apple |
| 8. 마무리 | 비네팅, 필름 그레인 | `CIVignetteEffect`, 노이즈 합성 커널 | Apple |

- **레시피(Recipe)**: 위 단계의 파라미터 묶음. JSON으로 저장·복제·이름 붙이기 가능. 라이브·앨범 모두 같은 레시피를 사용.
- **여행용 기본 프리셋 6종** 제공 예정: 맑은 하늘, 골든아워, 야경(저조도 강화), 음식, 실내, 흑백.
- **전/후 비교**: 드래그 슬라이더 + 길게 누르면 원본.

### 4.3 라이브 모드 촬영 옵션
- 후면 광각/초광각/망원 전환, 노출 고정(AE/AF lock), 그리드, 수평계, 셔터 후 즉시 보정본 미리보기.
- HEIF/JPEG 선택, Pro 모델이면 ProRAW 캡처 옵션(후처리 폭이 넓음).

---

## 5. 기능 ② 여행 쇼츠 제작

### 5.1 핵심 개념: **규격 → 템플릿 → 촬영 보조 → 조립 → 내보내기**
```
[규격 선택] Reels 9:16 · Shorts 9:16 · TikTok 9:16 · Instagram 피드 4:5 · 정사각 1:1 · 가로 16:9
     ↓
[템플릿 선택] 예) "여행 브이로그 30초": 훅(0~3s) → 도착샷(3s) → 풍경 B-roll ×3(각 4s) → 음식(4s) → 엔딩(3s)
     ↓
[촬영 보조 화면] 규격 프레임 + 세이프존 오버레이 + 현재 샷 이름·목표 길이·카운트다운 + 구도 가이드
     ↓
[클립 체크리스트] 샷별 촬영 완료 표시, 재촬영, 앨범에서 가져오기
     ↓
[자동 조립] 템플릿 길이대로 트림 → 전환 → 자막·텍스트 → 음악 → 규격에 맞춰 렌더링
     ↓
[내보내기] 사진 앱 저장 + 공유 시트(Instagram/YouTube/TikTok 앱으로)
```

### 5.2 플랫폼 규격 프리셋 (2026년 기준, 앱 내 테이블로 관리·수정 가능)
| 플랫폼 | 비율 / 해상도 | 최대 길이 | 세이프존(오버레이 회피 영역) |
|---|---|---|---|
| Instagram Reels | 9:16 · 1080×1920 | 최대 20분(권장 15~90초) | 상단 14%, 하단 20% |
| YouTube Shorts | 9:16 · 1080×1920 | 최대 3분 | 상단 ~10%, 하단 ~20%, 우측 ~15% |
| TikTok | 9:16 · 1080×1920 | 앱 내 10분(권장 15~60초) | 상단 15%, 하단 20%, 우측 15% |
| Instagram 피드 | 4:5 · 1080×1350 | 60초 | 없음 |
| 정사각 | 1:1 · 1080×1080 | – | 없음 |
| 가로(YouTube 일반) | 16:9 · 1920×1080 / 3840×2160 | – | 없음 |

- **촬영은 항상 세로 4K(3840×2160 세로) 30fps**로 저장하고 내보낼 때 규격에 맞춰 크롭·스케일 → 하나의 소스로 여러 규격 출력 가능. 60fps는 옵션.
- 세이프존은 반투명 오버레이로 표시. 텍스트·인물 얼굴이 세이프존에 걸리면 경고(Vision 얼굴 검출).

### 5.3 촬영 보조 기능 상세
| 기능 | 설명 |
|---|---|
| 규격 프레임 | 선택 규격의 실제 프레임을 프리뷰에 마스킹. 크롭 바깥은 어둡게 |
| 샷 카드 | 현재 샷 이름·설명·목표 길이. 촬영 시작하면 목표 길이 카운트다운, 초과 시 진동 |
| 구도 가이드 | 3분할 그리드, 수평계(Core Motion, 기울면 빨간색), 중심 가이드 |
| 안정화 | `preferredVideoStabilizationMode = .cinematicExtended`(iOS 17+) 기본 |
| 노출/포커스 | 탭 포커스, 길게 눌러 잠금, 노출 보정 슬라이더 |
| 오디오 | 입력 레벨 미터, 외부 마이크 자동 인식 |
| 재촬영·건너뛰기 | 샷 단위 재촬영, 순서 바꾸기, 앨범 클립으로 대체 |
| 촬영 룩 | ①의 레시피를 영상에도 적용(프리뷰만, 저장은 원본 + 조립 시 적용) |

### 5.4 조립·편집 기능 (최소 편집기)
- 클립 트림(템플릿 길이 자동 + 수동 미세조정), 순서 변경, 속도(0.5×/2×), 무음 처리.
- 전환: 컷, 크로스 디졸브, 페이드. 전환 시간 0.3초 기본.
- 텍스트: 제목 카드, 위치·날짜 스탬프(사진 메타데이터의 GPS → 지명 역지오코딩), 자막.
- 자동 자막: Speech 프레임워크로 한국어 초안 생성 → 수정.
- 음악: 파일 앱/사진 앱에서 가져온 음원. BPM 감지(온셋 분석)로 컷 포인트 제안.
- 규격별 렌더 프리셋: H.264/HEVC, 비트레이트(1080p 12Mbps 기본), 색공간 SDR(HDR은 옵션).

### 5.5 템플릿 (기본 제공 + 직접 편집)
| 이름 | 길이 | 구성 |
|---|---|---|
| 도시 하루 | 30s | 훅 3s → 이동 3s → 랜드마크 4s → 골목 B-roll 4s×2 → 카페/음식 4s → 야경 4s → 엔딩 4s |
| 자연 풍경 | 20s | 훅 3s → 와이드 4s → 디테일 3s×3 → 인물 4s |
| 음식 투어 | 25s | 간판 2s → 메뉴 3s → 조리/서빙 5s → 클로즈업 4s×3 → 리액션 3s |
| 자유 | – | 규격만 정하고 샷 제한 없음 |

---

## 6. 추가 제안 기능 (논의 후 반영)

| # | 기능 | 필요한 이유 | 우선순위 제안 |
|---|---|---|---|
| A1 | **여행(프로젝트) 단위 정리** | 사진·클립·쇼츠 결과물을 여행별로 묶어 관리. 날짜·위치 기반 자동 그룹 | 높음 (기본 골격) |
| A2 | **프리셋·템플릿 가져오기/내보내기** | JSON 파일로 백업, 기기 교체 시 복원 | 높음 (작음) |
| A3 | **일괄 보정 + 일괄 저장** | 여행 후 수백 장을 한 번에 | 높음 |
| A4 | **자동 하이라이트 제안** | 여행 사진·클립에서 선명도·얼굴·현저성 점수로 "쓸만한 것" 자동 선별 | 중 |
| A5 | **위치·날짜 스탬프/지도 스티커** | 쇼츠 오프닝에 "Kyoto · 2026.10" 등 자동 삽입 | 중 |
| A6 | **촬영 리스트 미리 계획** | 출발 전 여행지별 샷 리스트 작성, 현장에서 체크 | 중 |
| A7 | **HDR 영상·Dolby Vision 유지** | iPhone 기본 HDR 촬영본을 톤매핑 없이 내보내기 | 낮음 (복잡) |
| A8 | **Apple Watch 리모컨** | 삼각대 촬영 시 시작/정지 | 낮음 |
| A9 | **단축어(Shortcuts) 연동** | "최근 여행 사진 자동 보정" 같은 자동화 | 낮음 |
| A10 | **저장공간 관리** | 4K 원본이 쌓이므로 조립 완료 클립 정리 제안 | 중 |

---

## 7. 아키텍처 및 모듈

```
TravelShorts.xcodeproj
├─ App/                    진입점, 탭 네비게이션, 설정
├─ Modules/
│  ├─ Capture/             AVCaptureSession 래퍼, 프리뷰(MTKView), 사진/영상 캡처
│  ├─ Enhance/             레시피 모델, Core Image/Metal 파이프라인, LUT, Core ML 래퍼
│  ├─ Shorts/              규격·템플릿 모델, 촬영 보조 오버레이, 클립 체크리스트
│  ├─ Compose/             AVComposition 빌더, 전환/텍스트/자막/음악, 내보내기
│  ├─ Library/             PhotoKit 접근, 프로젝트(여행) 관리, SwiftData
│  └─ Shared/              공통 UI, 유틸, 색공간 헬퍼
├─ Resources/              기본 LUT(.cube), Core ML 모델(.mlpackage), 템플릿 JSON
└─ Tests/                  파이프라인 단위 테스트, 렌더 스냅샷 테스트
```

- **Enhance 파이프라인**은 `CIImage → [Stage] → CIImage` 순수 함수 체인. 라이브/앨범/영상이 같은 코드를 사용.
- **Capture**는 프리뷰 프레임을 Enhance에 넘기고, 촬영 결과는 원본 그대로 저장한 뒤 별도 큐에서 후처리.
- **Compose**는 템플릿 + 클립 목록을 입력받아 `AVMutableComposition`을 생성하는 결정적 빌더. 테스트 가능.

### 7.1 데이터 모델 (SwiftData)
```
Trip            id, title, startDate, endDate, coverAssetId
Recipe          id, name, stagesJSON, createdAt, isBuiltIn
FormatPreset    id, platform, width, height, maxSeconds, safeTop, safeBottom, safeRight, isBuiltIn
Template        id, name, formatPresetId, shots: [ShotSpec(name, hint, targetSeconds, order)]
ShortsProject   id, tripId, templateId, formatPresetId, status, createdAt
Clip            id, projectId, shotIndex, assetLocalId, inSec, outSec, speed, muted
ExportRecord    id, projectId, assetLocalId, formatPresetId, exportedAt
```

---

## 8. 화면 구성 (하단 탭 4개)

```
[촬영]     라이브 카메라. 상단: 사진/쇼츠 모드 토글, 레시피 선택. 쇼츠 모드면 규격·샷 카드·세이프존 표시
[보정]     앨범에서 선택 → 자동/프리셋/수동 슬라이더 → 전/후 비교 → 저장(단일·일괄)
[쇼츠]     프로젝트 목록 → 템플릿·규격 선택 → 클립 체크리스트 → 조립 편집기 → 내보내기
[라이브러리] 여행별 결과물, 프리셋·템플릿 관리, 설정(화질·서명·저장 옵션)
```
디자인: iOS 표준 컴포넌트(SwiftUI 기본)를 그대로 사용해 시스템 카메라·사진 앱과 같은 조작감 유지. 촬영 화면은 검은 배경·최소 UI.

---

## 9. 참고 오픈소스·알고리즘 (라이선스 포함)

| 항목 | 용도 | 라이선스 | 링크 |
|---|---|---|---|
| Core Image / AVFoundation / Vision / Speech | 기본 파이프라인 전부 | Apple SDK | Apple Developer 문서 |
| **MetalPetal** | Metal 기반 실시간 이미지·비디오 필터 프레임워크. Core Image보다 커스텀 셰이더가 쉬움 | MIT | https://github.com/MetalPetal/MetalPetal |
| **GPUImage3** | Swift/Metal 필터 파이프라인. 개별 필터(Unsharp, Clarity 등) 셰이더 참고 | BSD-3 | https://github.com/BradLarson/GPUImage3 |
| **MetalCamera** | Swift/Metal 카메라 프레임 처리 예제 | MIT | https://github.com/jsharp83/metalcamera |
| **Zero-DCE / Zero-DCE++** | 저조도 개선 경량 모델(원 논문 CVPR 2020). Core ML 변환 대상 | 비상업 연구용 라이선스 → **개인 사용은 가능, 확인 필요** | https://github.com/Li-Chongyi/Zero-DCE |
| **CoreML-Models (john-rocky)** | PyTorch → Core ML 변환 스크립트·샘플 앱 모음(Zero-DCE 포함) | 저장소별 확인 | https://github.com/john-rocky/CoreML-Models |
| Dark Channel Prior (He et al.) | 안개 제거 알고리즘. Metal 커널 직접 구현 | 논문(구현은 자체) | 논문 검색 |
| 3D LUT `.cube` 포맷 | 색감 프리셋 표준 | 포맷 자체 무료 | Adobe 사양 |
| **PixelSDK** | 상용 사진·영상 편집 SDK. UI 흐름 참고만(비용 발생) | 상용 | https://github.com/GottaYotta/PixelSDK |
| **swift-simple-video-editor** | AVFoundation 트림·병합·텍스트 오버레이 예제 | 저장소 확인 | https://github.com/indrasat/swift-simple-video-editor |
| 플랫폼 규격 참고 | Reels/Shorts/TikTok 2026 규격·세이프존 | – | Kapwing, Sprout Social 가이드 (§5.2 근거) |

> 원칙: 프레임워크는 Apple 기본을 우선 쓰고, 오픈소스는 **셰이더·알고리즘 참조** 수준으로 가져와 자체 코드로 유지한다. 의존성이 적을수록 iOS 업데이트 때 깨지지 않는다.

---

## 10. 실행 단계 (마일스톤)

| 단계 | 산출물 | 완료 기준 | 예상 |
|---|---|---|---|
| **P0 프로젝트 골격** | Xcode 프로젝트, 탭 구조, SwiftData 모델, 권한 요청(카메라·마이크·사진), CI 없이 Mac 로컬 빌드 가이드 | 내 iPhone에 설치되고 빈 화면 4개가 뜸 | 1일 |
| **P1 카메라 + 라이브 보정** | Capture 모듈, Metal 프리뷰, 기본 레시피 3종 실시간 적용, 사진 촬영·저장(비파괴) | 라이브 프리뷰에 필터가 30fps로 보이고 촬영본이 사진 앱에 저장 | 3일 |
| **P2 앨범 보정** | PHPicker, 자동 보정, 수동 슬라이더, LUT, 전/후 비교, 일괄 처리 | 100장 일괄 보정 후 저장 | 3일 |
| **P3 저조도·고급 보정** | Zero-DCE++ Core ML 변환·통합, Dehaze, Clarity 커널, 수평 자동 보정 | 야경 사진이 눈에 띄게 개선, 풀해상도 3초 이내 | 3일 |
| **P4 쇼츠 촬영 보조** | 규격 프리셋, 템플릿, 세이프존 오버레이, 샷 카드·카운트다운, 수평계, 클립 체크리스트 | 템플릿대로 7개 클립 촬영 완료 | 3일 |
| **P5 조립·내보내기** | Compose 빌더, 트림·전환·텍스트·음악, 규격별 렌더, 공유 시트 | 30초 Reels가 1080×1920으로 내보내지고 Instagram 앱에서 열림 | 4일 |
| **P6 자막·스탬프·다듬기** | Speech 자동 자막, 위치·날짜 스탬프, 여행 프로젝트 정리(A1), 프리셋 백업(A2) | 자막 포함 쇼츠 완성 | 2일 |
| **P7 안정화·성능** | 열 관리, 메모리(4K 프레임), 배터리, 오류 처리, 테스트 | 20분 연속 촬영에 문제 없음 | 2일 |

합계 약 **21일** (Mac 빌드 왕복 시간 별도). P1→P2→P3, P4→P5는 순차. P2/P3와 P4는 병행 가능.

**작업 방식**: 이 저장소에서 Swift 코드 작성 → 사용자 Mac에서 pull·빌드 → 빌드 로그/스크린샷 공유 → 수정. 단계마다 "Mac에서 할 일 체크리스트"를 문서로 제공.

---

## 11. 논의가 필요한 결정 사항

| # | 질문 | 제 추천 | 영향 |
|---|---|---|---|
| Q1 | **Mac과 Xcode를 사용할 수 있는지** (macOS 버전, Xcode 버전) | 필수 전제. 없으면 iOS 네이티브 앱 자체가 불가 | 전체 |
| Q2 | Apple Developer 계정: 무료(7일 재설치) vs 유료 $99/년(1년 유효) | **유료** — 여행 중 앱이 만료되면 곤란 | 배포 |
| Q3 | 사용 iPhone 모델과 iOS 버전 | 알려주시면 최소 버전·ProRAW/ProRes·초광각 등 옵션 확정 | 기능 범위 |
| Q4 | 쇼츠 주 타겟 플랫폼 | Reels + Shorts + TikTok 셋 다 9:16이라 **기본 9:16, 4:5/1:1은 옵션** | 규격 프리셋 |
| Q5 | 촬영 해상도 정책 | **세로 4K30 원본 고정**, 필요 시 60fps 옵션 | 저장공간·발열 |
| Q6 | 딥러닝 보정(Zero-DCE) 포함 여부 | 포함. 단, P3로 후순위. Core ML 변환은 Mac에서 실행 필요 | 일정 |
| Q7 | 음악 소스 | 파일 앱/사진 앱에서 가져오기(저작권은 본인 책임). Apple Music은 DRM으로 불가 | 조립 |
| Q8 | 자동 자막(Speech) 포함 여부 | 포함(기기 내 처리, 무료) | P6 |
| Q9 | 추가 기능 A1~A10 중 채택 범위 | A1, A2, A3, A5 채택. A4·A6·A10은 여유 시. A7·A8·A9 제외 | 일정 |
| Q10 | 앱 이름·아이콘 | 논의 | 소소 |

---

## 12. 비기능 요구사항
- **성능**: 프리뷰 필터 30fps 이상(1080p 프리뷰), 풀해상도 사진 보정 3초 이내, 30초 쇼츠 내보내기 1분 이내(HEVC 하드웨어 인코딩).
- **안정성**: 촬영 중 앱 종료돼도 파일이 남도록 `AVAssetWriter` 세그먼트 저장. 저장 실패 시 임시 폴더 보존.
- **저장공간**: 원본은 항상 사진 앱에. 앱 캐시는 설정에서 비우기 가능.
- **접근성·UX**: 시스템 카메라와 같은 제스처(탭 포커스, 핀치 줌), 다크 UI, 한 손 조작 가능한 하단 배치.
- **프라이버시**: 네트워크 권한 자체를 사용하지 않음(역지오코딩만 Apple `CLGeocoder` 사용, 옵션으로 끔).

---

## 13. 다음 행동
1. §11 항목 답변 → 계획서 v0.2 확정.
2. P0 착수: Xcode 프로젝트 생성 스크립트·구조를 저장소에 커밋, Mac 빌드 체크리스트 제공.
