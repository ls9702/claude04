// 앱 전역 의존성(렌더러·사진 저장·위치)과 앱 수준 상태(인물 모드 스위치·선택 프리셋)를 한곳에서 만들어 주입한다.
import Combine
import Foundation
import os
import SwiftUI

/// 앱에 하나만 두는 서비스 묶음. `TripShotApp`에서 `@StateObject`로 만들고 `.environmentObject`로 주입한다.
/// - 렌더러는 CIContext를 재사용하므로 하나만 만든다(생성 비용이 큼).
/// - 인물 모드 스위치는 프리셋 속성(`PresetParams.portrait.enabled`)이 아니라 **앱 상태**다(REVIEW_LOG R1-S1 권고).
///   스위치가 꺼지면 `pipelineContext()`가 `portraitStage = nil`을 돌려줘 프리셋 값과 무관하게 인물 단계를 건너뛴다.
@MainActor
final class AppServices: ObservableObject {
    private enum Keys {
        static let portraitMode = "portraitMode"
        static let selectedPresetID = "selectedPresetID"
        static let portraitStrength = "portraitStrength"
        static let customPortrait = "customPortrait"
        static let preferredFrameRate = "preferredFrameRate"
        static let installDate = "installDate"
        static let installStamp = "installStamp"
    }

    private static let log = Logger(subsystem: "com.ls9702.tripshot", category: "services")

    /// 설정 탭 프레임 레이트 선택지(발열·배터리 완화용 24).
    static let frameRateOptions: [Double] = [30, 24]

    let renderer: EnhanceRenderer
    let photoSaver: PhotoSaver
    let locationProvider = LocationProvider()
    /// 저장·앨범 경로의 얼굴 검출기(상태 없음, 스레드 안전).
    let faceDetector = FaceDetector()
    /// 전신 보정(몸 슬림·다리 길게)용 자세 검출. 저장·앨범 경로에서만 쓴다.
    let bodyPoseDetector = BodyPoseDetector()
    /// 인물 보정 Metal 커널. 처음 쓸 때 한 번 로드한다. 로드 실패면 nil(피부색 마스크·주파수 분리 없이 폴백).
    /// 실패는 로그만 남기고 UI는 설정 탭 "정보"의 상태 표시로 알린다.
    private(set) lazy var portraitKernels: PortraitKernels? = {
        let kernels = PortraitKernels.load()
        if kernels == nil { Self.log.error("인물 보정 Metal 커널 로드 실패 → 폴백(피부 마스크·주파수 분리 없음)") }
        else if kernels?.faceWarp == nil { Self.log.error("얼굴 워프 커널 로드 실패 → 윤곽·눈 보정 건너뜀") }
        return kernels
    }()
    /// 저조도(Zero-DCE++) 보정기. 처음 쓸 때 모델·커널을 로드한다. 모델이 없으면 폴백 보정으로 동작한다.
    /// 실패는 로그만(LowLightEnhancer가 이유를 남긴다). UI는 설정 탭 상태 표시.
    private(set) lazy var lowLight: LowLightEnhancer = {
        let enhancer = LowLightEnhancer()
        if !enhancer.isModelAvailable { Self.log.error("저조도 모델 없음 → 폴백 보정") }
        if !enhancer.isKernelAvailable { Self.log.error("저조도 곡선 커널 로드 실패 → 폴백 보정") }
        return enhancer
    }()

    /// 인물 모드 스위치. 마지막 상태를 기억한다(PLAN §3.3). 기본 꺼짐.
    @Published var portraitModeEnabled: Bool {
        didSet { defaults.set(portraitModeEnabled, forKey: Keys.portraitMode) }
    }

    /// 촬영·앨범 화면이 공유하는 선택 프리셋(`Preset.id`). nil이면 자동 보정 기본값.
    @Published var selectedPresetID: UUID? {
        didSet { defaults.set(selectedPresetID?.uuidString, forKey: Keys.selectedPresetID) }
    }

    /// 인물 강도 칩(자연/보통/강함). 마지막 선택을 기억한다. 기본 보통. 칩을 고르면 `customPortrait`는 nil.
    @Published var portraitStrength: PortraitStrength {
        didSet { defaults.set(portraitStrength.rawValue, forKey: Keys.portraitStrength) }
    }

    /// 사용자가 슬라이더로 만든 "직접" 인물 값. nil이면 `portraitStrength`의 값을 쓴다. 칩 선택 시 nil.
    @Published var customPortrait: PortraitParams? {
        didSet {
            if let customPortrait, let data = try? JSONEncoder().encode(customPortrait) {
                defaults.set(data, forKey: Keys.customPortrait)
            } else {
                defaults.removeObject(forKey: Keys.customPortrait)
            }
        }
    }

    /// 라이브 프리뷰 프레임 레이트(30 또는 24). 촬영 탭이 카메라에 적용한다(저전력 모드면 자동 24).
    @Published var preferredFrameRate: Double {
        didSet {
            // didSet 안에서 자기 자신을 다시 설정해도 didSet은 다시 불리지 않는다(Swift 규칙).
            let normalized = Self.normalizedFrameRate(preferredFrameRate)
            if normalized != preferredFrameRate { preferredFrameRate = normalized }
            defaults.set(normalized, forKey: Keys.preferredFrameRate)
        }
    }

