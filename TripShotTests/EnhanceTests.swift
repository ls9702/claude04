// R1-S1 보정 엔진 테스트: LUT 파서, 값 매핑, 파이프라인 항등성·단계 순서.
import CoreImage
import XCTest
@testable import TripShot

final class EnhanceTests: XCTestCase {

    // MARK: 공용 도구

    /// 테스트 전용 컨텍스트(작업 색공간은 렌더러와 동일). 테스트 전체에서 하나만 쓴다.
    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 4×4 단색 이미지.
    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: CGFloat = 4) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// 이미지를 sRGB RGBA8 바이트로 렌더한다.
    private func pixels(_ image: CIImage) -> [UInt8] {
        let rect = image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: Self.sRGB)
        }
        return bytes
    }

    /// 모든 강도 0, 자동 끔, LUT 없음.
    private func neutralParams() -> PresetParams {
        var p = PresetParams()
        p.auto = false
        p.sharpness = 0
        p.clarity = 0
        p.lutName = nil
        p.vignette = 0
        p.autoHorizon = false
        p.lowLight = 0
        return p
    }

    private let sampleCube = """
    # 항등 LUT
    TITLE "identity"

    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1
    0 0 0
    1 0 0
    0\t1\t0
    1 1 0   # 줄 끝 주석
    0 0 1

    1 0 1
    0 1 1
    1 1 1
    """

    // MARK: LUT 파서

    func testParseValidCube() throws {
        let lut = try LUT.parse(sampleCube)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.title, "identity")
        let f = lut.floats
        XCTAssertEqual(f.count, 8 * 4)
        XCTAssertEqual(lut.data.count, 8 * 4 * MemoryLayout<Float>.size)
        // 두 번째 항목(red가 가장 빠름): (1,0,0,1)
        XCTAssertEqual(Array(f[4..<8]), [1, 0, 0, 1])
        // 다섯 번째 항목: (0,0,1,1)
        XCTAssertEqual(Array(f[16..<20]), [0, 0, 1, 1])
        // alpha는 모두 1
        for i in 0..<8 { XCTAssertEqual(f[i * 4 + 3], 1) }
    }

    func testParseIgnoresCommentsAndBlankLines() throws {
        let text = "\n\n# 주석만\n   \nLUT_3D_SIZE 2\n" + String(repeating: "0.5 0.5 0.5\n\n", count: 8) + "# 끝\n"
        let lut = try LUT.parse(text)
        XCTAssertEqual(lut.size, 2)
        XCTAssertNil(lut.title)
        XCTAssertEqual(lut.floats.count, 32)
    }

    func testParseMissingSizeThrows() {
        let text = String(repeating: "0 0 0\n", count: 8)
        XCTAssertThrowsError(try LUT.parse(text)) { error in
            XCTAssertEqual(error as? LUTError, .missingSize)
        }
    }

    func testParseCountMismatchThrows() {
        let text = "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 7)
        XCTAssertThrowsError(try LUT.parse(text)) { error in
            XCTAssertEqual(error as? LUTError, .valueCountMismatch(expected: 8, actual: 7))
        }
    }

    func testParseBadLineThrows() {
        let text = "LUT_3D_SIZE 2\n0 0\n"
        XCTAssertThrowsError(try LUT.parse(text)) { error in
            XCTAssertEqual(error as? LUTError, .parseFailure(line: 2, content: "0 0"))
        }
    }

    func testParseDomainNormalizes() throws {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" + String(repeating: "2 1 0\n", count: 8)
        let f = try LUT.parse(text).floats
        XCTAssertEqual(Array(f[0..<4]), [1, 0.5, 0, 1])
    }

    func testBundledMonoLUTLoads() throws {
        let luts = LUTLibrary.load(from: Bundle.main)
        let mono = try XCTUnwrap(luts["mono"], "Resources/LUT/mono.cube가 번들에 있어야 함")
        XCTAssertEqual(mono.size, 2)
        let f = mono.floats
        // 각 항목은 R=G=B(회색), 마지막은 흰색
        for i in 0..<8 {
            XCTAssertEqual(f[i * 4], f[i * 4 + 1])
            XCTAssertEqual(f[i * 4 + 1], f[i * 4 + 2])
        }
        XCTAssertEqual(f[7 * 4], 1, accuracy: 1e-4)
        XCTAssertEqual(f[1 * 4], 0.2126, accuracy: 1e-4) // 순수 빨강
    }

    func testBuiltInPresetLUTNamesExistInBundle() {
        XCTAssertEqual(Seed.builtInPresets.count, 6)
        let luts = LUTLibrary.load(from: Bundle.main)
        for item in Seed.builtInPresets {
            if let name = item.params.lutName {
                XCTAssertNotNil(luts[name], "\(item.name)의 LUT \(name) 없음")
            }
        }
    }

    // MARK: 매핑

    func testMappingBoundaries() {
        XCTAssertEqual(Mapping.exposureEV(-100), -2)
        XCTAssertEqual(Mapping.exposureEV(0), 0)
        XCTAssertEqual(Mapping.exposureEV(100), 2)
        XCTAssertEqual(Mapping.exposureEV(500), 2) // 범위 밖은 잘림

        XCTAssertEqual(Mapping.contrast(-100), 0.8, accuracy: 1e-9)
        XCTAssertEqual(Mapping.contrast(0), 1)
        XCTAssertEqual(Mapping.contrast(100), 1.2, accuracy: 1e-9)

        XCTAssertEqual(Mapping.highlightAmount(-100), 0.3, accuracy: 1e-9)
        XCTAssertEqual(Mapping.highlightAmount(0), 1)
        XCTAssertEqual(Mapping.highlightAmount(100), 1)

        XCTAssertEqual(Mapping.shadowAmount(-100), -1)
        XCTAssertEqual(Mapping.shadowAmount(0), 0)
        XCTAssertEqual(Mapping.shadowAmount(100), 1)

        XCTAssertEqual(Mapping.temperatureKelvin(-100), 4500)
        XCTAssertEqual(Mapping.temperatureKelvin(0), 6500)
        XCTAssertEqual(Mapping.temperatureKelvin(100), 8500)

        XCTAssertEqual(Mapping.vibranceAmount(-100), -1)
        XCTAssertEqual(Mapping.vibranceAmount(0), 0)
        XCTAssertEqual(Mapping.vibranceAmount(100), 1)

        XCTAssertEqual(Mapping.sharpness(0, resolutionScale: 1).intensity, 0)
        XCTAssertEqual(Mapping.sharpness(100, resolutionScale: 1).intensity, 1)
        XCTAssertEqual(Mapping.clarity(0, resolutionScale: 1).intensity, 0)
        XCTAssertEqual(Mapping.clarity(100, resolutionScale: 1).intensity, 0.5)
        // 반경은 해상도에 비례
        XCTAssertEqual(Mapping.clarity(50, resolutionScale: 4).radius, Mapping.clarity(50, resolutionScale: 1).radius * 4, accuracy: 1e-9)

        XCTAssertEqual(Mapping.lutMix(0), 0)
        XCTAssertEqual(Mapping.lutMix(100), 1)
        XCTAssertEqual(Mapping.vignetteIntensity(0), 0)
        XCTAssertEqual(Mapping.vignetteIntensity(100), 1)
        XCTAssertEqual(Mapping.vignetteIntensity(-10), 0)
    }

    func testHorizonCropScale() {
        XCTAssertEqual(Mapping.horizonCropScale(width: 400, height: 300, angle: 0), 1, accuracy: 1e-9)
        let s = Mapping.horizonCropScale(width: 400, height: 300, angle: 0.1)
        XCTAssertLessThan(s, 1)
        XCTAssertGreaterThan(s, 0.8)
        // 좌우 대칭
        XCTAssertEqual(s, Mapping.horizonCropScale(width: 400, height: 300, angle: -0.1), accuracy: 1e-9)
    }

    func testResolutionScale() {
        XCTAssertEqual(Mapping.resolutionScale(for: CGRect(x: 0, y: 0, width: 1024, height: 768)), 1)
        XCTAssertEqual(Mapping.resolutionScale(for: CGRect(x: 0, y: 0, width: 3024, height: 4032)), 4032.0 / 1024.0, accuracy: 1e-9)
    }

    // MARK: 파이프라인 항등성

    func testNeutralParamsLeavePixelsUnchanged() {
        let input = solid(0.4, 0.5, 0.6)
        let output = EnhancePipeline.apply(neutralParams(), to: input, context: PipelineContext())
        XCTAssertEqual(output.extent, input.extent)
        XCTAssertEqual(pixels(output), pixels(input))
    }

    func testEachStageIsIdentityAtZero() {
        let input = solid(0.2, 0.7, 0.3)
        let p = neutralParams()
        let reference = pixels(input)
        let stages: [(String, CIImage)] = [
            ("auto", EnhancePipeline.applyAuto(p, to: input)),
            ("tone", EnhancePipeline.applyTone(p, to: input)),
            ("portrait", EnhancePipeline.applyPortrait(p, to: input, hook: nil)),
            ("sharpen", EnhancePipeline.applySharpen(p, to: input, resolutionScale: 1)),
            ("lowLight", EnhancePipeline.applyLowLight(p, to: input, hook: { _ in CIImage(color: .black) })),
            ("lut", EnhancePipeline.applyLUT(p, to: input, luts: [:], colorSpace: Self.sRGB)),
            ("finish", EnhancePipeline.applyFinish(p, to: input, horizonAngle: 0.2)),
        ]
        for (name, out) in stages {
            XCTAssertEqual(out.extent, input.extent, name)
            XCTAssertEqual(pixels(out), reference, name)
        }
    }

    func testLUTIntensityZeroIsIdentity() throws {
        var p = neutralParams()
        p.lutName = "mono"
        p.lutIntensity = 0
        let luts = ["mono": try LUT.parse(sampleCube)]
        let input = solid(0.9, 0.1, 0.1)
        let out = EnhancePipeline.applyLUT(p, to: input, luts: luts, colorSpace: Self.sRGB)
        XCTAssertEqual(pixels(out), pixels(input))
    }

    func testMonoLUTProducesGray() throws {
        let mono = try XCTUnwrap(LUTLibrary.load(from: Bundle.main)["mono"])
        var p = neutralParams()
        p.lutName = "mono"
        p.lutIntensity = 100
        let out = EnhancePipeline.applyLUT(p, to: solid(0.9, 0.2, 0.1), luts: ["mono": mono], colorSpace: Self.sRGB)
        let px = pixels(out)
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertLessThanOrEqual(abs(Int(px[0]) - Int(px[1])), 2)
        XCTAssertLessThanOrEqual(abs(Int(px[1]) - Int(px[2])), 2)
    }

    func testExposureChangesPixels() {
        var p = neutralParams()
        p.exposure = 50
        let input = solid(0.3, 0.3, 0.3)
        let out = EnhancePipeline.applyTone(p, to: input)
        XCTAssertEqual(out.extent, input.extent)
        XCTAssertGreaterThan(pixels(out)[0], pixels(input)[0])
    }

    func testHorizonKeepsOriginAndShrinks() {
        let input = solid(0.5, 0.5, 0.5, size: 100)
        let out = EnhancePipeline.applyHorizon(angle: 0.1, to: input)
        XCTAssertEqual(out.extent.minX, 0)
        XCTAssertEqual(out.extent.minY, 0)
        XCTAssertLessThan(out.extent.width, 100)
        XCTAssertEqual(out.extent.width, out.extent.height)
    }

    // MARK: 단계 순서

    func testStageOrderAndHooks() throws {
        var log: [String] = []
        var portraitInput: CIImage?
        var lowLightExtent: CGRect?

        var p = neutralParams()
        p.exposure = 50            // 톤 단계가 실제로 무언가 하게
        p.lowLight = 50            // 저조도 hook 활성
        p.portrait.enabled = true
        let expectedPortrait = p.portrait

        var context = PipelineContext()
        context.portraitStage = { image, portrait in
            log.append("portrait-hook")
            portraitInput = image
            XCTAssertEqual(portrait, expectedPortrait)
            // 이후 단계에서 식별되도록 extent를 줄여 돌려준다
            return image.cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        context.lowLightStage = { image in
            log.append("lowLight-hook")
            lowLightExtent = image.extent
            return image
        }
        context.onStage = { stage, _ in log.append("\(stage)") }

        let input = solid(0.3, 0.3, 0.3)
        let out = EnhancePipeline.apply(p, to: input, context: context)

        XCTAssertEqual(log, [
            "auto",
            "tone",
            "portrait-hook", "portrait",
            "sharpen",
            "lowLight-hook", "lowLight",
            "lut",
            "finish",
        ])

        // portrait hook은 톤 적용 후 이미지를 받는다
        let toned = EnhancePipeline.applyTone(p, to: input)
        let received = try XCTUnwrap(portraitInput)
        XCTAssertEqual(pixels(received), pixels(toned))
        XCTAssertNotEqual(pixels(toned), pixels(input))
        // lowLight hook은 portrait 결과(2×2) 이후에 호출된다
        XCTAssertEqual(lowLightExtent, CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    func testPortraitHookSkippedWhenDisabled() {
        var called = false
        var p = neutralParams()
        p.portrait.enabled = false
        let out = EnhancePipeline.applyPortrait(p, to: solid(0.1, 0.1, 0.1), hook: { img, _ in called = true; return img })
        XCTAssertFalse(called)
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    // MARK: 렌더러

    func testRendererColorSpaceOfKeepsRGB() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let cg = Self.ctx.createCGImage(solid(0.5, 0.5, 0.5), from: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBA8, colorSpace: p3)!
        let image = CIImage(cgImage: cg)
        XCTAssertEqual(EnhanceRenderer.colorSpace(of: image).name as String?, CGColorSpace.displayP3 as String)
    }

    func testRendererFullResolutionKeepsSize() {
        let renderer = EnhanceRenderer(pipelineContext: PipelineContext())
        let cg = renderer.renderFullResolution(ciImage: solid(0.4, 0.4, 0.4, size: 16), params: neutralParams(), outputColorSpace: Self.sRGB)
        XCTAssertEqual(cg?.width, 16)
        XCTAssertEqual(cg?.height, 16)
    }

    func testDownsampleLimitsLongSide() {
        let big = solid(0.5, 0.5, 0.5, size: 2048)
        let small = EnhanceRenderer.downsample(big, maxDimension: 1024)
        XCTAssertEqual(small.extent.origin, .zero)
        XCTAssertLessThanOrEqual(max(small.extent.width, small.extent.height), 1024)
    }
}
