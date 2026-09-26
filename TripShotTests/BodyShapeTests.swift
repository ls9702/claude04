// 전신 보정(몸 슬림·다리 길게)·전체화면 16:9 포맷 선택 테스트: 몸 배치, 워프 계획 제한, 좌표 사상, 워프 커널, 칩·직렬화 호환.
import CoreGraphics
import CoreImage
import XCTest
@testable import TripShot

final class BodyShapeTests: XCTestCase {

    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 1000×2000 세로 사진에 서 있는 사람(머리 꼭대기 약 1600, 엉덩이 1000, 발목 200).
    private var standingJoints: [BodyJoint: CGPoint] {
        [
            .nose: CGPoint(x: 500, y: 1500),
            .leftShoulder: CGPoint(x: 420, y: 1350), .rightShoulder: CGPoint(x: 580, y: 1350),
            .leftHip: CGPoint(x: 450, y: 1000), .rightHip: CGPoint(x: 550, y: 1000),
            .leftKnee: CGPoint(x: 455, y: 600), .rightKnee: CGPoint(x: 545, y: 600),
            .leftAnkle: CGPoint(x: 460, y: 200), .rightAnkle: CGPoint(x: 540, y: 210),
        ]
    }
    private let tallExtent = CGRect(x: 0, y: 0, width: 1000, height: 2000)

    // MARK: BodyLayout

    func testLayoutFromStandingPose() throws {
        let l = try XCTUnwrap(BodyLayout.make(joints: standingJoints))
        XCTAssertEqual(l.centerX, 500, accuracy: 0.01)
        XCTAssertEqual(l.shoulderY, 1350, accuracy: 0.01)
        XCTAssertEqual(l.hipY, 1000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(l.ankleY), 200, accuracy: 0.01, "두 발목 중 낮은 쪽")
        XCTAssertEqual(l.halfWidth, 80, accuracy: 0.01, "어깨 폭 160의 절반")
        XCTAssertEqual(l.headTopY, 1500 + 150 * 0.8, accuracy: 0.01)
    }

    func testLayoutRequiresShoulderAndHip() {
        var j = standingJoints
        j[.leftHip] = nil; j[.rightHip] = nil
        XCTAssertNil(BodyLayout.make(joints: j))
    }

    func testLayoutRejectsLyingPose() {
        // 어깨가 엉덩이 옆(수평)에 있으면 세로 워프가 맞지 않아 건너뛴다.
        let j: [BodyJoint: CGPoint] = [
            .leftShoulder: CGPoint(x: 800, y: 500), .leftHip: CGPoint(x: 400, y: 480),
        ]
        XCTAssertNil(BodyLayout.make(joints: j))
    }

    func testLayoutEstimatesAnkleFromKnee() throws {
        var j = standingJoints
        j[.leftAnkle] = nil; j[.rightAnkle] = nil
        let l = try XCTUnwrap(BodyLayout.make(joints: j))
        XCTAssertEqual(try XCTUnwrap(l.ankleY), 200, accuracy: 0.01, "무릎 600 − (엉덩이 1000 − 무릎 600)")
    }

    func testLayoutUpperBodyOnlyHasNoAnkle() throws {
        var j = standingJoints
        for k in [BodyJoint.leftKnee, .rightKnee, .leftAnkle, .rightAnkle] { j[k] = nil }
        XCTAssertNil(try XCTUnwrap(BodyLayout.make(joints: j)).ankleY)
    }

    // MARK: BodyWarpPlan

