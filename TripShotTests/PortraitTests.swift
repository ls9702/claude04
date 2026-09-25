// R1-S5 인물 모드 ① 피부 테스트: 랜드마크 좌표 변환, 시간축 평활, 피부 마스크, 피부 보정 항등성, 마스크 바깥 선명도.
import CoreGraphics
import CoreImage
import XCTest
@testable import TripShot

final class PortraitTests: XCTestCase {

    // MARK: 공용 도구

    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// 두 회색(0.3/0.6)이 `cell` 픽셀 간격으로 번갈아 나오는 체스판. 순흑·순백이면 언샤프 결과가 잘려 입력과 같아지므로 중간 회색을 쓴다.
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
    private func pixels(_ image: CIImage, colorSpace: CGColorSpace = PortraitTests.sRGB) -> [UInt8] {
        let rect = image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: colorSpace)
        }
        return bytes
    }

    /// CIImage 좌표(원점 좌하단)의 (x, y) 픽셀 R 값(0~1, 선형).
    private func maskValue(_ bytes: [UInt8], width: Int, height: Int, x: Int, y: Int) -> Double {
        let row = height - 1 - y
        return Double(bytes[(row * width + x) * 4]) / 255
    }

    /// contour가 사각형인 얼굴.
    private func squareFace(_ rect: CGRect) -> DetectedFace {
        let contour = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        return DetectedFace(boundingBox: rect, landmarks: FaceLandmarks(faceContour: contour))
    }

    private func face(x: CGFloat, y: CGFloat, size: CGFloat = 50) -> DetectedFace {
        DetectedFace(boundingBox: CGRect(x: x, y: y, width: size, height: size), landmarks: FaceLandmarks())
    }

    // MARK: 랜드마크 좌표 변환

    func testImagePointsFromNormalized() {
        let bb = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let size = CGSize(width: 400, height: 400)
        let pts = FaceLandmarks.imagePoints(normalized: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 0)],
                                            boundingBox: bb, imageSize: size)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].x, 200, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, 200, accuracy: 1e-9)
        XCTAssertEqual(pts[1].x, 100, accuracy: 1e-9)
        XCTAssertEqual(pts[1].y, 100, accuracy: 1e-9)
    }

    func testImagePointsNilRegionIsEmpty() {
        XCTAssertTrue(FaceLandmarks.imagePoints(nil, boundingBox: .zero, imageSize: CGSize(width: 10, height: 10)).isEmpty)
    }

    func testSelectDropsSmallFacesAndSortsByArea() {
        let extent = CGRect(x: 0, y: 0, width: 1000, height: 800)   // 짧은 변 800 → 최소 너비 96
        let faces = [face(x: 0, y: 0, size: 100), face(x: 300, y: 0, size: 50), face(x: 600, y: 0, size: 200)]
        let selected = FaceDetector.select(faces, imageExtent: extent, maxFaces: 5)
        XCTAssertEqual(selected.map(\.boundingBox.width), [200, 100])
        XCTAssertEqual(FaceDetector.select(faces, imageExtent: extent, maxFaces: 1).count, 1)
    }

    // MARK: 시간축 평활

    func testSmootherAppliesEMA() {
        var smoother = FaceSmoother()
        smoother.update([face(x: 100, y: 100)])
        let out = smoother.update([face(x: 110, y: 100)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].boundingBox.minX, 105, accuracy: 1e-9)   // α = 0.5
        XCTAssertEqual(out[0].boundingBox.minY, 100, accuracy: 1e-9)
    }

    func testSmootherRemovesAfterThreeMisses() {
        var smoother = FaceSmoother()
        smoother.update([face(x: 100, y: 100)])
        XCTAssertEqual(smoother.update([]).count, 1)   // 1회 놓침: 마지막 값 유지
        XCTAssertEqual(smoother.update([]).count, 1)   // 2회
        XCTAssertEqual(smoother.update([]).count, 0)   // 3회 연속 → 제거
    }

    func testSmootherKeepsIdentityOfTwoFaces() {
        var smoother = FaceSmoother()
        smoother.update([face(x: 100, y: 100), face(x: 300, y: 100)])
        // 입력 순서를 뒤집어 줘도 가까운 쪽끼리 짝지어져야 한다.
        let out = smoother.update([face(x: 290, y: 100), face(x: 110, y: 100)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].boundingBox.minX, 105, accuracy: 1e-9)
        XCTAssertEqual(out[1].boundingBox.minX, 295, accuracy: 1e-9)
    }

    func testSmootherAddsNewFaceFarAway() {
        var smoother = FaceSmoother()
        smoother.update([face(x: 100, y: 100)])
        let out = smoother.update([face(x: 100, y: 100), face(x: 500, y: 500)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].boundingBox.minX, 500, accuracy: 1e-9)
    }

    // MARK: 피부 보정 항등성

    func testSkinSmoothingWithoutFacesIsIdentity() {
        let input = checkerboard(size: 32, cell: 2)
        var params = PortraitParams()
        params.skinSmooth = 80
        params.teethWhiten = 50
        let result = SkinSmoothing.process(input, faces: [], params: params, quality: .full, kernels: nil)
        XCTAssertEqual(pixels(result.image), pixels(input))
        XCTAssertNil(result.skinMask)
    }

    func testSkinSmoothingZeroStrengthIsIdentity() {
        let input = checkerboard(size: 32, cell: 2)
        var params = PortraitParams()
        params.skinSmooth = 0
        params.teethWhiten = 0
        let faces = [squareFace(CGRect(x: 8, y: 8, width: 16, height: 16))]
        for quality in [PortraitQuality.full, .live] {
            let result = SkinSmoothing.process(input, faces: faces, params: params, quality: quality, kernels: nil)
            XCTAssertEqual(pixels(result.image), pixels(input))
            XCTAssertNil(result.skinMask)
        }
    }

    /// 커널 없는 폴백(경량 블러): 얼굴 안은 부드러워지고, 얼굴에서 먼 곳은 그대로.
    func testSkinSmoothingChangesOnlyInsideFace() {
        let input = checkerboard(size: 128, cell: 1)
        var params = PortraitParams()
        params.skinSmooth = 100
        params.teethWhiten = 0
        let faceRect = CGRect(x: 32, y: 32, width: 64, height: 64)
        let result = SkinSmoothing.process(input, faces: [squareFace(faceRect)], params: params, quality: .live, kernels: nil)
        XCTAssertNotNil(result.skinMask)
        XCTAssertEqual(result.image.extent, input.extent)

        let before = pixels(input), after = pixels(result.image)
        func px(_ bytes: [UInt8], _ x: Int, _ y: Int) -> UInt8 { bytes[((127 - y) * 128 + x) * 4] }
        // 가운데(얼굴 안): 체스판 대비가 줄어든다.
        let beforeDiff = abs(Int(px(before, 64, 64)) - Int(px(before, 65, 64)))
        let afterDiff = abs(Int(px(after, 64, 64)) - Int(px(after, 65, 64)))
        XCTAssertLessThan(afterDiff, beforeDiff)
        // 모서리(얼굴 영역 밖): 그대로.
        XCTAssertEqual(px(after, 2, 2), px(before, 2, 2))
        XCTAssertEqual(px(after, 125, 125), px(before, 125, 125))
    }

    // MARK: 피부 마스크

    func testSkinMaskSquareFaceFallback() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let mask = try XCTUnwrap(SkinMask.make(faces: [squareFace(CGRect(x: 16, y: 16, width: 32, height: 32))],
                                               imageExtent: extent, kernels: nil))
        XCTAssertEqual(mask.extent, extent)
        let bytes = pixels(mask, colorSpace: Self.linearSRGB)
        XCTAssertGreaterThan(maskValue(bytes, width: 64, height: 64, x: 32, y: 32), 0.9)
        XCTAssertLessThan(maskValue(bytes, width: 64, height: 64, x: 0, y: 0), 0.1)
        XCTAssertLessThan(maskValue(bytes, width: 64, height: 64, x: 63, y: 63), 0.1)
    }

    func testSkinMaskEmptyFacesIsNil() {
        XCTAssertNil(SkinMask.make(faces: [], imageExtent: CGRect(x: 0, y: 0, width: 64, height: 64), kernels: nil))
    }

    func testSkinMaskCutsOutEyes() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 128)
        var f = squareFace(CGRect(x: 16, y: 16, width: 96, height: 96))
        // 왼눈을 (40,80) 주변 작은 사각형으로(1.6배 확대되어 빠진다).
        f.landmarks.leftEye = [CGPoint(x: 34, y: 76), CGPoint(x: 46, y: 76), CGPoint(x: 46, y: 84), CGPoint(x: 34, y: 84)]
        let mask = try XCTUnwrap(SkinMask.make(faces: [f], imageExtent: extent, kernels: nil))
        let bytes = pixels(mask, colorSpace: Self.linearSRGB)
        XCTAssertLessThan(maskValue(bytes, width: 128, height: 128, x: 40, y: 80), 0.3)
        XCTAssertGreaterThan(maskValue(bytes, width: 128, height: 128, x: 64, y: 40), 0.9)
    }

    /// Metal 커널(default.metallib)이 로드되고, 피부색은 높고 파랑은 낮아야 한다. 로드 실패는 빌드 설정 문제이므로 실패로 본다.
    func testSkinLikelihoodKernel() throws {
        let kernels = try XCTUnwrap(PortraitKernels.load(), "default.metallib 로드 실패(project.yml Metal 플래그 확인)")
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        // sRGB (224, 172, 140) 근처 피부색. CIColor는 sRGB 값으로 해석된다.
        let skin = CIImage(color: CIColor(red: 224 / 255, green: 172 / 255, blue: 140 / 255, colorSpace: Self.sRGB)!).cropped(to: rect)
        let blue = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.9, colorSpace: Self.sRGB)!).cropped(to: rect)
        let skinMask = try XCTUnwrap(kernels.skinMask(for: skin, in: rect))
        let blueMask = try XCTUnwrap(kernels.skinMask(for: blue, in: rect))
        XCTAssertGreaterThan(Double(pixels(skinMask, colorSpace: Self.linearSRGB)[0]) / 255, 0.5)
        XCTAssertLessThan(Double(pixels(blueMask, colorSpace: Self.linearSRGB)[0]) / 255, 0.1)
    }

    // MARK: 선명도는 피부 마스크 바깥에만

    func testSharpenSkipsSkinMask() {
        let input = checkerboard(size: 16, cell: 2)
        var p = PresetParams()
        p.auto = false
        p.clarity = 0
        p.sharpness = 100
        // 왼쪽 절반(x < 8)이 피부.
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: input.extent)
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16))
            .composited(over: black)

        let plain = EnhancePipeline.applySharpen(p, to: input, resolutionScale: 1)
        let masked = EnhancePipeline.applySharpen(p, to: input, resolutionScale: 1, skinMask: mask)
        let src = pixels(input), sharp = pixels(plain), out = pixels(masked)
        XCTAssertNotEqual(sharp, src, "마스크 없이 선명도가 실제로 픽셀을 바꿔야 테스트가 의미 있다")

        var insideSame = true, outsideChanged = false
        for y in 0..<16 {
            for x in 0..<16 {
                let i = (y * 16 + x) * 4
                if x < 8 {
                    if out[i] != src[i] { insideSame = false }
                } else if out[i] != src[i] {
                    outsideChanged = true
                }
            }
        }
        XCTAssertTrue(insideSame, "마스크 안은 입력과 같아야 한다")
        XCTAssertTrue(outsideChanged, "마스크 바깥은 선명도가 적용돼야 한다")
    }

    func testSharpenWithoutStrengthIgnoresMask() {
        let input = checkerboard(size: 16, cell: 2)
        var p = PresetParams()
        p.clarity = 0
        p.sharpness = 0
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: input.extent)
        let out = EnhancePipeline.applySharpen(p, to: input, resolutionScale: 1, skinMask: mask)
        XCTAssertTrue(out === input)
    }

    // MARK: hook

    func testPortraitStageFullWithZeroStrengthIsIdentity() {
        let input = checkerboard(size: 32, cell: 2)
        var params = PortraitParams()
        params.skinSmooth = 0
        params.teethWhiten = 0
        let hook = PortraitStage.full(detector: FaceDetector(), kernels: nil)
        let result = hook(input, params)
        XCTAssertTrue(result.image === input)
        XCTAssertNil(result.skinMask)
    }
}
