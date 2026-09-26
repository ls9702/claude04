// 효과 적용: (이미지, 효과, 얼굴 기준점, 사람 마스크, 시간) → CIImage. 라이브 프리뷰·저장이 같은 함수를 쓴다(해상도만 다름).
// 보정 파이프라인 마지막(8단계)에서 `PipelineContext.effectStage` hook으로 호출된다.
import CoreImage
import Foundation
import Vision

/// 효과 hook에 넘기는 입력(얼굴·마스크는 hook이 품질에 맞게 구한다).
struct EffectInput {
    var faces: [FaceAnchors] = []
    /// 사람 = 1 회색 마스크(이미지 extent 크기). `backgroundSwap`에서만.
    var personMask: CIImage? = nil
    /// 애니메이션 시간(초). 저장은 0.
    var time: Double = 0
}

enum EffectRenderer {
    /// 효과를 적용한다. 필요한 얼굴·마스크가 없으면 가능한 범위만(렌즈는 화면 중심) 적용하거나 입력 그대로.
    static func apply(_ kind: EffectKind, to image: CIImage, input: EffectInput) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        let faces = input.faces
        let out: CIImage
        switch kind {
        case .puppyFace, .catFace, .bunnyEars, .flowerCrown, .crown, .heartHalo, .sunglasses, .blushFreckles:
            out = stickers(kind, over: image, faces: faces, time: input.time)
        case .bigEyes:
            out = faces.reduce(image) { img, f in
                let r = f.iod * 0.6
                let a = bump(img, center: f.eyeLeft, radius: r, scale: 0.6)
                return bump(a, center: f.eyeRight, radius: r, scale: 0.6)
            }
        case .bigMouth:
            out = faces.reduce(image) { img, f in bump(img, center: f.mouthCenter, radius: f.iod * 1.1, scale: 0.8) }
        case .faceSwap:
            out = faceSwap(image, faces: faces)
        case .bulge:
            out = bump(image, center: lensCenter(faces, extent), radius: min(extent.width, extent.height) * 0.45, scale: 0.6)
        case .pinch:
            out = filter("CIPinchDistortion", image, [
                kCIInputCenterKey: CIVector(cgPoint: lensCenter(faces, extent)),
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.45,
                kCIInputScaleKey: 0.6,
            ])
        case .twirl:
            out = filter("CITwirlDistortion", image, [
                kCIInputCenterKey: CIVector(cgPoint: lensCenter(faces, extent)),
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.4,
                kCIInputAngleKey: Double.pi,
            ])
        case .mirror:
            out = mirror(image)
        case .fisheye:
            let bulged = bump(image, center: CGPoint(x: extent.midX, y: extent.midY),
                              radius: max(extent.width, extent.height) * 0.75, scale: 0.5)
            out = filter("CIVignetteEffect", bulged, [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.55,
                kCIInputIntensityKey: 0.9,
            ])
        case .lightTunnel:
            out = filter("CILightTunnel", image, [
                kCIInputCenterKey: CIVector(cgPoint: lensCenter(faces, extent)),
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.25,
                "inputRotation": input.time.truncatingRemainder(dividingBy: 2 * .pi),
            ])
        case .comic:
            out = filter("CIComicEffect", image, [:])
        case .thermal:
            out = filter("CIThermal", image, [:])
        case .backgroundSwap:
            out = backgroundSwap(image, mask: input.personMask)
        }
        return out.cropped(to: extent)
    }

    // MARK: 스티커

    static func stickers(_ kind: EffectKind, over image: CIImage, faces: [FaceAnchors], time: Double) -> CIImage {
        var result = image
        for f in faces {
            for layer in stickerLayers(kind, face: f, time: time) {
                result = layer.composited(over: result)
            }
        }
        return result
    }

    /// 얼굴 하나에 얹을 스티커 층(아래 → 위 순서).
    static func stickerLayers(_ kind: EffectKind, face f: FaceAnchors, time: Double) -> [CIImage] {
        let L = StickerLibrary.self
        switch kind {
        case .puppyFace:
            var layers = [L.puppyEars.placed(at: f.point(fromEyesUp: 1.35), width: f.iod * 3.6, angle: f.roll)]
            if f.mouthOpen > 0.18 {
                layers.append(L.tongue.placed(at: f.offset(f.mouthCenter, up: -0.05 * f.iod), width: f.iod * 0.55, angle: f.roll))
            }
            layers.append(L.puppyNose.placed(at: f.noseTip, width: f.iod * 0.75, angle: f.roll))
            return layers
        case .catFace:
            return [L.catEars.placed(at: f.point(fromEyesUp: 1.5), width: f.iod * 3.2, angle: f.roll),
                    L.catWhiskers.placed(at: f.noseTip, width: f.iod * 2.8, angle: f.roll)]
        case .bunnyEars:
            let wobble = CGFloat(sin(time * 3) * 0.05)
            return [L.bunnyEars.placed(at: f.point(fromEyesUp: 1.55), width: f.iod * 2.8, angle: f.roll + wobble)]
        case .flowerCrown:
            return [L.flowerCrown.placed(at: f.point(fromEyesUp: 1.55), width: f.iod * 3.8, angle: f.roll)]
        case .crown:
            return [L.crown.placed(at: f.point(fromEyesUp: 1.7), width: f.iod * 2.4, angle: f.roll)]
        case .heartHalo:
            let center = f.point(fromEyesUp: 1.9)
            return (0..<6).map { k in
                let a = time * 1.5 + Double(k) * .pi / 3
                let depth = CGFloat((sin(a) + 2) / 3)          // 뒤쪽(sin < 0)은 작게
                let p = f.offset(center, up: CGFloat(sin(a)) * 0.45 * f.iod, right: CGFloat(cos(a)) * 1.9 * f.iod)
                return L.heart.placed(at: p, width: f.iod * 0.55 * depth, angle: f.roll)
            }
        case .sunglasses:
            return [L.sunglasses.placed(at: f.eyeMid, width: f.iod * 2.4, angle: f.roll)]
        case .blushFreckles:
            return [L.blush.placed(at: f.point(fromEyesUp: -0.55), width: f.iod * 2.6, angle: f.roll)]
        default:
            return []
        }
    }

    // MARK: 렌즈·필터

    /// 렌즈 중심: 가장 큰 얼굴 중심, 없으면 이미지 중심.
    static func lensCenter(_ faces: [FaceAnchors], _ extent: CGRect) -> CGPoint {
        faces.max { $0.faceSize.width < $1.faceSize.width }?.faceCenter ?? CGPoint(x: extent.midX, y: extent.midY)
    }

    static func bump(_ image: CIImage, center: CGPoint, radius: CGFloat, scale: CGFloat) -> CIImage {
        filter("CIBumpDistortion", image, [
            kCIInputCenterKey: CIVector(cgPoint: center),
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
    }

    /// 이름으로 필터를 만든다. 가장자리가 투명해지지 않게 입력을 확장하고, 결과는 호출 측이 원래 영역으로 자른다.
    static func filter(_ name: String, _ image: CIImage, _ params: [String: Any]) -> CIImage {
        guard let f = CIFilter(name: name) else { return image }
        f.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        for (key, value) in params { f.setValue(value, forKey: key) }
        return f.outputImage?.cropped(to: image.extent) ?? image
    }

    /// 왼쪽 절반을 오른쪽에 거울처럼 복사.
    static func mirror(_ image: CIImage) -> CIImage {
        let e = image.extent
        let left = image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height))
        let reflect = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * e.midX, ty: 0)
        return left.transformed(by: reflect).composited(over: image)
    }

    // MARK: 얼굴교환

    /// 가장 큰 두 얼굴을 서로 바꾼다. 두 눈을 맞추는 닮음 변환으로 옮기고, 타원 마스크(가장자리 흐림)로 합성한다.
    /// 얼굴이 2개 미만이면 입력 그대로.
    static func faceSwap(_ image: CIImage, faces: [FaceAnchors]) -> CIImage {
        let sorted = faces.sorted { $0.iod > $1.iod }
        guard sorted.count >= 2 else { return image }
        let a = sorted[0], b = sorted[1]
        let source = image.clampedToExtent()
        let aOnB = source.transformed(by: similarity(from: a, to: b))
        let bOnA = source.transformed(by: similarity(from: b, to: a))
        var result = blend(aOnB, over: image, mask: faceMask(b))
        result = blend(bOnA, over: result, mask: faceMask(a))
        return result
    }

    /// 얼굴 a의 두 눈을 얼굴 b의 두 눈에 맞추는 변환(회전·균등 배율·이동).
    static func similarity(from a: FaceAnchors, to b: FaceAnchors) -> CGAffineTransform {
        let s = b.iod / a.iod
        let angle = b.roll - a.roll
        return CGAffineTransform(translationX: b.eyeMid.x, y: b.eyeMid.y)
            .rotated(by: angle)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -a.eyeMid.x, y: -a.eyeMid.y)
    }

    /// 얼굴 타원 마스크(중심 1 → 가장자리 0). 눈 중점 조금 아래를 중심으로 폭 2.2·IOD, 높이 3.0·IOD.
    static func faceMask(_ f: FaceAnchors) -> CIImage {
        let unit = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputRadius0": 0.65,
            "inputRadius1": 1.0,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])?.outputImage ?? CIImage(color: .black)
        let center = f.point(fromEyesUp: -0.4)
        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: f.roll)
            .scaledBy(x: f.iod * 1.1, y: f.iod * 1.5)
        return unit.transformed(by: t)
    }

    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIBlendWithMask") else { return background }
        f.setValue(foreground, forKey: kCIInputImageKey)
        f.setValue(background, forKey: kCIInputBackgroundImageKey)
        f.setValue(mask, forKey: kCIInputMaskImageKey)
        return f.outputImage?.cropped(to: background.extent) ?? background
    }

    // MARK: 배경 바꾸기

    /// 사람은 그대로, 배경은 대각선 무지개빛 그라데이션. 마스크가 없으면(사람 없음) 입력 그대로.
    static func backgroundSwap(_ image: CIImage, mask: CIImage?) -> CIImage {
        guard let mask else { return image }
        let e = image.extent
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: e.minX, y: e.maxY),
            "inputPoint1": CIVector(x: e.maxX, y: e.minY),
            "inputColor0": CIColor(red: 1.0, green: 0.55, blue: 0.75),
            "inputColor1": CIColor(red: 0.45, green: 0.75, blue: 1.0),
        ])?.outputImage?.cropped(to: e) ?? image
        return blend(image, over: gradient, mask: mask)
    }
}