    func testZeroStrengthIsNil() throws {
        let l = try XCTUnwrap(BodyLayout.make(joints: standingJoints))
        XCTAssertNil(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 0, legLengthen: 0))
    }

    func testFullStrengthValues() throws {
        let l = try XCTUnwrap(BodyLayout.make(joints: standingJoints))
        let plan = try XCTUnwrap(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 100, legLengthen: 100))
        XCTAssertEqual(plan.slimAmount, BodyWarpPlan.maxSlimAmount, accuracy: 1e-6)
        XCTAssertEqual(plan.stretch, BodyWarpPlan.maxStretch, accuracy: 1e-6, "머리 위 여유(약 380px)가 충분")
        XCTAssertEqual(plan.slimRadius, 240, accuracy: 0.01)
    }

    func testNoLegStretchWithoutAnkles() throws {
        var j = standingJoints
        for k in [BodyJoint.leftKnee, .rightKnee, .leftAnkle, .rightAnkle] { j[k] = nil }
        let l = try XCTUnwrap(BodyLayout.make(joints: j))
        let plan = try XCTUnwrap(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 50, legLengthen: 100))
        XCTAssertEqual(plan.stretch, 0, "상반신 사진은 다리 길게 없음")
        XCTAssertNil(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 0, legLengthen: 100))
    }

    func testStretchCappedToKeepHeadInFrame() throws {
        // 머리 꼭대기가 위 가장자리 바로 아래(여유 40px − 1% 20px = 20px) → s ≤ 20/1000 = 0.02.
        var l = try XCTUnwrap(BodyLayout.make(joints: standingJoints))
        l.headTopY = 1960
        let plan = try XCTUnwrap(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 0, legLengthen: 100))
        XCTAssertEqual(plan.stretch, 0.02, accuracy: 1e-6)
        // 늘린 뒤 머리 꼭대기의 출력 위치가 이미지 안에 있다.
        XCTAssertLessThanOrEqual(l.headTopY + plan.maxVerticalShift, tallExtent.maxY)
    }

    func testSourceMappingIsIdentityOutsideAndMonotonic() throws {
        let l = try XCTUnwrap(BodyLayout.make(joints: standingJoints))
        let plan = try XCTUnwrap(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 100, legLengthen: 100))
        // 반경 밖 x는 그대로.
        XCTAssertEqual(plan.sourcePoint(for: CGPoint(x: 900, y: 500)).x, 900, accuracy: 1e-6)
        // 몸 중심선은 움직이지 않는다.
        XCTAssertEqual(plan.sourcePoint(for: CGPoint(x: 500, y: 500)).x, 500, accuracy: 1e-6)
        // 중심 근처 입력은 중심에서 더 먼 곳 → 몸이 좁아진다.
        XCTAssertGreaterThan(plan.sourcePoint(for: CGPoint(x: 560, y: 500)).x, 560)
        // 바닥은 고정, 위로 갈수록 입력 높이가 증가(접힘 없음), 엉덩이 위는 평행 이동.
        XCTAssertEqual(plan.sourceHeight(forOutputHeight: 0), 0, accuracy: 1e-6)
        var prevY: CGFloat = -1, prevX: CGFloat = -1
        for i in 0...200 {
            let y = CGFloat(i) * 10
            let sy = plan.sourceHeight(forOutputHeight: y)
            XCTAssertGreaterThan(sy, prevY); prevY = sy
            let sx = plan.sourcePoint(for: CGPoint(x: CGFloat(i) * 5, y: 500)).x
            XCTAssertGreaterThan(sx, prevX); prevX = sx
        }
        let shift = plan.maxVerticalShift
        XCTAssertEqual(1900 - plan.sourceHeight(forOutputHeight: 1900), shift, accuracy: 1e-3)
        XCTAssertEqual(shift, 100, accuracy: 3, "엉덩이 높이 1000 × s 0.1 근처")
    }

    func testSlimFadesAboveShoulders() throws {
        let l = try XCTUnwrap(BodyLayout.make(joints: standingJoints))
        let plan = try XCTUnwrap(BodyWarpPlan.make(layout: l, extent: tallExtent, bodySlim: 100, legLengthen: 0))
        XCTAssertEqual(plan.slimWeight(atSourceY: 1000), 1, accuracy: 1e-6)
        XCTAssertEqual(plan.slimWeight(atSourceY: 1700), 0, accuracy: 1e-6, "머리 꼭대기 위는 슬림 없음")
        XCTAssertEqual(plan.sourcePoint(for: CGPoint(x: 560, y: 1800)).x, 560, accuracy: 1e-6)
    }

    // MARK: 워프 커널

    /// 검정 바탕에 흰 세로 막대(x 110~130)와 가로 막대(y 150~165).
    private func barsImage() -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let white = CIImage(color: .white)
        return white.cropped(to: CGRect(x: 110, y: 0, width: 20, height: 200))
            .composited(over: white.cropped(to: CGRect(x: 0, y: 150, width: 200, height: 15)))
            .composited(over: black)
    }

    func testWarpKernelMatchesSourceMapping() throws {
        let kernels = try XCTUnwrap(PortraitKernels.load(), "default.metallib 로드 실패")
        let kernel = try XCTUnwrap(kernels.bodyReshape, "bodyReshape 커널 로드 실패")
        let plan = BodyWarpPlan(centerX: 100, slimRadius: 60, slimAmount: 0.12, slimFullY: 120, slimZeroY: 190,
                                baseY: 0, rampStart: 60, rampWidth: 20, stretch: 0.1)
        let input = barsImage()
        let output = BodyShape.warp(input, plan: plan, kernel: kernel)
        XCTAssertEqual(output.extent, input.extent, "출력 크기는 그대로")

        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        var bytes = [UInt8](repeating: 0, count: 200 * 200 * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(output, toBitmap: ptr.baseAddress!, rowBytes: 200 * 4, bounds: bounds,
                            format: .RGBA8, colorSpace: Self.sRGB)
        }
        func isWhite(_ p: CGPoint) -> Bool? {
            // 막대 경계에서 2px 이상 떨어진 입력 위치만 판정한다(보간 영향 제외).
            let inV = p.x > 112 && p.x < 128, outV = p.x < 108 || p.x > 132
            let inH = p.y > 152 && p.y < 163, outH = p.y < 148 || p.y > 167
            if inV || inH { return true }
            if outV && outH { return false }
            return nil
        }
        var checked = 0
        for y in stride(from: 5, to: 195, by: 7) {
            for x in stride(from: 5, to: 195, by: 3) {
                let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                guard let expected = isWhite(plan.sourcePoint(for: center)) else { continue }
                let row = 199 - y
                let value = bytes[(row * 200 + x) * 4]
                XCTAssertEqual(value > 128, expected, "(\(x), \(y)) 값 \(value)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    // MARK: 칩·직렬화

    func testStrengthChipsIncludeBodyValues() {
        XCTAssertEqual(PortraitStrength.normal.params.bodySlim, 30)
        XCTAssertEqual(PortraitStrength.normal.params.legLengthen, 40)
        var p = PortraitStrength.normal.params
        XCTAssertEqual(PortraitStrength.matching(p), .normal)
        p.legLengthen = 41
        XCTAssertNil(PortraitStrength.matching(p), "다리 값만 달라도 직접")
    }

    func testOldJSONWithoutBodyKeysDecodesToZero() throws {
        let json = #"{"enabled":true,"skinSmooth":40,"faceSlim":20,"eyeEnlarge":0,"teethWhiten":0}"#
        let p = try JSONDecoder().decode(PortraitParams.self, from: Data(json.utf8))
        XCTAssertEqual(p.bodySlim, 0)
        XCTAssertEqual(p.legLengthen, 0)
        XCTAssertFalse(BodyShape.isActive(p))
    }

    func testStageActiveWithBodyOnly() {
        var p = PortraitParams()
        p.skinSmooth = 0; p.faceSlim = 0; p.eyeEnlarge = 0; p.teethWhiten = 0; p.skinBrighten = 0; p.backgroundBlur = 0
        XCTAssertFalse(PortraitStage.isActive(p))
        p.legLengthen = 10
        XCTAssertTrue(PortraitStage.isActive(p))
        XCTAssertFalse(PortraitStage.isFaceActive(p), "전신 값만으로 얼굴 검출은 하지 않는다")
    }

    // MARK: 전체화면 16:9 포맷

    func testPicksSixteenByNineFormatWithFullWidthPhoto() {
        let photo169 = PixelSize(width: 4032, height: 2268)
        let formats = [
            FormatInfo(width: 1280, height: 720, maxFrameRate: 60, maxPhotoDimensions: [PixelSize(width: 1280, height: 720)]),
            FormatInfo(width: 1920, height: 1080, maxFrameRate: 60, maxPhotoDimensions: [PixelSize(width: 1920, height: 1080), photo169]),
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [PixelSize(width: 4032, height: 3024)]),
            FormatInfo(width: 3840, height: 2160, maxFrameRate: 30, maxPhotoDimensions: [photo169]),   // 너무 큼
        ]
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats, requireFullPhoto: true, aspect: .sixteenByNine), 1)
        XCTAssertEqual(CameraFormatPicker.pick(formats: formats, requireFullPhoto: true), 2, "기본은 여전히 4:3")
        XCTAssertEqual(CameraFormatPicker.largestPhotoDimensions(formats[1].maxPhotoDimensions, aspect: .sixteenByNine), photo169)
    }

    func testSixteenByNineRejectsSmallPhotoFormats() {
        let formats = [
            FormatInfo(width: 1920, height: 1080, maxFrameRate: 30, maxPhotoDimensions: [PixelSize(width: 1920, height: 1080)]),
            FormatInfo(width: 1920, height: 1440, maxFrameRate: 30, maxPhotoDimensions: [PixelSize(width: 4032, height: 3024)]),
        ]
        XCTAssertNil(CameraFormatPicker.pick(formats: formats, requireFullPhoto: true, aspect: .sixteenByNine),
                     "16:9 사진이 작으면 4:3 폴백")
    }

    func testAspectMatchesWithTolerance() {
        XCTAssertTrue(AspectRatio.sixteenByNine.matches(PixelSize(width: 4032, height: 2268)))
        XCTAssertTrue(AspectRatio.sixteenByNine.matches(PixelSize(width: 1080, height: 1920)))
        XCTAssertFalse(AspectRatio.sixteenByNine.matches(PixelSize(width: 4032, height: 3024)))
        XCTAssertEqual(AspectRatio.sixteenByNine.portraitWidthOverHeight, 9.0 / 16.0, accuracy: 1e-9)
    }
}
