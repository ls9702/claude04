// 라이브 프리뷰 한 프레임의 보정: 카메라 프레임 → 다운샘플 → 보정 파이프라인 → CIImage (픽셀 렌더는 MetalPreviewView 담당).
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

// MARK: - 설정

/// 라이브 파이프라인 설정. 세 값을 한 번에(원자적으로) 교체한다.
/// 저장(후처리)도 같은 `params`·`context`를 쓰므로 프리뷰와 저장본은 해상도만 다르다.
struct LiveSettings {
    var params: PresetParams = PresetParams()
    var context: PipelineContext = PipelineContext()
    /// 프리뷰 긴 변 상한(픽셀). 열 상태에 따라 `PreviewQuality`가 정한다.
    var maxDimension: CGFloat = PreviewQuality.baseDimension
}

// MARK: - 열 상태 → 프리뷰 해상도

/// 기기 열 상태에 따른 프리뷰 해상도. 순수 함수만 둔다(관찰은 CaptureViewModel).
enum PreviewQuality {
    /// 기본 프리뷰 긴 변. 보정 파이프라인의 공간 반경 기준 해상도(`Mapping.referenceDimension`)와 같다.
    static let baseDimension: CGFloat = 1024

    /// nominal/fair → base, serious → base×0.75, critical → base×0.5.
    /// 공간 필터 반경은 `Mapping.resolutionScale`로 해상도에 비례하므로 해상도를 낮춰도 보이는 결과는 같다(더 흐릴 뿐).
    static func maxDimension(for state: ProcessInfo.ThermalState, base: CGFloat = baseDimension) -> CGFloat {
        switch state {
        case .nominal, .fair: return base
        case .serious: return base * 0.75
        case .critical: return base * 0.5
        @unknown default: return base
        }
    }
}

// MARK: - 백프레셔

/// 동시에 처리 중인 프레임 수를 세는 문(순수 값 타입, 스레드 안전하지 않음 — `LockedFrameGate`가 감싼다).
/// 한도(기본 1)만큼 처리 중이면 새 프레임은 들어오지 못하고 버려진다. 렌더가 느려도 대기열이 쌓이지 않는다.
struct FrameGate {
    let limit: Int
    private(set) var inFlight = 0

    init(limit: Int = 1) {
        self.limit = max(1, limit)
    }

    /// 들어갈 수 있으면 카운터를 올리고 true. 한도에 차 있으면 false(이 프레임은 버린다).
    mutating func tryEnter() -> Bool {
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    /// 처리 완료(또는 중도 포기). 0 아래로 내려가지 않는다.
    mutating func leave() {
        inFlight = max(0, inFlight - 1)
    }
}

/// `FrameGate`의 스레드 안전 버전. 비디오 큐에서 들어가고, GPU 완료 핸들러(임의 스레드)나 메인에서 나간다.
final class LockedFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: FrameGate

    init(limit: Int = 1) {
        gate = FrameGate(limit: limit)
    }

    func tryEnter() -> Bool { lock.withLock { gate.tryEnter() } }
    func leave() { lock.withLock { gate.leave() } }
    var inFlight: Int { lock.withLock { gate.inFlight } }
}

// MARK: - 파이프라인

/// "카메라 프레임 → 보정된 CIImage". 렌더(픽셀 계산)는 하지 않고 CIImage 그래프만 만든다.
///
/// 스레드 규칙:
/// - `process(_:orientation:)`는 **한 직렬 큐(카메라 비디오 큐)에서만** 호출한다. 자동 보정 필터 캐시가 이 큐 전용이다.
/// - `update(_:)`·`isEnabled`는 어느 스레드에서나(보통 메인) 호출해도 된다. 설정은 잠금으로 통째로 교체한다.
///
/// 프리뷰와 저장의 동일성: 두 경로 모두 `EnhancePipeline.apply`를 같은 `params`·`context`로 부른다.
/// 차이는 (1) 프리뷰는 `maxDimension`으로 다운샘플한 입력, (2) 1단계 자동 보정의 "분석"을 몇 프레임마다 한 번만 하고
/// 그 필터를 재사용한다는 점뿐이다(분석 결과를 적용하는 코드는 `EnhancePipeline.applyAutoFilters`로 같다).
final class LivePipeline: @unchecked Sendable {
    /// 자동 보정 분석을 다시 하는 프레임 간격(30fps 기준 약 0.5초).
    /// TODO(검증): 실기기에서 `autoAdjustmentFilters` 분석 비용을 재 보고 간격을 조정(비용이 작으면 1로).
    static let autoRefreshInterval = 15

    private let lock = NSLock()
    private var settings = LiveSettings()
    private var settingsVersion = 0
    private var enabled = true

    // 비디오 큐 전용 상태(잠금 없음).
    private var cachedAutoFilters: [CIFilter] = []
    private var cachedAutoVersion = -1
    private var framesSinceAutoAnalysis = 0

    init(settings: LiveSettings = LiveSettings()) {
        self.settings = settings
    }

    /// 설정 교체(원자적). 다음 프레임부터 적용된다.
    func update(_ newSettings: LiveSettings) {
        lock.withLock {
            settings = newSettings
            settingsVersion &+= 1
        }
    }

    /// 현재 설정 사본.
    var currentSettings: LiveSettings { lock.withLock { settings } }

    /// false면 `process`가 바로 nil을 돌려준다(백그라운드·다른 탭).
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// 프레임 하나를 보정한 CIImage. 비활성이면 nil.
    /// - Parameter orientation: 프레임을 세로로 세우는 방향. 카메라 연결이 90° 회전을 지원하면 `.up`,
    ///   지원하지 않으면(폴백) `.right`(시계 방향 90°).
    func process(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> CIImage? {
        let (current, version, isOn) = lock.withLock { (settings, settingsVersion, enabled) }
        guard isOn else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if orientation != .up {
            image = image.oriented(orientation)
        }
        image = EnhanceRenderer.downsample(image, maxDimension: current.maxDimension)

        var params = current.params
        if params.auto {
            // 1단계 자동 보정: 분석은 가끔, 적용은 매 프레임. 적용 후 파이프라인에서는 자동 단계를 끈다.
            if version != cachedAutoVersion || framesSinceAutoAnalysis >= Self.autoRefreshInterval {
                cachedAutoFilters = EnhancePipeline.autoFilters(for: image)
                cachedAutoVersion = version
                framesSinceAutoAnalysis = 0
            } else {
                framesSinceAutoAnalysis += 1
            }
            let input = image
            image = EnhancePipeline.applyAutoFilters(cachedAutoFilters, to: input)
            // 필터가 이번 프레임(픽셀 버퍼)을 붙잡고 있지 않도록 입력을 비운다. 이미 만든 출력 CIImage에는 영향 없음.
            // TODO(검증): CIFilter.outputImage가 호출 시점의 입력을 캡처한 불변 그래프라는 가정(일반적으로 그렇다).
            for filter in cachedAutoFilters { filter.setValue(nil, forKey: kCIInputImageKey) }
            params.auto = false
        }
        return EnhancePipeline.apply(params, to: image, context: current.context)
    }
}
