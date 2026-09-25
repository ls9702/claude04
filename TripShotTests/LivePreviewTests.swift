// R1-S4 라이브 보정 프리뷰 테스트: 백프레셔 게이트, 열 상태 해상도, aspect-fill 배치, 탭 포커스 좌표, 프레임 보정 경로.
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import XCTest
@testable import TripShot

final class LivePreviewTests: XCTestCase {

    private let accuracy: CGFloat = 1e-6

    // MARK: FrameGate

    func testFrameGateRejectsSecondFrameUntilLeave() {
        var gate = FrameGate()
        XCTAssertTrue(gate.tryEnter())
        XCTAssertFalse(gate.tryEnter(), "처리 중이면 새 프레임은 버린다")
        XCTAssertEqual(gate.inFlight, 1)
        gate.leave()
        XCTAssertEqual(gate.inFlight, 0)
        XCTAssertTrue(gate.tryEnter(), "처리가 끝나면 다시 받는다")
    }

    func testFrameGateLeaveDoesNotGoNegative() {
        var gate = FrameGate()
        gate.leave()
        gate.leave()
        XCTAssertEqual(gate.inFlight, 0)
        XCTAssertTrue(gate.tryEnter())
        XCTAssertFalse(gate.tryEnter(), "여분의 leave가 한도를 늘리지 않는다")
    }

    func testFrameGateLimitTwo() {
        var gate = FrameGate(limit: 2)
        XCTAssertTrue(gate.tryEnter())
        XCTAssertTrue(gate.tryEnter())
        XCTAssertFalse(gate.tryEnter())
    }

