// 카메라 활성 포맷 선택과 렌즈(표시 배율 ↔ videoZoomFactor) 환산. AVFoundation 객체를 값으로 옮겨 순수 함수로 계산한다(테스트 대상).
import CoreGraphics
import Foundation

// MARK: - 활성 포맷 선택

/// `AVCaptureDevice.Format`에서 선택에 필요한 값만 옮긴 값 타입. 크기는 센서 기준(가로가 긴 변)이다.
struct FormatInfo: Equatable {
    /// 비디오(프리뷰 프레임) 크기.
    var width: Int
    var height: Int
    /// `videoSupportedFrameRateRanges`의 최대 fps.
    var maxFrameRate: Double
    /// `supportedMaxPhotoDimensions`(이 포맷에서 가능한 사진 최대 크기 목록).
    var maxPhotoDimensions: [PixelSize]
    /// `isVideoBinned`. 비닝 포맷은 사진 해상도·화질이 낮은 경우가 많아 뒤로 미룬다.
    var isBinned: Bool
    /// 420f(풀 레인지) 여부. `.photo` 프리셋이 쓰는 형식이라 같은 조건이면 이쪽을 고른다.
    var isFullRange: Bool

    init(width: Int, height: Int, maxFrameRate: Double, maxPhotoDimensions: [PixelSize],
         isBinned: Bool = false, isFullRange: Bool = true) {
        self.width = width
        self.height = height
        self.maxFrameRate = maxFrameRate
        self.maxPhotoDimensions = maxPhotoDimensions
        self.isBinned = isBinned
        self.isFullRange = isFullRange
    }

    var videoArea: Int { width * height }
    /// 이 포맷에서 가능한 가장 큰 사진 면적.
    var maxPhotoArea: Int { maxPhotoDimensions.map(\.area).max() ?? 0 }
    /// 이 포맷에서 가능한 사진의 가장 긴 변.
    var maxPhotoLongSide: Int { maxPhotoDimensions.map { max($0.width, $0.height) }.max() ?? 0 }
}

/// 정수 픽셀 크기(`CMVideoDimensions`의 값 사본).
struct PixelSize: Equatable, Hashable {
    var width: Int
    var height: Int
    var area: Int { width * height }
}

/// 라이브 프리뷰용 활성 포맷 선택.
///
/// 배경(R1-S8a): `.photo` 프리셋에서는 비디오 데이터 출력 프레임이 12MP급으로 와서 매 프레임 다운샘플 비용이 컸다.
/// 비디오는 1920×1440 이하로 받고, 사진은 `photoOutput.maxPhotoDimensions`로 풀해상도를 유지한다.
enum CameraFormatPicker {
    /// 비디오 긴 변·짧은 변 상한(4:3 기준 1920×1440).
    static let maxVideoLongSide = 1920
    static let maxVideoShortSide = 1440

    /// 조건에 맞는 포맷의 인덱스. 없으면 nil(호출 측은 `.photo` 프리셋으로 폴백).
    ///
    /// 조건: `aspect` 비율(기본 4:3, 촬영 탭은 16:9), 비디오 1920×1440 이하, `frameRate` fps 지원.
    /// 순위: (1) 같은 비율 포맷 중 가장 큰 사진 크기를 지원 → (2) 비디오 면적이 큰 것 → (3) 비닝 아님 → (4) 풀 레인지 → (5) 앞쪽 인덱스.
    /// - Parameter aspect: (긴 변, 짧은 변) 비율. 16:9 포맷은 사진도 16:9(12 Pro 4032×2268)로 찍힌다.
    /// - Parameter requireFullPhoto: true면 사진 긴 변이 전체 포맷 중 가장 긴 사진 긴 변보다 짧은 포맷은 제외한다
    ///   (사진 해상도를 잃느니 폴백이 낫다 — 카메라 서비스는 true로 부른다). 16:9는 긴 변(4032)으로 비교한다.
    static func pick(formats: [FormatInfo], frameRate: Double = 30, requireFullPhoto: Bool = false,
                     aspect: AspectRatio = .fourByThree) -> Int? {
        let bestLongSide = formats.map(\.maxPhotoLongSide).max() ?? 0
        let candidates = formats.indices.filter { i in
            let f = formats[i]
            let long = max(f.width, f.height), short = min(f.width, f.height)
            guard long > 0, short > 0 else { return false }
            guard long * aspect.short == short * aspect.long else { return false }
            guard long <= maxVideoLongSide, short <= maxVideoShortSide else { return false }
            guard f.maxFrameRate + 0.01 >= frameRate else { return false }
            if requireFullPhoto && f.maxPhotoLongSide < bestLongSide { return false }
            return true
        }
        let bestCandidateArea = candidates.map { formats[$0].maxPhotoArea }.max() ?? 0
        return candidates.min { a, b in
            let fa = formats[a], fb = formats[b]
            let fullA = fa.maxPhotoArea >= bestCandidateArea, fullB = fb.maxPhotoArea >= bestCandidateArea
            if fullA != fullB { return fullA }
            if fa.videoArea != fb.videoArea { return fa.videoArea > fb.videoArea }
            if fa.isBinned != fb.isBinned { return !fa.isBinned }
            if fa.isFullRange != fb.isFullRange { return fa.isFullRange }
            return a < b
        }
    }

