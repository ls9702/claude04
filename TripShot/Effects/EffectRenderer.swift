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
    /// 효과를 적용한다. 얼굴 효과는 **모든 얼굴**에 적용한다(단체 사진). 필요한 얼굴·마스크가 없으면
    /// 가능한 범위만(렌즈는 화면 중심) 적용하거나 입력 그대로.
    static func apply(_ kind: EffectKind, to image: CIImage, input: EffectInput) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        let faces = input.faces
        let minSide = min(extent.width, extent.height)
        let center = lensCenter(faces, extent)
        let out: CIImage
        switch kind.category {
        case .sticker:
            out = stickers(kind, over: image, faces: faces, time: input.time)
        case .face:
            out = faceEffect(kind, image, faces: faces)
        case .lens:
            switch kind {
            case .bulge:
                out = bump(image, center: center, radius: minSide * 0.45, scale: 0.6)
            case .pinch:
                out = filter("CIPinchDistortion", image, [kCIInputCenterKey: CIVector(cgPoint: center),
                                                          kCIInputRadiusKey: minSide * 0.45, kCIInputScaleKey: 0.6])
            case .twirl:
                out = filter("CITwirlDistortion", image, [kCIInputCenterKey: CIVector(cgPoint: center),
                                                          kCIInputRadiusKey: minSide * 0.4, kCIInputAngleKey: Double.pi])
            case .mirror:
                out = mirror(image)
            case .fisheye:
                let bulged = bump(image, center: CGPoint(x: extent.midX, y: extent.midY),
                                  radius: max(extent.width, extent.height) * 0.75, scale: 0.5)
                out = filter("CIVignetteEffect", bulged, [kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                                                          kCIInputRadiusKey: minSide * 0.55, kCIInputIntensityKey: 0.9])
            case .lightTunnel:
                out = filter("CILightTunnel", image, [kCIInputCenterKey: CIVector(cgPoint: center),
                                                      kCIInputRadiusKey: minSide * 0.25,
                                                      "inputRotation": input.time.truncatingRemainder(dividingBy: 2 * .pi)])
            case .mirrorVertical:
                out = mirrorVertical(image)
            case .kaleidoscope:
                out = filter("CIKaleidoscope", image, ["inputCount": 6, kCIInputCenterKey: CIVector(cgPoint: center),
                                                       kCIInputAngleKey: input.time * 0.3])
            case .glassRing:
                out = filter("CITorusLensDistortion", image, [kCIInputCenterKey: CIVector(cgPoint: center),
                                                              kCIInputRadiusKey: minSide * 0.3, "inputWidth": minSide * 0.12,
                                                              "inputRefraction": 1.7])
            case .blackHole:
                out = filter("CIHoleDistortion", image, [kCIInputCenterKey: CIVector(cgPoint: center),
                                                         kCIInputRadiusKey: minSide * 0.08])
            case .stretch:
                out = filter("CIBumpDistortionLinear", image, [kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                                                               kCIInputRadiusKey: minSide * 0.6, kCIInputAngleKey: Double.pi / 2,
                                                               kCIInputScaleKey: 0.7])
            case .vortex:
                out = filter("CIVortexDistortion", image, [kCIInputCenterKey: CIVector(cgPoint: center),
                                                           kCIInputRadiusKey: minSide * 0.45, kCIInputAngleKey: 56.0])
            default:
                out = image
            }
        case .style:
            switch kind {
            case .comic: out = filter("CIComicEffect", image, [:])
            case .thermal: out = filter("CIThermal", image, [:])
            case .backgroundSwap: out = backgroundSwap(image, mask: input.personMask)
            case .popArt: out = popArt(image)
            case .colorPoint: out = colorPoint(image, mask: input.personMask)
            case .snowfall: out = snowfall(image, time: input.time)
            default: out = image
            }
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

    /// 얼굴 하나에 얹을 스티커 층(아래 → 위 순서). 크기는 두 눈 사이 거리(IOD) 배수, 위치는 눈 중점 기준.
    static func stickerLayers(_ kind: EffectKind, face f: FaceAnchors, time: Double) -> [CIImage] {
        let L = StickerLibrary.self
        var layers: [CIImage?] = []
        switch kind {
        case .puppyFace:
            layers.append(L.dogEars?.placed(at: f.point(fromEyesUp: 1.9), width: f.iod * 3.4, angle: f.roll))
            if f.mouthOpen > 0.18 {
                layers.append(L.dogTongue?.placed(at: f.offset(f.mouthCenter, up: 0.05 * f.iod), width: f.iod * 0.5, angle: f.roll))
            }
            layers.append(L.dogNose?.placed(at: f.noseTip, width: f.iod * 0.75, angle: f.roll))
        case .catFace:
            layers.append(L.catEars?.placed(at: f.point(fromEyesUp: 1.45), width: f.iod * 3.1, angle: f.roll, stretchY: 1.35))
            layers.append(L.catWhiskers?.placed(at: f.noseTip, width: f.iod * 2.9, angle: f.roll))
        case .bunnyEars:
            let wobble = CGFloat(sin(time * 3) * 0.04)
            layers.append(L.rabbitEars?.placed(at: f.point(fromEyesUp: 1.5), width: f.iod * 2.0, angle: f.roll + wobble, stretchY: 1.8))
            layers.append(L.rabbitWhiskers?.placed(at: f.noseTip, width: f.iod * 2.6, angle: f.roll))
        case .bearEars:
            layers.append(L.bearEars?.placed(at: f.point(fromEyesUp: 1.35), width: f.iod * 3.2, angle: f.roll))
            layers.append(L.bearMuzzle?.placed(at: f.noseTip, width: f.iod * 1.1, angle: f.roll))
        case .mouseEars:
            layers.append(L.mouseEars?.placed(at: f.point(fromEyesUp: 1.35), width: f.iod * 3.4, angle: f.roll))
            layers.append(L.mouseWhiskers?.placed(at: f.noseTip, width: f.iod * 2.4, angle: f.roll))
        case .flowerCrown:
            // 꽃 9송이를 머리 위 호에 벚꽃·히비스커스 번갈아.
            let n = 9
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n - 1) - 0.5                 // -0.5 ~ 0.5
                let p = f.offset(f.point(fromEyesUp: 1.55), up: (0.25 - t * t * 1.2) * f.iod, right: t * 3.4 * f.iod)
                let art = k % 2 == 0 ? L.cherryBlossom : L.hibiscus
                let size = f.iod * (k % 2 == 0 ? 0.8 : 0.65)
                layers.append(art?.placed(at: p, width: size, angle: f.roll + t * 0.8))
            }
        case .crown:
            layers.append(L.crown?.placed(at: f.point(fromEyesUp: 1.7), width: f.iod * 2.3, angle: f.roll))
        case .heartHalo:
            layers += orbit(f, count: 6, time: time, speed: 1.5, size: 0.6) { k in k % 2 == 0 ? L.redHeart : L.sparklingHeart }
        case .sunglasses:
            layers.append(L.sunglasses?.placed(at: f.point(fromEyesUp: 0.02), width: f.iod * 2.5, angle: f.roll))
        case .nerdGlasses:
            layers.append(L.glasses?.placed(at: f.point(fromEyesUp: 0.02), width: f.iod * 2.5, angle: f.roll))
        case .ribbon:
            layers.append(L.ribbon?.placed(at: f.point(fromEyesUp: 1.75, right: 0.75), width: f.iod * 1.5, angle: f.roll - 0.3))
        case .topHat:
            layers.append(L.topHat?.placed(at: f.point(fromEyesUp: 1.65), width: f.iod * 2.4, angle: f.roll))
        case .gradCap:
            layers.append(L.gradCap?.placed(at: f.point(fromEyesUp: 1.6), width: f.iod * 2.8, angle: f.roll))
        case .butterflies:
            layers += orbit(f, count: 3, time: time, speed: 0.9, size: 0.75, flutter: true) { _ in L.butterfly }
        case .angelHalo:
            let bob = CGFloat(sin(time * 2) * 0.06)
            layers.append(L.halo?.placed(at: f.point(fromEyesUp: 2.25 + bob), width: f.iod * 2.0, angle: f.roll))
        case .devilHorns:
            layers.append(L.horns?.placed(at: f.point(fromEyesUp: 1.5), width: f.iod * 2.6, angle: f.roll))
        default:
            break
        }
        return layers.compactMap { $0 }
    }

    /// 머리 주위를 도는 스티커들(하트·나비). 뒤쪽(타원 위쪽 반)은 작게 그려 깊이감을 준다.
    static func orbit(_ f: FaceAnchors, count: Int, time: Double, speed: Double, size: CGFloat, flutter: Bool = false,
                      art: (Int) -> StickerArt?) -> [CIImage?] {
        let center = f.point(fromEyesUp: 1.9)
        return (0..<count).map { k in
            let a = time * speed + Double(k) * 2 * .pi / Double(count)
            let depth = CGFloat((sin(a) + 2) / 3)
            let p = f.offset(center, up: CGFloat(sin(a)) * 0.45 * f.iod, right: CGFloat(cos(a)) * 2.0 * f.iod)
            let flap: CGFloat = flutter ? CGFloat(0.75 + 0.25 * sin(time * 12 + Double(k))) : 1
            return art(k)?.placed(at: p, width: f.iod * size * depth * flap, angle: f.roll,
                                  stretchY: flutter ? 1 / flap : 1)
        }
    }

    // MARK: 얼굴 변형 (모든 얼굴)

    static func faceEffect(_ kind: EffectKind, _ image: CIImage, faces: [FaceAnchors]) -> CIImage {
        switch kind {
        case .faceSwap:
            return faceSwap(image, faces: faces)
        default:
            return faces.reduce(image) { img, f in
                let faceRadius = max(f.faceSize.width, f.faceSize.height) * 0.75
                switch kind {
                case .bigEyes:
                    let a = bump(img, center: f.eyeLeft, radius: f.iod * 0.6, scale: 0.6)
                    return bump(a, center: f.eyeRight, radius: f.iod * 0.6, scale: 0.6)
                case .bigMouth:
                    return bump(img, center: f.mouthCenter, radius: f.iod * 1.1, scale: 0.8)
                case .balloonFace:
                    return bump(img, center: f.faceCenter, radius: faceRadius * 1.3, scale: 0.55)
                case .tinyFace:
                    return filter("CIPinchDistortion", img, [kCIInputCenterKey: CIVector(cgPoint: f.faceCenter),
                                                             kCIInputRadiusKey: faceRadius * 1.3, kCIInputScaleKey: 0.55])
                case .alien:
                    var a = bump(img, center: f.eyeLeft, radius: f.iod * 0.8, scale: 0.9)
                    a = bump(a, center: f.eyeRight, radius: f.iod * 0.8, scale: 0.9)
                    a = filter("CIPinchDistortion", a, [kCIInputCenterKey: CIVector(cgPoint: f.mouthCenter),
                                                        kCIInputRadiusKey: f.iod * 1.0, kCIInputScaleKey: 0.6])
                    // 턱을 좁혀 역삼각형 얼굴.
                    let chin = f.offset(f.mouthCenter, up: -0.5 * f.iod)
                    return filter("CIPinchDistortion", a, [kCIInputCenterKey: CIVector(cgPoint: chin),
                                                           kCIInputRadiusKey: f.iod * 1.4, kCIInputScaleKey: 0.4])
                default:
                    return img
                }
            }
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
        // 없는 키에 setValue하면 예외로 앱이 죽는다 → 필터가 가진 키만 넣는다.
        let keys = Set(f.inputKeys)
        for (key, value) in params where keys.contains(key) { f.setValue(value, forKey: key) }
        return f.outputImage?.cropped(to: image.extent) ?? image
    }

    /// 왼쪽 절반을 오른쪽에 거울처럼 복사.
    static func mirror(_ image: CIImage) -> CIImage {
        let e = image.extent
        let left = image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height))
        let reflect = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * e.midX, ty: 0)
        return left.transformed(by: reflect).composited(over: image)
    }

    /// 아래 절반을 위로 뒤집어 복사(물 반사처럼 위아래 대칭).
    static func mirrorVertical(_ image: CIImage) -> CIImage {
        let e = image.extent
        let bottom = image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 2))
        let reflect = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * e.midY)
        return bottom.transformed(by: reflect).composited(over: image)
    }

    /// 네 칸 팝아트: 절반 크기 사본 4장을 서로 다른 색으로 포스터화해 2×2로 배치.
    static func popArt(_ image: CIImage) -> CIImage {
        let e = image.extent
        let half = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: 0.5, y: 0.5))
        let posterized = filter("CIColorPosterize", filter("CIColorControls", half, [kCIInputContrastKey: 1.3,
                                                                                    kCIInputSaturationKey: 0.0]),
                                ["inputLevels": 4.0])
        let tints: [CIColor] = [CIColor(red: 1, green: 0.3, blue: 0.6), CIColor(red: 1, green: 0.85, blue: 0.1),
                                CIColor(red: 0.2, green: 0.8, blue: 1), CIColor(red: 0.4, green: 1, blue: 0.4)]
        var result = CIImage(color: .black).cropped(to: e)
        for (i, tint) in tints.enumerated() {
            let colored = filter("CIColorMonochrome", posterized, [kCIInputColorKey: tint, kCIInputIntensityKey: 1.0])
            let dx = e.minX + CGFloat(i % 2) * e.width / 2, dy = e.minY + CGFloat(1 - i / 2) * e.height / 2
            result = colored.transformed(by: CGAffineTransform(translationX: dx, y: dy)).composited(over: result)
        }
        return result
    }

    /// 사람만 컬러, 배경은 흑백. 마스크가 없으면(사람 없음) 전체 흑백.
    static func colorPoint(_ image: CIImage, mask: CIImage?) -> CIImage {
        let gray = filter("CIColorControls", image, [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.1])
        guard let mask else { return gray }
        return blend(image, over: gray, mask: mask)
    }

    /// 눈송이가 위에서 아래로 내린다. 위치는 번호로 정해지는 의사 난수라 같은 시간이면 같은 그림(저장은 시간 0).
    static func snowfall(_ image: CIImage, time: Double) -> CIImage {
        guard let flake = StickerLibrary.snowflake else { return image }
        let e = image.extent
        func rand(_ k: Int, _ salt: Double) -> Double {
            let x = sin(Double(k) * 12.9898 + salt * 78.233) * 43758.5453
            return x - x.rounded(.down)
        }
        var result = image
        for k in 0..<36 {
            let size = e.width * CGFloat(0.03 + 0.05 * rand(k, 1))
            let speed = 0.06 + 0.1 * rand(k, 2)                      // 화면 높이/초
            let phase = rand(k, 3) + time * speed
            let y = e.maxY + size - CGFloat(phase - phase.rounded(.down)) * (e.height + 2 * size)
            let x = e.minX + CGFloat(rand(k, 4)) * e.width + CGFloat(sin(time * 1.3 + Double(k))) * size * 0.5
            let art = flake.placed(at: CGPoint(x: x, y: y), width: size, angle: CGFloat(time * 0.8 + Double(k)))
            result = filter("CIColorMatrix", art, ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.85)])
                .composited(over: result)
        }
        return result
    }

    // MARK: 얼굴교환

    /// 얼굴을 서로 바꾼다. 2명이면 맞바꾸고, 3명 이상이면 돌아가며(1→2→3→1) 옮긴다.
    /// 두 눈을 맞추는 닮음 변환으로 옮기고, 타원 마스크(가장자리 흐림)로 합성한다. 얼굴이 2개 미만이면 입력 그대로.
    static func faceSwap(_ image: CIImage, faces: [FaceAnchors]) -> CIImage {
        guard faces.count >= 2 else { return image }
        // 화면 왼쪽부터 순서를 고정해 프레임마다 짝이 바뀌지 않게 한다.
        let ordered = faces.sorted { $0.faceCenter.x < $1.faceCenter.x }
        let source = image.clampedToExtent()
        var result = image
        for (i, target) in ordered.enumerated() {
            let donor = ordered[(i + 1) % ordered.count]
            let moved = source.transformed(by: similarity(from: donor, to: target))
            result = blend(moved, over: result, mask: faceMask(target))
        }
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
                // 단체 사진: 작은 얼굴까지 잡도록 검출 해상도를 높이고 최소 크기를 낮춘다.
                input.faces = detector.detect(in: image, maxFaces: EffectKind.maxFaces, detectionMaxDimension: 1600,
                                              minFaceWidthFraction: EffectKind.minFaceWidthFraction)
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