    func testLockedFrameGateConcurrentEntersAdmitOnlyOne() {
        let gate = LockedFrameGate(limit: 1)
        let admitted = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if gate.tryEnter() { admitted.increment() }
        }
        XCTAssertEqual(admitted.value, 1)
        gate.leave()
        XCTAssertTrue(gate.tryEnter())
    }

    // MARK: PreviewQuality

    func testPreviewQualityByThermalState() {
        XCTAssertEqual(PreviewQuality.maxDimension(for: .nominal), 1024)
        XCTAssertEqual(PreviewQuality.maxDimension(for: .fair), 1024)
        XCTAssertEqual(PreviewQuality.maxDimension(for: .serious), 768)
        XCTAssertEqual(PreviewQuality.maxDimension(for: .critical), 512)
        XCTAssertEqual(PreviewQuality.maxDimension(for: .serious, base: 2000), 1500)
    }

    // MARK: fitRect

    func testFitRectFillPortraitImageInTallDrawable() {
        // 3:4 세로 이미지를 19.5:9 화면(1170×2532)에 채우기: 높이 기준으로 확대, 좌우가 잘림.
        let r = MetalPreviewView.fitRect(image: CGRect(x: 0, y: 0, width: 300, height: 400),
                                         drawable: CGSize(width: 1170, height: 2532), mode: .fill)
        XCTAssertEqual(r.height, 2532, accuracy: accuracy)
        XCTAssertEqual(r.width, 300 * 2532 / 400, accuracy: accuracy)   // 1899
        XCTAssertEqual(r.midX, 585, accuracy: accuracy, "가로 중심 정렬")
        XCTAssertEqual(r.midY, 1266, accuracy: accuracy)
        XCTAssertLessThanOrEqual(r.minX, 0)
        XCTAssertGreaterThanOrEqual(r.maxX, 1170)
    }

    func testFitRectFillLandscapeImageInSquareDrawable() {
        let r = MetalPreviewView.fitRect(image: CGRect(x: 10, y: 20, width: 400, height: 300),
                                         drawable: CGSize(width: 1000, height: 1000), mode: .fill)
        XCTAssertEqual(r.height, 1000, accuracy: accuracy)
        XCTAssertEqual(r.width, 4000.0 / 3.0, accuracy: 1e-3)
        XCTAssertEqual(r.midX, 500, accuracy: 1e-3)
        XCTAssertEqual(r.minY, 0, accuracy: accuracy)
    }

    func testFitRectSameAspectFillsExactly() {
        let r = MetalPreviewView.fitRect(image: CGRect(x: 0, y: 0, width: 768, height: 1024),
                                         drawable: CGSize(width: 1170, height: 1560), mode: .fill)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-3)
        XCTAssertEqual(r.minY, 0, accuracy: 1e-3)
        XCTAssertEqual(r.width, 1170, accuracy: 1e-3)
        XCTAssertEqual(r.height, 1560, accuracy: 1e-3)
    }

    func testFitRectFitKeepsWholeImage() {
        let r = MetalPreviewView.fitRect(image: CGRect(x: 0, y: 0, width: 400, height: 300),
                                         drawable: CGSize(width: 1000, height: 1000), mode: .fit)
        XCTAssertEqual(r.width, 1000, accuracy: accuracy)
        XCTAssertEqual(r.height, 750, accuracy: accuracy)
        XCTAssertEqual(r.minY, 125, accuracy: accuracy)
    }

    // MARK: devicePoint (세로 고정·후면 카메라·회전 90°)

    func testDevicePointCornersWithoutCrop() {
        let size = CGSize(width: 300, height: 400)   // 3:4 뷰 = 3:4 프레임 → 잘림 없음
        func dp(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            MetalPreviewView.devicePoint(fromViewPoint: CGPoint(x: x, y: y), viewSize: size,
                                         imageSize: CGSize(width: 3, height: 4))
        }
        // 주석의 유도: devicePoint = (v, 1 − u)
        let center = dp(150, 200)
        XCTAssertEqual(center.x, 0.5, accuracy: accuracy)
        XCTAssertEqual(center.y, 0.5, accuracy: accuracy)

        let topLeft = dp(0, 0)            // 화면 좌상단 → 센서 (0, 1)
        XCTAssertEqual(topLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, 1, accuracy: accuracy)

        let topRight = dp(300, 0)         // 화면 우상단 → 센서 좌상단 (0, 0)
        XCTAssertEqual(topRight.x, 0, accuracy: accuracy)
        XCTAssertEqual(topRight.y, 0, accuracy: accuracy)

        let bottomLeft = dp(0, 400)       // 화면 좌하단 → 센서 우하단 (1, 1)
        XCTAssertEqual(bottomLeft.x, 1, accuracy: accuracy)
        XCTAssertEqual(bottomLeft.y, 1, accuracy: accuracy)
    }

    func testDevicePointCompensatesAspectFillCrop() {
        // 3:4 프레임을 390×844 뷰에 채우면 좌우가 잘린다: 배율 211, 그린 폭 633, 왼쪽 121.5pt가 화면 밖.
        let view = CGSize(width: 390, height: 844)
        let p = MetalPreviewView.devicePoint(fromViewPoint: CGPoint(x: 0, y: 422), viewSize: view,
                                             imageSize: CGSize(width: 3, height: 4))
        let u = 121.5 / 633.0
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.y, 1 - u, accuracy: 1e-6, "화면 왼쪽 끝은 프레임 가장자리(u=0)가 아니라 잘린 만큼 안쪽")

        let center = MetalPreviewView.devicePoint(fromViewPoint: CGPoint(x: 195, y: 422), viewSize: view,
                                                  imageSize: CGSize(width: 3, height: 4))
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-6)
    }

    func testDevicePointClampsOutsideView() {
        let p = MetalPreviewView.devicePoint(fromViewPoint: CGPoint(x: -50, y: 900),
                                             viewSize: CGSize(width: 300, height: 400))
        XCTAssertEqual(p.x, 1, accuracy: accuracy)
        XCTAssertEqual(p.y, 1, accuracy: accuracy)
    }

    // MARK: LivePipeline

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess && buffer != nil)
        return buffer!
    }

    func testLivePipelineDownsamplesToMaxDimension() {
        let pipeline = LivePipeline(settings: LiveSettings(params: .identity, context: PipelineContext(), maxDimension: 200))
        let out = pipeline.process(makeBuffer(width: 300, height: 400))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.extent.width, 150)
        XCTAssertEqual(out?.extent.height, 200)
    }

    func testLivePipelineFallbackOrientationMakesPortrait() {
        // 연결 회전을 지원하지 않는 폴백: 가로 센서 프레임(400×300)을 .right로 세운다.
        let pipeline = LivePipeline(settings: LiveSettings(params: .identity, context: PipelineContext(), maxDimension: 1024))
        let out = pipeline.process(makeBuffer(width: 400, height: 300), orientation: .right)
        XCTAssertEqual(out?.extent.width, 300)
        XCTAssertEqual(out?.extent.height, 400)
    }

    func testLivePipelineDisabledReturnsNil() {
        let pipeline = LivePipeline()
        pipeline.isEnabled = false
        XCTAssertNil(pipeline.process(makeBuffer(width: 64, height: 64)))
        pipeline.isEnabled = true
        XCTAssertNotNil(pipeline.process(makeBuffer(width: 64, height: 64)))
    }

    func testLivePipelineUsesUpdatedSettingsAndRunsAllStages() {
        let pipeline = LivePipeline()
        var stages: [EnhanceStage] = []
        var context = PipelineContext()
        context.onStage = { stage, _ in stages.append(stage) }
        pipeline.update(LiveSettings(params: PresetParams(), context: context, maxDimension: 100))
        XCTAssertEqual(pipeline.currentSettings.maxDimension, 100)

        let out = pipeline.process(makeBuffer(width: 64, height: 48))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.extent.width, 64, "maxDimension보다 작으면 줄이지 않는다")
        XCTAssertEqual(stages, EnhanceStage.allCases, "프리뷰도 저장과 같은 7단계 파이프라인을 거친다")
    }
}

/// 동시성 테스트용 카운터.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