    /// 사진 최대 크기 목록 중 면적이 가장 큰 것. `aspect`를 주면 그 비율인 것 중에서 고르고, 없으면 전체에서.
    static func largestPhotoDimensions(_ dims: [PixelSize], aspect: AspectRatio? = nil) -> PixelSize? {
        if let aspect {
            let matching = dims.filter { aspect.matches($0) }
            if let best = matching.max(by: { $0.area < $1.area }) { return best }
        }
        return dims.max { $0.area < $1.area }
    }
}

/// 가로:세로 비율(긴 변 : 짧은 변). 방향과 무관하게 비교한다.
struct AspectRatio: Equatable {
    var long: Int
    var short: Int

    static let fourByThree = AspectRatio(long: 4, short: 3)
    static let sixteenByNine = AspectRatio(long: 16, short: 9)

    /// 크기가 이 비율인지. 4032×2268처럼 정수로 딱 떨어지지 않는 센서 크기도 있어 1% 오차를 허용한다.
    func matches(_ size: PixelSize) -> Bool {
        let l = max(size.width, size.height), s = min(size.width, size.height)
        guard l > 0, s > 0 else { return false }
        return abs(Double(l) * Double(short) - Double(s) * Double(long)) <= 0.01 * Double(s) * Double(long)
    }

    /// 세로 화면 기준 가로/세로(예: 16:9 → 9/16).
    var portraitWidthOverHeight: Double { Double(short) / Double(long) }
}

// MARK: - 렌즈 배율

/// 가상 다중 카메라(트리플·듀얼 와이드)의 `videoZoomFactor` ↔ 사용자에게 보이는 배율(0.5×/1×/2×) 환산.
///
/// `virtualDeviceSwitchOverVideoZoomFactors`는 다음 렌즈로 넘어가는 `videoZoomFactor` 목록이다.
/// 예: iPhone 12 Pro 트리플 [2, 4] → 1.0 = 초광각, 2.0 = 광각, 4.0 = 망원.
/// 이 앱은 후면에 트리플 → 듀얼 와이드 → 광각 순으로 기기를 고르므로, 목록이 비어 있지 않으면 **첫 값이 광각 전환 계수**다
/// (초광각이 기본 렌즈인 구성만 쓴다. 광각+망원 `.builtInDualCamera`는 쓰지 않는다).
/// 표시 배율 = videoZoomFactor / 광각 전환 계수. 목록이 비면(단일 렌즈·전면) 계수 1.
enum LensZoom {
    /// 핀치 줌 표시 배율 범위.
    static let minDisplayFactor: CGFloat = 0.5
    static let maxDisplayFactor: CGFloat = 10
    /// 렌즈 버튼 후보(표시 배율).
    static let buttonFactors: [CGFloat] = [0.5, 1, 2]

    /// 광각(1×)에 해당하는 videoZoomFactor.
    static func wideZoomFactor(switchOvers: [CGFloat]) -> CGFloat {
        guard let first = switchOvers.first, first > 0 else { return 1 }
        return first
    }

    static func displayFactor(videoZoom: CGFloat, switchOvers: [CGFloat]) -> CGFloat {
        videoZoom / wideZoomFactor(switchOvers: switchOvers)
    }

    static func videoZoom(forDisplay display: CGFloat, switchOvers: [CGFloat]) -> CGFloat {
        display * wideZoomFactor(switchOvers: switchOvers)
    }

    /// 이 기기에서 보일 렌즈 버튼(표시 배율).
    /// - 0.5×: 초광각이 있을 때(전환 계수가 1개 이상).
    /// - 1×: 항상.
    /// - 2×: 망원이 있을 때(전환 계수가 2개 이상 = 트리플). 12 Pro 망원은 정확히 2×, 3×·5× 망원 기기에서는
    ///   2×가 광각 디지털 크롭 구간이 된다(버튼은 같은 표시 배율로 둔다).
    static func availableDisplayFactors(switchOvers: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        if !switchOvers.isEmpty { result.append(0.5) }
        result.append(1)
        if switchOvers.count >= 2 { result.append(2) }
        return result
    }
}
