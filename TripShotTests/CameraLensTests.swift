// R1-S8a 카메라 테스트: 활성 포맷 선택(CameraFormatPicker), 렌즈 표시 배율 환산(LensZoom), 렌즈 버튼 강조.
import CoreGraphics
import XCTest
@testable import TripShot

final class CameraLensTests: XCTestCase {

    private let full = PixelSize(width: 4032, height: 3024)
    private let small = PixelSize(width: 1920, height: 1440)

    // MARK: CameraFormatPicker

    /// iPhone 12 Pro 비슷한 포맷 목록(순서는 기기 목록처럼 작은 것 → 큰 것).
    private var formats12Pro: [FormatInfo] {
        [
            FormatInfo(width: 640, height: 480, maxFrameRate: 30, maxPhotoDimensions: [PixelSize(width: 640, height: 480)]),
            FormatInfo(width: 1280, height: 720, maxFrameRate: 60, maxPhotoDimensions: [PixelSize(width: 1280, height: 720)]),   // 16:9
            FormatInfo(width: 1440, height: 1080, maxFrameRate: 30, maxPhotoDimensions: [small, full], isFullRange: false),
            FormatInfo(width: 1440, height: 1080, maxFrameRate: 30, maxPhotoDimensions: [small, full]),
            FormatInfo(width: 1920, height: 1080, maxFrameRate: 60, maxPhotoDimensions: [full]),                                 // 16:9
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [small], isBinned: true),
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [small, full], isFullRange: false),
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [small, full]),                          // ← 기대
            FormatInfo(width: 4032, height: 3024, maxFrameRate: 30, maxPhotoDimensions: [full]),                                 // 너무 큼
        ]
    }

    func testPicksLargest4by3UnderLimitWithFullPhoto() {
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats12Pro), 7)
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats12Pro, requireFullPhoto: true), 7)
    }

    func testPrefersFullPhotoOverLargerVideo() {
        // 1920×1440은 사진이 작고 1440×1080은 풀 사진 → 풀 사진 우선.
        let formats = [
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [small]),
            FormatInfo(width: 1440, height: 1080, maxFrameRate: 30, maxPhotoDimensions: [full]),
            FormatInfo(width: 4032, height: 3024, maxFrameRate: 30, maxPhotoDimensions: [full]),
        ]
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats), 1)
    }

    func testRequireFullPhotoReturnsNilWhenNoCandidateHasIt() {
        let formats = [
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [small]),
            FormatInfo(width: 4032, height: 3024, maxFrameRate: 30, maxPhotoDimensions: [full]),
        ]
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats), 0, "우선순위만 쓰면 작은 사진이라도 고른다")
        XCTAssertNil(CameraFormatPicker.pick(formats: formats, requireFullPhoto: true), "풀 사진이 필수면 폴백(.photo)")
    }

    func testRejectsFormatsBelowFrameRate() {
        let formats = [
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 24, maxPhotoDimensions: [full]),
            FormatInfo(width: 1440, height: 1080, maxFrameRate: 30, maxPhotoDimensions: [full]),
        ]
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats, frameRate: 30), 1)
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats, frameRate: 24), 0)
    }

    func testNoCandidateReturnsNil() {
        XCTAssertNil(CameraFormatPicker.pick(formats: []))
        let wideOnly = [FormatInfo(width: 1920, height: 1080, maxFrameRate: 30, maxPhotoDimensions: [full])]
        XCTAssertNil(CameraFormatPicker.pick(formats: wideOnly), "4:3이 아니면 제외")
    }

    func testLargestPhotoDimensions() {
        XCTAssertEqual(CameraFormatPicker.largestPhotoDimensions([small, full]), full)
        XCTAssertNil(CameraFormatPicker.largestPhotoDimensions([]))
    }

    // MARK: LensZoom

    func testTripleCameraDisplayFactors() {
        let triple: [CGFloat] = [2, 4]   // 12 Pro: 1.0 초광각, 2.0 광각, 4.0 망원
        XCTAssertEqual(LensZoom.displayFactor(videoZoom: 1, switchOvers: triple), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.displayFactor(videoZoom: 2, switchOvers: triple), 1, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.displayFactor(videoZoom: 4, switchOvers: triple), 2, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.videoZoom(forDisplay: 0.5, switchOvers: triple), 1, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.videoZoom(forDisplay: 1, switchOvers: triple), 2, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.videoZoom(forDisplay: 2, switchOvers: triple), 4, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.videoZoom(forDisplay: 10, switchOvers: triple), 20, accuracy: 1e-9)
        XCTAssertEqual(LensZoom.availableDisplayFactors(switchOvers: triple), [0.5, 1, 2])
    }

    func testRoundTrip() {
        for switchOvers: [CGFloat] in [[2, 6], [2], []] {
            for display: CGFloat in [0.5, 1, 1.7, 2, 7.3] {
                let video = LensZoom.videoZoom(forDisplay: display, switchOvers: switchOvers)
                XCTAssertEqual(LensZoom.displayFactor(videoZoom: video, switchOvers: switchOvers), display, accuracy: 1e-9)
            }
        }
    }

    func testDualWideAndSingleLens() {
        XCTAssertEqual(LensZoom.availableDisplayFactors(switchOvers: [2]), [0.5, 1], "듀얼 와이드: 망원 없음")
        XCTAssertEqual(LensZoom.availableDisplayFactors(switchOvers: []), [1], "광각 단일·전면")
        XCTAssertEqual(LensZoom.displayFactor(videoZoom: 3, switchOvers: []), 3, accuracy: 1e-9, "단일 렌즈는 배율 그대로")
        XCTAssertEqual(LensZoom.wideZoomFactor(switchOvers: []), 1)
    }

    // MARK: 렌즈 버튼 강조

    func testSelectedLensButton() {
        let factors: [CGFloat] = [0.5, 1, 2]
        XCTAssertEqual(CaptureView.selectedLens(zoom: 0.5, factors: factors), 0.5)
        XCTAssertEqual(CaptureView.selectedLens(zoom: 0.999, factors: factors), 1, "반올림 오차 허용")
        XCTAssertEqual(CaptureView.selectedLens(zoom: 1.4, factors: factors), 1)
        XCTAssertEqual(CaptureView.selectedLens(zoom: 5, factors: factors), 2)
        XCTAssertEqual(CaptureView.lensLabel(0.5), "0.5×")
        XCTAssertEqual(CaptureView.lensLabel(2), "2×")
    }
}
