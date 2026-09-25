// R1-S6 인물 모드 ② 윤곽 테스트: 강도 0 항등성, 턱선 점 선택, 좌우 대칭, 순방향 근사, 다인 겹침, ROI, 워프 커널 적용.
import CoreGraphics
import CoreImage
import XCTest
@testable import TripShot

final class FaceWarpTests: XCTestCase {

    // MARK: 공용 도구

    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 두 회색(0.3/0.6) 체스판.
    private func checkerboard(size: CGFloat, cell: CGFloat) -> CIImage {
        let f = CIFilter(name: "CICheckerboardGenerator")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        f.setValue(CIColor(red: 0.3, green: 0.3, blue: 0.3), forKey: "inputColor0")
        f.setValue(CIColor(red: 0.6, green: 0.6, blue: 0.6), forKey: "inputColor1")
        f.setValue(cell, forKey: "inputWidth")
        f.setValue(1.0, forKey: "inputSharpness")
        return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// RGBA8 바이트(행 0 = 이미지 위쪽).
    private func pixels(_ image: CIImage, bounds: CGRect) -> [UInt8] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: bounds, format: .RGBA8, colorSpace: Self.sRGB)
        }
        return bytes
    }

    /// 반원 턱선(13점, 왼쪽 귀 → 턱 끝 → 오른쪽 귀) + 눈·입이 있는 인위적 얼굴. 중심 (cx, cy), 반지름 R.
    /// `roll`(라디안)만큼 얼굴 중심 기준으로 회전한다.
    private func syntheticFace(cx: CGFloat = 32, cy: CGFloat = 34, R: CGFloat = 18, roll: CGFloat = 0) -> DetectedFace {
        let pivot = CGPoint(x: cx, y: cy)
        func rot(_ p: CGPoint) -> CGPoint {
            guard roll != 0 else { return p }
            let dx = p.x - pivot.x, dy = p.y - pivot.y
            return CGPoint(x: pivot.x + dx * cos(roll) - dy * sin(roll), y: pivot.y + dx * sin(roll) + dy * cos(roll))
        }
        let contour = (0...12).map { i -> CGPoint in
            let t = CGFloat.pi + CGFloat(i) * CGFloat.pi / 12
            return rot(CGPoint(x: cx + R * cos(t), y: cy + R * sin(t)))
        }
        func eye(_ ex: CGFloat) -> [CGPoint] {
            [CGPoint(x: ex - 3, y: cy + 8), CGPoint(x: ex, y: cy + 9), CGPoint(x: ex + 3, y: cy + 8), CGPoint(x: ex, y: cy + 7)].map(rot)
        }
        let lips = [CGPoint(x: cx - 4, y: cy - 10), CGPoint(x: cx, y: cy - 9), CGPoint(x: cx + 4, y: cy - 10), CGPoint(x: cx, y: cy - 11)].map(rot)
        let landmarks = FaceLandmarks(faceContour: contour, leftEye: eye(cx - 8), rightEye: eye(cx + 8), outerLips: lips)
        let box = CGRect(x: cx - R - 2, y: cy - R - 2, width: 2 * R + 4, height: 2 * R + 4)
        return DetectedFace(boundingBox: box, landmarks: landmarks)
    }

    private func params(slim: Double, eye: Double) -> PortraitParams {
        var p = PortraitParams()
        p.skinSmooth = 0
        p.teethWhiten = 0
        p.faceSlim = slim
        p.eyeEnlarge = eye
        return p
    }

    private func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }

    // MARK: 강도 0 항등성 (완료 기준)

    func testZeroStrengthReturnsSameObjectAndPixels() {
        let input = checkerboard(size: 64, cell: 4)
        let out = FaceWarp.apply(input, faces: [syntheticFace()], params: params(slim: 0, eye: 0),
                                 quality: .full, kernels: PortraitKernels.load())
        XCTAssertTrue(out === input, "강도 0이면 같은 객체")
        XCTAssertEqual(pixels(out, bounds: input.extent), pixels(input, bounds: input.extent))
        XCTAssertNil(WarpPlan.make(face: syntheticFace(), params: params(slim: 0, eye: 0), quality: .full))
    }

    func testNilKernelsReturnsInput() {
        let input = checkerboard(size: 64, cell: 4)
        let result = FaceWarp.process(input, faces: [syntheticFace()], params: params(slim: 100, eye: 100),
                                      quality: .full, kernels: nil)
        XCTAssertTrue(result.image === input)
        XCTAssertEqual(result.faces, [syntheticFace()])
    }

    func testNoFacesReturnsInput() {
        let input = checkerboard(size: 64, cell: 4)
        let out = FaceWarp.apply(input, faces: [], params: params(slim: 100, eye: 100), quality: .full, kernels: PortraitKernels.load())
        XCTAssertTrue(out === input)
    }

    func testIsActiveIncludesWarp() {
        XCTAssertFalse(PortraitStage.isActive(params(slim: 0, eye: 0)))
        XCTAssertTrue(PortraitStage.isActive(params(slim: 20, eye: 0)))
        XCTAssertTrue(PortraitStage.isActive(params(slim: 0, eye: 20)))
    }

    // MARK: 계획

    func testMakePlanSymmetricPushes() throws {
        let plan = try XCTUnwrap(WarpPlan.make(face: syntheticFace(), params: params(slim: 50, eye: 0), quality: .full))
        XCTAssertEqual(plan.pushes.count, 6)
        XCTAssertTrue(plan.bulges.isEmpty, "눈 확대 0이면 bulge 없음")
        let left = Array(plan.pushes[0..<3]), right = Array(plan.pushes[3..<6])
        for (l, r) in zip(left, right) {
            XCTAssertEqual(l.strength, r.strength, accuracy: 1e-9, "좌우 k 동일")
            XCTAssertLessThan(dot(l.direction, r.direction), 0, "좌우 방향이 반대")
            XCTAssertGreaterThan(l.direction.dx, 0, "왼쪽은 오른쪽(축)으로 민다")
            XCTAssertLessThan(l.center.x, 32)
            XCTAssertGreaterThan(r.center.x, 32)
        }
        // k = 얼굴 너비 × 0.035 × 0.5
        XCTAssertEqual(left[0].strength, syntheticFace().boundingBox.width * WarpPlan.pushStrengthFraction * 0.5, accuracy: 1e-9)
    }

    func testMakePlanLiveUsesFourPushes() throws {
        let plan = try XCTUnwrap(WarpPlan.make(face: syntheticFace(), params: params(slim: 50, eye: 0), quality: .live))
        XCTAssertEqual(plan.pushes.count, 4)
    }

    func testMakePlanEyeBulges() throws {
        let plan = try XCTUnwrap(WarpPlan.make(face: syntheticFace(), params: params(slim: 0, eye: 100), quality: .full))
        XCTAssertTrue(plan.pushes.isEmpty)
        XCTAssertEqual(plan.bulges.count, 2)
        // 눈 너비 6 × 1.4
        XCTAssertEqual(plan.bulges[0].radius, 6 * WarpPlan.eyeRadiusFactor, accuracy: 1e-6)
        XCTAssertEqual(plan.bulges[0].scale, WarpPlan.eyeMaxScale, accuracy: 1e-9)
    }

    func testRolledFaceStaysSymmetric() throws {
        let roll: CGFloat = .pi / 6
        let face = syntheticFace(roll: roll)
        let plan = try XCTUnwrap(WarpPlan.make(face: face, params: params(slim: 100, eye: 0), quality: .full))
        XCTAssertEqual(plan.pushes.count, 6)
        let axis = FaceAxis.make(for: face)
        // 축 방향이 회전을 따라간다: down = 회전된 (0, −1).
        XCTAssertEqual(axis.down.dx, sin(roll), accuracy: 1e-6)
        XCTAssertEqual(axis.down.dy, -cos(roll), accuracy: 1e-6)
        for i in 0..<3 {
            let l = plan.pushes[i], r = plan.pushes[i + 3]
            XCTAssertEqual(axis.side(l.center), -axis.side(r.center), accuracy: 1e-6, "축 기준 거울 대칭")
            XCTAssertEqual(axis.depth(l.center), axis.depth(r.center), accuracy: 1e-6)
        }
    }

    // MARK: 턱선 점

    func testJawPointsSplitLeftRight() {
        let face = syntheticFace()
        let axis = FaceAxis.make(for: face)
        let jaw = WarpPlan.jawPoints(contour: face.landmarks.faceContour, axis: axis)
        XCTAssertEqual(jaw.left.count, 3)
        XCTAssertEqual(jaw.right.count, 3)
        XCTAssertTrue(jaw.left.allSatisfy { $0.x < 32 })
        XCTAssertTrue(jaw.right.allSatisfy { $0.x > 32 })
        // 광대 → 턱 끝 순서: 아래로 갈수록 y가 작다.
        XCTAssertGreaterThan(jaw.left[0].y, jaw.left[2].y)
        XCTAssertGreaterThan(jaw.right[0].y, jaw.right[2].y)

        // 턱선 순서가 반대(오른쪽 귀 → 왼쪽 귀)여도 같은 결과.
        let reversed = WarpPlan.jawPoints(contour: face.landmarks.faceContour.reversed(), axis: axis)
        XCTAssertEqual(reversed.left, jaw.left)
        XCTAssertEqual(reversed.right, jaw.right)
    }

    func testJawPointsTooFewPoints() {
        let axis = FaceAxis(origin: .zero, down: CGVector(dx: 0, dy: -1))
        let jaw = WarpPlan.jawPoints(contour: [CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0)], axis: axis)
        XCTAssertTrue(jaw.left.isEmpty && jaw.right.isEmpty)
    }

    // MARK: 순방향 근사

    func testForwardMap() {
        let push = WarpPlan.Push(center: CGPoint(x: 50, y: 50), radius: 10, strength: 2, direction: CGVector(dx: 1, dy: 0))
        let plan = WarpPlan(pushes: [push], bulges: [], center: CGPoint(x: 50, y: 50), radius: 10)
        XCTAssertEqual(plan.forwardMap(CGPoint(x: 70, y: 50)), CGPoint(x: 70, y: 50), "반경 밖은 불변")
        XCTAssertEqual(plan.forwardMap(CGPoint(x: 50, y: 61)), CGPoint(x: 50, y: 61))
        let moved = plan.forwardMap(CGPoint(x: 50, y: 50))
        XCTAssertEqual(moved.x, 52, accuracy: 1e-9, "중심은 d 방향으로 k만큼")
        XCTAssertEqual(moved.y, 50, accuracy: 1e-9)
    }

    func testForwardMapBulgeMovesOutward() {
        let bulge = WarpPlan.Bulge(center: CGPoint(x: 0, y: 0), radius: 10, scale: 0.2)
        let plan = WarpPlan(pushes: [], bulges: [bulge], center: .zero, radius: 10)
        let p = plan.forwardMap(CGPoint(x: 3, y: 0))
        XCTAssertGreaterThan(p.x, 3, "확대: 중심에서 멀어진다")
        XCTAssertEqual(plan.forwardMap(.zero), .zero)
    }

    // MARK: 다인 겹침

    func testAttenuateOverlaps() {
        func plan(at x: CGFloat) -> WarpPlan {
            let push = WarpPlan.Push(center: CGPoint(x: x, y: 0), radius: 10, strength: 2, direction: CGVector(dx: 1, dy: 0))
            let bulge = WarpPlan.Bulge(center: CGPoint(x: x, y: 5), radius: 4, scale: 0.2)
            return WarpPlan(pushes: [push], bulges: [bulge], center: CGPoint(x: x, y: 0), radius: 20)
        }
        let apart = WarpPlan.attenuateOverlaps([plan(at: 0), plan(at: 100)])
        XCTAssertEqual(apart[0].pushes[0].strength, 2)
        XCTAssertEqual(apart[1].pushes[0].strength, 2, "겹치지 않으면 유지")

        let same = WarpPlan.attenuateOverlaps([plan(at: 0), plan(at: 0)])
        XCTAssertEqual(same[0].pushes[0].strength, 2, "첫 얼굴은 그대로")
        XCTAssertLessThan(same[1].pushes[0].strength, 0.2, "완전히 겹치면 크게 감소")
        XCTAssertLessThan(same[1].bulges[0].scale, 0.02)

        let half = WarpPlan.attenuateOverlaps([plan(at: 0), plan(at: 20)])
        XCTAssertEqual(half[1].pushes[0].strength, 1, accuracy: 1e-9, "거리 20 / 합 반경 40 → 절반")
    }

    // MARK: ROI

    func testROIExpandsByMaxDisplacement() throws {
        let plan = try XCTUnwrap(WarpPlan.make(face: syntheticFace(), params: params(slim: 100, eye: 100), quality: .full))
        let m = plan.maxDisplacement
        XCTAssertGreaterThan(m, 0)
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let roi = WarpPlan.roi(for: rect, maxDisplacement: m)
        XCTAssertTrue(roi.contains(rect.insetBy(dx: -m, dy: -m)))
        XCTAssertLessThanOrEqual(roi.width, rect.width + 2 * m + 2 + 1e-9)
    }

    func testMaxDisplacementBoundsActualDisplacement() throws {
        let plan = try XCTUnwrap(WarpPlan.make(face: syntheticFace(), params: params(slim: 100, eye: 100), quality: .full))
        let m = plan.maxDisplacement
        for x in stride(from: 0, through: 64, by: 2) {
            for y in stride(from: 0, through: 64, by: 2) {
                let d = plan.backwardDisplacement(at: CGPoint(x: x, y: y))
                XCTAssertLessThanOrEqual((d.dx * d.dx + d.dy * d.dy).squareRoot(), m + 1e-9)
            }
        }
    }

    // MARK: 워프 커널 실제 적용

    func testWarpKernelChangesOnlyInsideRadius() throws {
        guard let kernels = PortraitKernels.load(), kernels.faceWarp != nil else {
            throw XCTSkip("faceWarp 커널 로드 실패(default.metallib)")
        }
        let input = checkerboard(size: 64, cell: 4)
        let face = syntheticFace()
        let p = params(slim: 100, eye: 0)
        let result = FaceWarp.process(input, faces: [face], params: p, quality: .full, kernels: kernels)
        XCTAssertFalse(result.image === input)
        XCTAssertEqual(result.image.extent, input.extent)

        let before = pixels(input, bounds: input.extent)
        let after = pixels(result.image, bounds: input.extent)
        XCTAssertNotEqual(before, after, "영향 반경 안 어딘가는 달라진다")

        // 영향 영역 밖 픽셀은 동일.
        let plan = try XCTUnwrap(WarpPlan.make(face: face, params: p, quality: .full))
        let influence = plan.influenceRect.insetBy(dx: -1, dy: -1)
        var checked = 0
        for y in 0..<64 {
            for x in 0..<64 where !influence.intersects(CGRect(x: x, y: y, width: 1, height: 1)) {
                let i = ((63 - y) * 64 + x) * 4   // 행 0 = 위쪽
                XCTAssertEqual(before[i], after[i], "(\(x), \(y))")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)

        // 랜드마크는 워프 후 좌표로 옮겨진다(왼쪽 턱선 점은 오른쪽으로).
        let leftJaw = face.landmarks.faceContour[3]
        XCTAssertGreaterThan(result.faces[0].landmarks.faceContour[3].x, leftJaw.x)
    }
}