// MARK: - 사람 분리 (라이브)

/// 라이브용 사람 분리. 몇 프레임마다 `.fast`로 새로 구하고 그 사이는 마지막 마스크를 쓴다. 비디오 큐 전용.
final class LivePersonSegmenter: @unchecked Sendable {
    static let interval = 2
    private var frameIndex = 0
    private var lastMask: CIImage?
    private var lastExtent: CGRect = .null
    private let context = CIContext(options: [.cacheIntermediates: false])

    func mask(for image: CIImage) -> CIImage? {
        if image.extent != lastExtent {
            lastExtent = image.extent
            lastMask = nil
            frameIndex = 0
        }
        if frameIndex % Self.interval == 0 || lastMask == nil {
            lastMask = Self.segment(image, context: context)
        }
        frameIndex &+= 1
        return lastMask
    }

    static func segment(_ image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent
        var small = EnhanceRenderer.downsample(image, maxDimension: 512)
        if small.extent.origin != .zero {
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [.ciContext: context])
        guard (try? handler.perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return nil }
        let raw = BackgroundBlur.grayscale(CIImage(cvPixelBuffer: buffer))
        return BackgroundBlur.scaled(raw, to: extent)
    }
}

// MARK: - 파이프라인 hook

enum EffectStage {
    /// 저장·앨범용: 호출마다 얼굴 검출(필요할 때만)·정밀 사람 분리.
    static func full(detector: FaceDetector) -> (CIImage, EffectKind) -> CIImage {
        return { image, kind in
            var input = EffectInput()
            if kind.usesFaces {
                input.faces = detector.detect(in: image, detectionMaxDimension: FaceDetector.defaultDetectionMaxDimension)
                    .map(FaceAnchors.init(face:))
            }
            if kind.needsPersonMask {
                input.personMask = BackgroundBlur.mask(for: image, quality: .full)
            }
            return EffectRenderer.apply(kind, to: image, input: input)
        }
    }

    /// 라이브용: 평활 트래커 얼굴 + 빠른 사람 분리 + 애니메이션 시간. 비디오 큐에서만 호출된다.
    static func live(tracker: SmoothedFaceTracker, segmenter: LivePersonSegmenter) -> (CIImage, EffectKind) -> CIImage {
        return { image, kind in
            var input = EffectInput(time: ProcessInfo.processInfo.systemUptime)
            if kind.usesFaces {
                input.faces = tracker.faces(in: image).map(FaceAnchors.init(face:))
            }
            if kind.needsPersonMask {
                input.personMask = segmenter.mask(for: image)
            }
            return EffectRenderer.apply(kind, to: image, input: input)
        }
    }
}
