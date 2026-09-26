// R1-S8a 피부톤 업 테스트: 이전 JSON(키 없음) 호환, 강도 0 항등성, 강도 100에서 피부 마스크 중심이 밝아짐, 인물 단계 활성 조건.
import CoreGraphics
import CoreImage
import XCTest
@testable import TripShot

final class SkinBrightenTests: XCTestCase {

    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 피부색 비슷한 단색 이미지(중간 밝기라 밝아질 여유가 있다).
    private func skinImage(size: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: 0.6, green: 0.45, blue: 0.38))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        let rect = image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: rect,
                            format: .RGBA8, colorSpace: Self.sRGB)
        }
        return bytes
    }

    /// CIImage 좌표(원점 좌하단) (x, y)의 RGB.
    private func rgb(_ bytes: [UInt8], size: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = ((size - 1 - y) * size + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// contour가 사각형인 얼굴(커널 없이 얼굴 영역 마스크만으로 판정되는 폴백 경로).
    private func squareFace(_ rect: CGRect) -> DetectedFace {
        let contour = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        return DetectedFace(boundingBox: rect, landmarks: FaceLandmarks(faceContour: contour))
    }

    private func params(brighten: Double) -> PortraitParams {
        var p = PortraitParams()
        p.skinSmooth = 0
        p.teethWhiten = 0
        p.faceSlim = 0
        p.eyeEnlarge = 0
        p.skinBrighten = brighten
        return p
    }

    // MARK: 직렬화 호환

    func testDecodingOldPortraitJSONWithoutKeyDefaultsToZero() throws {
        let json = #"{"enabled":true,"skinSmooth":40,"faceSlim":10,"eyeEnlarge":5,"teethWhiten":0}"#
        let p = try JSONDecoder().decode(PortraitParams.self, from: Data(json.utf8))
        XCTAssertEqual(p.skinBrighten, 0)
        XCTAssertEqual(p.skinSmooth, 40)
        XCTAssertEqual(p.faceSlim, 10)
        XCTAssertEqual(p.eyeEnlarge, 5)
    }

    func testDecodingOldPresetParamsKeepsOtherValues() throws {
        // 이전 버전이 저장한 프리셋: portrait에 skinBrighten 키가 없다 → PresetParams 전체가 읽혀야 한다(폴백 기본값 아님).
        var original = PresetParams()
        original.exposure = 33
        original.portrait.skinSmooth = 55
        let data = try JSONEncoder().encode(original)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var portrait = try XCTUnwrap(dict["portrait"] as? [String: Any])
        portrait.removeValue(forKey: "skinBrighten")
        dict["portrait"] = portrait
        let old = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(PresetParams.self, from: old)
        XCTAssertEqual(decoded.exposure, 33)
        XCTAssertEqual(decoded.portrait.skinSmooth, 55)
        XCTAssertEqual(decoded.portrait.skinBrighten, 0)
    }

    func testRoundTripKeepsSkinBrighten() throws {
        var p = PortraitParams()
        p.skinBrighten = 70
        let decoded = try JSONDecoder().decode(PortraitParams.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }

    // MARK: 보정

    func testZeroStrengthIsIdentity() {
        let input = skinImage(size: 64)
        let faces = [squareFace(CGRect(x: 16, y: 16, width: 32, height: 32))]
        for quality in [PortraitQuality.full, .live] {
            let result = SkinSmoothing.process(input, faces: faces, params: params(brighten: 0), quality: quality, kernels: nil)
            XCTAssertEqual(pixels(result.image), pixels(input))
            XCTAssertNil(result.skinMask)
        }
    }

    func testFullStrengthBrightensMaskCenterOnly() {
        let size = 128
        let input = skinImage(size: CGFloat(size))
        let faces = [squareFace(CGRect(x: 32, y: 32, width: 64, height: 64))]
        for quality in [PortraitQuality.full, .live] {
            let result = SkinSmoothing.process(input, faces: faces, params: params(brighten: 100), quality: quality, kernels: nil)
            XCTAssertEqual(result.image.extent, input.extent)
            XCTAssertNil(result.skinMask, "피부톤 업만으로는 선명도 제외 마스크를 만들지 않는다")

            let before = pixels(input), after = pixels(result.image)
            let b = rgb(before, size: size, x: 64, y: 64)
            let a = rgb(after, size: size, x: 64, y: 64)
            XCTAssertGreaterThan(a.r + a.g + a.b, b.r + b.g + b.b + 15, "마스크 중심은 밝아진다")

            let farB = rgb(before, size: size, x: 2, y: 2)
            let farA = rgb(after, size: size, x: 2, y: 2)
            XCTAssertEqual(farA.r, farB.r, "얼굴에서 먼 곳은 그대로")
            XCTAssertEqual(farA.g, farB.g)
            XCTAssertEqual(farA.b, farB.b)
        }
    }

    func testPortraitStageActiveWithBrightenOnly() {
        XCTAssertFalse(PortraitStage.isActive(params(brighten: 0)))
        XCTAssertTrue(PortraitStage.isActive(params(brighten: 10)))
    }

    func testSliderListIncludesSkinToneAfterSkin() {
        let list = AdjustmentKind.portrait
        let skin = try? XCTUnwrap(list.firstIndex(of: .skin))
        let tone = try? XCTUnwrap(list.firstIndex(of: .skinTone))
        XCTAssertEqual(tone, skin.map { $0 + 1 })
        XCTAssertEqual(AdjustmentKind.skinTone.title, "피부톤")
        XCTAssertEqual(AdjustmentKind.skinTone.range, 0...100)
        var p = PresetParams()
        p[keyPath: AdjustmentKind.skinTone.keyPath] = 42
        XCTAssertEqual(p.portrait.skinBrighten, 42)
    }
}
