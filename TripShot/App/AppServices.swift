// 앱 전역 의존성(렌더러·사진 저장·위치)과 앱 수준 상태(인물 모드 스위치·선택 프리셋)를 한곳에서 만들어 주입한다.
import Combine
import Foundation
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
    }

    let renderer: EnhanceRenderer
    let photoSaver: PhotoSaver
    let locationProvider = LocationProvider()
    /// 저장·앨범 경로의 얼굴 검출기(상태 없음, 스레드 안전).
    let faceDetector = FaceDetector()
    /// 인물 보정 Metal 커널. 처음 쓸 때 한 번 로드한다. 로드 실패면 nil(피부색 마스크·주파수 분리 없이 폴백).
    private(set) lazy var portraitKernels: PortraitKernels? = PortraitKernels.load()

    /// 인물 모드 스위치. 마지막 상태를 기억한다(PLAN §3.3). 기본 꺼짐.
    @Published var portraitModeEnabled: Bool {
        didSet { defaults.set(portraitModeEnabled, forKey: Keys.portraitMode) }
    }

    /// 촬영·앨범 화면이 공유하는 선택 프리셋(`Preset.id`). nil이면 자동 보정 기본값.
    @Published var selectedPresetID: UUID? {
        didSet { defaults.set(selectedPresetID?.uuidString, forKey: Keys.selectedPresetID) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let renderer = EnhanceRenderer()
        self.renderer = renderer
        self.photoSaver = PhotoSaver(renderer: renderer)
        self.defaults = defaults
        _portraitModeEnabled = Published(initialValue: defaults.bool(forKey: Keys.portraitMode))
        _selectedPresetID = Published(initialValue: defaults.string(forKey: Keys.selectedPresetID).flatMap(UUID.init(uuidString:)))
    }

    /// 렌더마다 넘길 파이프라인 컨텍스트. 렌더러의 공유 컨텍스트(LUT 등)를 복사하고
    /// 인물 단계 hook만 스위치 상태에 맞춰 바꾼다. 공유 컨텍스트 자체는 바꾸지 않는다.
    /// - Parameters:
    ///   - quality: `.full`(저장·앨범·촬영 후처리) = 매번 검출 + 주파수 분리.
    ///     `.live`(라이브 프리뷰) = `liveTracker`의 평활 검출 + 경량 블러. `.live`인데 트래커가 없으면 `.full`.
    ///   - liveTracker: 라이브 경로의 트래커(CaptureViewModel 소유, 비디오 큐 전용).
    func pipelineContext(quality: PortraitQuality = .full, liveTracker: SmoothedFaceTracker? = nil) -> PipelineContext {
        var context = renderer.pipelineContext
        guard portraitModeEnabled else {
            context.portraitStage = nil
            return context
        }
        let kernels = portraitKernels
        if quality == .live, let tracker = liveTracker {
            context.portraitStage = PortraitStage.live(tracker: tracker, kernels: kernels)
        } else {
            context.portraitStage = PortraitStage.full(detector: faceDetector, kernels: kernels)
        }
        return context
    }
}