    /// 이번 설치(빌드)를 처음 실행한 날. 무료 서명 만료 추정에 쓴다(`SigningInfo`).
    let installDate: Date

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let renderer = EnhanceRenderer()
        self.renderer = renderer
        self.photoSaver = PhotoSaver(renderer: renderer)
        self.defaults = defaults
        _portraitModeEnabled = Published(initialValue: defaults.bool(forKey: Keys.portraitMode))
        _selectedPresetID = Published(initialValue: defaults.string(forKey: Keys.selectedPresetID).flatMap(UUID.init(uuidString:)))
        _portraitStrength = Published(initialValue: defaults.string(forKey: Keys.portraitStrength)
            .flatMap(PortraitStrength.init(rawValue:)) ?? .normal)
        _customPortrait = Published(initialValue: defaults.data(forKey: Keys.customPortrait)
            .flatMap { try? JSONDecoder().decode(PortraitParams.self, from: $0) })
        _preferredFrameRate = Published(initialValue: Self.normalizedFrameRate(
            defaults.object(forKey: Keys.preferredFrameRate) as? Double ?? 30))
        installDate = SigningInfo.recordInstallDate(defaults: defaults,
                                                    dateKey: Keys.installDate,
                                                    stampKey: Keys.installStamp,
                                                    currentStamp: SigningInfo.currentBuildStamp())
    }

    /// 30·24 외의 값은 30으로.
    nonisolated static func normalizedFrameRate(_ value: Double) -> Double {
        abs(value - 24) < 0.5 ? 24 : 30
    }

    // MARK: 설정 백업·초기화

    /// 앱 설정을 기본값으로(인물 모드 끔·보통·직접 값 없음·선택 프리셋 없음·30fps). 사진·프리셋 목록은 건드리지 않는다.
    func resetSettings() {
        portraitModeEnabled = false
        portraitStrength = .normal
        customPortrait = nil
        selectedPresetID = nil
        preferredFrameRate = 30
        defaults.removeObject(forKey: CaptureViewModel.portraitSuggestionKey)
    }

    // MARK: 인물 강도

    /// 촬영·앨범 공통: 프리셋(또는 현재) 인물 값 위에 칩·직접 값을 덮어쓴 최종 값.
    /// 규칙은 `PortraitStrength.effective` 참고(원본 등 `enabled == false`는 그대로).
    func effectivePortrait(base: PortraitParams) -> PortraitParams {
        PortraitStrength.effective(base: base, strength: portraitStrength, custom: customPortrait)
    }

    /// 칩 선택: 단계 저장 + 직접 값 해제.
    func selectPortraitStrength(_ strength: PortraitStrength) {
        customPortrait = nil
        portraitStrength = strength
    }

    /// 렌더마다 넘길 파이프라인 컨텍스트. 렌더러의 공유 컨텍스트(LUT 등)를 복사하고
    /// 인물 단계 hook(스위치 상태)과 저조도 hook(품질)을 채운다. 공유 컨텍스트 자체는 바꾸지 않는다.
    /// - Parameters:
    ///   - quality: `.full`(저장·앨범·촬영 후처리) = 매번 검출 + 주파수 분리.
    ///     `.live`(라이브 프리뷰) = `liveTracker`의 평활 검출 + 경량 블러. `.live`인데 트래커가 없으면 `.full`.
    ///     저조도 hook은 `.full`에서만 넣는다(`.live`는 트래커 유무와 관계없이 저조도 없음).
    ///   - liveTracker: 라이브 경로의 트래커(CaptureViewModel 소유, 비디오 큐 전용).
    func pipelineContext(quality: PortraitQuality = .full, liveTracker: SmoothedFaceTracker? = nil) -> PipelineContext {
        var context = renderer.pipelineContext
        // 5단계 저조도: 저장·앨범·촬영 후처리(.full)에서만. 라이브 프리뷰는 비활성(PLAN §3.2).
        // 앨범 프리뷰(EnhanceViewModel)도 .full이라 1024 프리뷰에서 모델이 돈다 — 512 추론 수십 ms라
        // 80ms 디바운스 렌더에 충분하고, 저장 결과를 미리 볼 수 있어 따로 끄는 플래그는 두지 않는다.
        context.lowLightStage = quality == .full ? LowLightStage.make(enhancer: lowLight) : nil
        guard portraitModeEnabled else {
            context.portraitStage = nil
            return context
        }
        let kernels = portraitKernels
        if quality == .live, let tracker = liveTracker {
            context.portraitStage = PortraitStage.live(tracker: tracker, kernels: kernels)
        } else {
            context.portraitStage = PortraitStage.full(detector: faceDetector, bodyDetector: bodyPoseDetector,
                                                       kernels: kernels)
            // 앨범 프리뷰(`isPreview = true`로 복사한 컨텍스트)는 배경 분리를 `.balanced`로 한다(EnhancePipeline이 고른다).
            context.portraitPreviewStage = PortraitStage.full(detector: faceDetector, bodyDetector: bodyPoseDetector,
                                                              kernels: kernels,
                                                              segmentationPreview: true)
        }
        return context
    }
}
