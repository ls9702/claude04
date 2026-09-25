// R1-S7 저조도 테스트: 곡선 맵 변환, 모델 입력 방향, 폴백 경로, 곡선 커널, 번들 모델(있을 때만).
import CoreImage
import CoreML
import CoreVideo
import XCTest
@testable import TripShot

final class LowLightTests: XCTestCase {

    // MARK: 공용 도구

    /// 작업 색공간은 렌더러와 동일.
    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    /// 색 관리 없는 컨텍스트(곡선 맵 값 그대로 읽기용).
    private static let rawCtx = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func solid(_ v: CGFloat, width: CGFloat = 8, height: CGFloat = 8) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// sRGB RGBA8 바이트.
    private func pixels(_ image: CIImage) -> [UInt8] {
        let rect = image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: Self.sRGB)
        }
        return bytes
    }

    /// 색 관리 없이 RGBAf로 읽는다.
    private func rawFloats(_ image: CIImage) -> [Float] {
        let rect = image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var values = [Float](repeating: 0, count: w * h * 4)
        values.withUnsafeMutableBytes { ptr in
            Self.rawCtx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
        }
        return values
    }

    /// MLMultiArray 인덱스.
    private func idx(_ v: Int...) -> [NSNumber] { v.map { NSNumber(value: $0) } }

    /// 상수 곡선 맵(모든 채널 a, 0~1 = (A+1)/2). 4×4 — 입력 크기로 업샘플된다.
    /// `CIImage(color:)`는 sRGB로 색 관리되어 값이 바뀌므로, 실제 경로와 같이 `curveImage(from:)`로 만든다(색 관리 없음).
    private func constantCurve(_ a: Float) throws -> CIImage {
        let array = try MLMultiArray(shape: [1, 3, 4, 4], dataType: .float32)
        for c in 0..<3 { for y in 0..<4 { for x in 0..<4 {
            array[idx(0, c, y, x)] = NSNumber(value: a * 2 - 1)
        } } }
        return try XCTUnwrap(LowLightEnhancer.curveImage(from: array))
    }

    // MARK: 곡선 맵

    func testCurveImageMapsMinusOneZeroOneToZeroHalfOne() throws {
        // (1,3,2,2): 채널 0 = −1, 채널 1 = 0, 채널 2 = 1
        let array = try MLMultiArray(shape: [1, 3, 2, 2], dataType: .float32)
        for c in 0..<3 {
            let v: Float = [-1, 0, 1][c]
            for y in 0..<2 { for x in 0..<2 {
                array[idx(0, c, y, x)] = NSNumber(value: v)
            } }
        }
        let image = try XCTUnwrap(LowLightEnhancer.curveImage(from: array))
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 2, height: 2))
        let px = rawFloats(image)
        for i in 0..<4 {
            XCTAssertEqual(px[i * 4 + 0], 0, accuracy: 1e-3)
            XCTAssertEqual(px[i * 4 + 1], 0.5, accuracy: 1e-3)
            XCTAssertEqual(px[i * 4 + 2], 1, accuracy: 1e-3)
            XCTAssertEqual(px[i * 4 + 3], 1, accuracy: 1e-3)
        }
    }

    func testCurveImageKeepsRowOrder() throws {
        // 행 0(위쪽) = 1, 행 1(아래쪽) = −1 → 렌더 결과 첫 행(위쪽)이 1.0
        let array = try MLMultiArray(shape: [1, 3, 2, 1], dataType: .float32)
        for c in 0..<3 {
            array[idx(0, c, 0, 0)] = NSNumber(value: 1)
            array[idx(0, c, 1, 0)] = NSNumber(value: -1)
        }
        let px = rawFloats(try XCTUnwrap(LowLightEnhancer.curveImage(from: array)))
        XCTAssertEqual(px[0], 1, accuracy: 1e-3, "비트맵 첫 행 = 배열 행 0")
        XCTAssertEqual(px[4], 0, accuracy: 1e-3)
    }

    func testCurveImageRejectsBadShape() throws {
        let array = try MLMultiArray(shape: [1, 2, 2, 2], dataType: .float32)
        XCTAssertNil(LowLightEnhancer.curveImage(from: array))
    }

    // MARK: 모델 입력

    func testModelInputIsSquareAndKeepsOrientation() throws {
        // 위쪽 절반 흰색, 아래쪽 절반 검정(Core Image 좌표는 y가 위로 증가).
        let size = CGRect(x: 0, y: 0, width: 400, height: 300)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 150, width: 400, height: 150))
        let black = CIImage(color: .black).cropped(to: size)
        let input = white.composited(over: black)

        let enhancer = LowLightEnhancer(model: nil, kernel: nil)
        let buffer = try enhancer.renderModelInput(input)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), LowLightEnhancer.modelInputSize)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), LowLightEnhancer.modelInputSize)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let last = LowLightEnhancer.modelInputSize - 1
        // BGRA: 행 0(버퍼 위쪽)은 흰색, 마지막 행은 검정이어야 한다(곡선 맵과 같은 방향).
        XCTAssertGreaterThan(base[10 * 4 + 1], 200, "버퍼 행 0 = 이미지 위쪽")
        XCTAssertLessThan(base[last * rowBytes + 10 * 4 + 1], 50)
    }

    // MARK: 폴백 경로

    func testFallbackBrightensDarkImage() {
        let enhancer = LowLightEnhancer(model: nil, kernel: nil)
        XCTAssertFalse(enhancer.isModelAvailable)
        let input = solid(0.1)
        let out = enhancer.enhance(input, strength: 1)
        XCTAssertEqual(out.extent, input.extent)
        XCTAssertGreaterThan(pixels(out)[0], pixels(input)[0])
        XCTAssertEqual(enhancer.lastPath, .fallback("모델 없음"))
    }

    func testStrengthZeroReturnsSameObject() {
        let enhancer = LowLightEnhancer(model: nil, kernel: nil)
        let input = solid(0.1)
        XCTAssertTrue(enhancer.enhance(input, strength: 0) === input)
        XCTAssertNil(enhancer.lastPath, "강도 0은 실행으로 치지 않는다")
    }

    func testLastPathRecordsFallback() {
        let enhancer = LowLightEnhancer(model: nil, kernel: nil)
        _ = enhancer.enhance(solid(0.2), strength: 0.5)
        guard case .fallback = enhancer.lastPath else {
            return XCTFail("폴백 경로가 기록되어야 함: \(String(describing: enhancer.lastPath))")
        }
    }

    // MARK: 곡선 커널

    private func curveKernel() throws -> CIColorKernel {
        guard let kernel = EnhanceKernels.load()?.zeroDCECurve else {
            throw XCTSkip("zeroDCECurve 커널 로드 실패(default.metallib)")
        }
        return kernel
    }

    func testKernelWithZeroCurveIsIdentity() throws {
        let kernel = try curveKernel()
        let input = solid(0.25, width: 16, height: 12)
        // a = 0.5 → A = 0 → x 그대로
        let out = try XCTUnwrap(LowLightEnhancer.applyCurve(kernel: kernel, input: input, curve: try constantCurve(0.5), strength: 1))
        XCTAssertEqual(out.extent, input.extent)
        let a = pixels(out), b = pixels(input)
        for i in 0..<a.count { XCTAssertLessThanOrEqual(abs(Int(a[i]) - Int(b[i])), 1, "픽셀 \(i)") }
    }

    func testKernelNegativeCurveBrightensPositiveDarkens() throws {
        // 원본 코드의 곡선 x + A·(x² − x): A < 0이면 밝아지고 A > 0이면 어두워진다.
        let kernel = try curveKernel()
        let input = solid(0.25, width: 16, height: 12)
        let brighter = try XCTUnwrap(LowLightEnhancer.applyCurve(kernel: kernel, input: input, curve: try constantCurve(0), strength: 1))
        let darker = try XCTUnwrap(LowLightEnhancer.applyCurve(kernel: kernel, input: input, curve: try constantCurve(1), strength: 1))
        XCTAssertGreaterThan(pixels(brighter)[0], pixels(input)[0])
        XCTAssertLessThan(pixels(darker)[0], pixels(input)[0])
    }

    func testKernelStrengthZeroIsIdentity() throws {
        let kernel = try curveKernel()
        let input = solid(0.25, width: 16, height: 12)
        let out = try XCTUnwrap(LowLightEnhancer.applyCurve(kernel: kernel, input: input, curve: try constantCurve(0), strength: 0))
        let a = pixels(out), b = pixels(input)
        for i in 0..<a.count { XCTAssertLessThanOrEqual(abs(Int(a[i]) - Int(b[i])), 1, "픽셀 \(i)") }
    }

    func testKernelPathWithoutModelStillFallsBack() throws {
        let kernel = try curveKernel()
        let enhancer = LowLightEnhancer(model: nil, kernel: kernel)
        _ = enhancer.enhance(solid(0.1), strength: 1)
        XCTAssertEqual(enhancer.lastPath, .fallback("모델 없음"))
    }

    // MARK: 파이프라인 연결

    func testStageHookReceivesStrength() {
        let enhancer = LowLightEnhancer(model: nil, kernel: nil)
        var p = PresetParams()
        p.auto = false
        p.sharpness = 0
        p.clarity = 0
        p.lutName = nil
        p.vignette = 0
        p.autoHorizon = false
        p.lowLight = 70   // 야경 프리셋 값
        var context = PipelineContext()
        let hook = LowLightStage.make(enhancer: enhancer)
        var received: Double?
        context.lowLightStage = { image, s in received = s; return hook(image, s) }
        let input = solid(0.1)
        let out = EnhancePipeline.applyLowLight(p, to: input, hook: context.lowLightStage)
        XCTAssertEqual(received ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertGreaterThan(pixels(out)[0], pixels(input)[0])
    }

    // MARK: 번들 모델 (Mac에서 변환 후)

    func testBundledModelEnhancesDarkImage() throws {
        guard let model = LowLightEnhancer.loadModel() else {
            throw XCTSkip("모델 미변환(ZeroDCEpp.mlmodelc 없음)")
        }
        let kernel = try curveKernel()
        let enhancer = LowLightEnhancer(model: model, kernel: kernel)
        XCTAssertTrue(enhancer.isModelAvailable)
        // 어두운 그라데이션(모델이 평평한 단색에서도 동작하지만 실제에 가깝게).
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 640, y: 480),
            "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.03),
            "inputColor1": CIColor(red: 0.15, green: 0.12, blue: 0.1),
        ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let input = try XCTUnwrap(gradient)
        let start = CFAbsoluteTimeGetCurrent()
        let out = enhancer.enhance(input, strength: 1)
        let before = pixels(input), after = pixels(out)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(enhancer.lastPath, .model)
        XCTAssertEqual(out.extent, input.extent)
        let meanBefore = before.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }.reduce(0, +)
        let meanAfter = after.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }.reduce(0, +)
        XCTAssertGreaterThan(meanAfter, meanBefore, "저조도 모델이 평균 밝기를 올려야 함")
        XCTAssertLessThan(elapsed, 3, "PLAN R1-S7 완료 기준: 3초 이내(시뮬레이터는 참고용)")
    }
}
