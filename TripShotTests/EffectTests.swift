// 효과(R2) 테스트: 20종 모두 렌더되고 크기를 유지하며 실제로 픽셀을 바꾸는지, 필터 이름, 얼굴 기준점, 파이프라인 8단계·직렬화 호환.
import CoreGraphics
import CoreImage
import XCTest
@testable import TripShot

final class EffectTests: XCTestCase {

    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let extent = CGRect(x: 0, y: 0, width: 360, height: 640)

    /// 가로 그라데이션(왼쪽 어두움 → 오른쪽 밝음) + 세로 줄무늬: 왜곡·거울이 픽셀을 바꾸도록.
    private func testImage() -> CIImage {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 360, y: 0),
            "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3), "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.6),
        ])!.outputImage!
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.3), "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            "inputWidth": 12.0,
        ])!.outputImage!
        return stripes.composited(over: gradient).cropped(to: extent)
    }

    /// 화면 가운데 위쪽 얼굴(IOD 60).
    private func face(x: CGFloat = 180, y: CGFloat = 400, iod: CGFloat = 60, roll: CGFloat = 0) -> FaceAnchors {
        let half = CGVector(dx: cos(roll) * iod / 2, dy: sin(roll) * iod / 2)
        return FaceAnchors(eyeLeft: CGPoint(x: x - half.dx, y: y - half.dy),
                           eyeRight: CGPoint(x: x + half.dx, y: y + half.dy),
                           noseTip: CGPoint(x: x, y: y - iod * 0.6), mouthCenter: CGPoint(x: x, y: y - iod),
                           mouthOpen: 0.3, faceCenter: CGPoint(x: x, y: y - iod * 0.4),
                           faceSize: CGSize(width: iod * 2.2, height: iod * 2.8))
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        let w = Int(extent.width), h = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: Self.sRGB)
        }
        return bytes
    }

    private func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var changed = 0
        for i in stride(from: 0, to: a.count, by: 4) where abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) > 6 {
            changed += 1
        }
        return Double(changed) / Double(a.count / 4)
    }

    /// 사람 마스크: 가운데 세로 띠만 1.
    private func personMask() -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 120, y: 0, width: 120, height: 500))
            .composited(over: CIImage(color: .black).cropped(to: extent))
    }

    func testTwentyEffects() {
        XCTAssertEqual(EffectKind.allCases.count, 20)
        XCTAssertEqual(Set(EffectKind.allCases.map(\.title)).count, 20, "타일 이름 중복 없음")
    }

    func testFilterNamesExist() {
        for name in ["CIBumpDistortion", "CIPinchDistortion", "CITwirlDistortion", "CIVignetteEffect", "CILightTunnel",
                     "CIComicEffect", "CIThermal", "CIRadialGradient", "CIBlendWithMask", "CILinearGradient"] {
            XCTAssertNotNil(CIFilter(name: name), name)
        }
        let tunnel = CIFilter(name: "CILightTunnel")!
        XCTAssertTrue(tunnel.inputKeys.contains("inputRotation"))
    }

    func testEveryEffectRendersAndChangesPixels() {
        let input = testImage()
        let base = pixels(input)
        let faces = [face(), face(x: 120, y: 180, iod: 45, roll: 0.2)]
        for kind in EffectKind.allCases {
            let out = EffectRenderer.apply(kind, to: input,
                                           input: EffectInput(faces: faces, personMask: personMask(), time: 0.7))
            XCTAssertEqual(out.extent, input.extent, "\(kind) 크기 유지")
            let fraction = changedFraction(base, pixels(out))
            XCTAssertGreaterThan(fraction, 0.003, "\(kind)가 픽셀을 바꿔야 한다 (\(fraction))")
        }
    }

    func testFaceEffectsWithoutFacesAreIdentity() {
        let input = testImage()
        let base = pixels(input)
        for kind in EffectKind.allCases where kind.minimumFaces >= 1 {
            let out = EffectRenderer.apply(kind, to: input, input: EffectInput())
            XCTAssertEqual(changedFraction(base, pixels(out)), 0, "\(kind): 얼굴 없으면 그대로")
        }
        // 얼굴교환은 한 명이면 그대로.
        let one = EffectRenderer.apply(.faceSwap, to: input, input: EffectInput(faces: [face()]))
        XCTAssertEqual(changedFraction(base, pixels(one)), 0)
    }

    func testBackgroundSwapKeepsPerson() {
        let input = testImage()
        let out = pixels(EffectRenderer.apply(.backgroundSwap, to: input, input: EffectInput(personMask: personMask())))
        let base = pixels(input)
        func px(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Int { let row = 639 - y; return Int(bytes[(row * 360 + x) * 4]) }
        XCTAssertEqual(px(out, 180, 250), px(base, 180, 250), accuracy: 2, "사람 영역은 그대로")
        XCTAssertNotEqual(px(out, 20, 600), px(base, 20, 600), "배경은 바뀜")
    }

    func testMirrorIsSymmetric() {
        let out = pixels(EffectRenderer.apply(.mirror, to: testImage(), input: EffectInput()))
        func px(_ x: Int, _ y: Int) -> Int { Int(out[(y * 360 + x) * 4]) }
        for x in [10, 60, 150] {
            XCTAssertEqual(px(x, 300), px(359 - x, 300), accuracy: 3, "x=\(x)")
        }
    }

    func testFaceAnchorsFromDetectedFace() {
        var lm = FaceLandmarks()
        // 오른쪽이 올라간 기울어진 얼굴(각도 atan(10/60)), 순서는 일부러 뒤집어 넣는다.
        lm.leftEye = [CGPoint(x: 210, y: 410)]
        lm.rightEye = [CGPoint(x: 150, y: 400)]
        lm.nose = [CGPoint(x: 180, y: 380), CGPoint(x: 182, y: 360)]
        lm.innerLips = [CGPoint(x: 180, y: 345), CGPoint(x: 180, y: 327)]
        lm.outerLips = [CGPoint(x: 170, y: 336), CGPoint(x: 190, y: 336)]
        let f = FaceAnchors(face: DetectedFace(boundingBox: CGRect(x: 120, y: 300, width: 120, height: 150), landmarks: lm))
        XCTAssertEqual(f.eyeLeft.x, 150, "이미지 왼쪽 눈이 먼저")
        XCTAssertEqual(f.roll, atan2(10, 60), accuracy: 1e-6)
        XCTAssertEqual(f.iod, hypot(60, 10), accuracy: 1e-6)
        XCTAssertEqual(f.noseTip.y, 360, "위 방향으로 가장 낮은 코 점")
        XCTAssertGreaterThan(f.mouthOpen, 0.2)
        XCTAssertGreaterThan(f.headTop.y, f.eyeMid.y + f.iod)
    }

    func testFaceSwapSimilarityMapsEyes() {
        let a = face(x: 100, y: 200, iod: 40, roll: 0.1), b = face(x: 250, y: 450, iod: 70, roll: -0.2)
        let t = EffectRenderer.similarity(from: a, to: b)
        let l = a.eyeLeft.applying(t), r = a.eyeRight.applying(t)
        XCTAssertEqual(l.x, b.eyeLeft.x, accuracy: 1e-6); XCTAssertEqual(l.y, b.eyeLeft.y, accuracy: 1e-6)
        XCTAssertEqual(r.x, b.eyeRight.x, accuracy: 1e-6); XCTAssertEqual(r.y, b.eyeRight.y, accuracy: 1e-6)
    }

    func testPipelineEffectStage() {
        var stages: [EnhanceStage] = []
        var called: EffectKind?
        var ctx = PipelineContext()
        ctx.onStage = { stage, _ in stages.append(stage) }
        ctx.effectStage = { image, kind in called = kind; return image }
        var p = PresetParams.identity
        _ = EnhancePipeline.apply(p, to: testImage(), context: ctx)
        XCTAssertNil(called, "effect nil이면 hook을 부르지 않는다")
        XCTAssertEqual(stages.last, .effect)
        p.effect = EffectKind.crown.rawValue
        _ = EnhancePipeline.apply(p, to: testImage(), context: ctx)
        XCTAssertEqual(called, .crown)
        XCTAssertNotEqual(p, PresetParams.identity, "원본 + 효과는 촬영 후처리 대상")
    }

    func testOldPresetJSONDecodesWithoutEffect() throws {
        let data = try JSONEncoder().encode(PresetParams())
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "effect")
        let old = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertNil(try JSONDecoder().decode(PresetParams.self, from: old).effect)
    }
}
