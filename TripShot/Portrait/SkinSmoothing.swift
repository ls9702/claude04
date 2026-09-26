// 피부 보정 본체: 주파수 분리(저장·앨범) / 가우시안 경량(라이브) 피부 부드럽게 + 잡티 완화 + 피부톤 업 + 치아 미백. 순수 함수.
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 인물 보정 품질. 저장·앨범은 `.full`, 라이브 프리뷰는 `.live`.
enum PortraitQuality {
    case full
    case live
}

/// 피부 보정. 네임스페이스로만 쓰며 상태가 없다.
///
/// 얼굴별 독립 처리(PLAN §3.3): 얼굴마다 그 얼굴 주변 영역만 잘라 그 얼굴 너비에 비례한 반경으로 보정하고,
/// 그 얼굴의 마스크로 섞는다. 반경이 얼굴 너비에 비례하므로 프리뷰(1024)와 풀해상도 결과가 같은 느낌이 된다.
enum SkinSmoothing {
    /// 큰 블러(피부 톤·요철) 반경 = 얼굴 너비 × 이 값 × 강도 계수.
    static let lowRadiusFraction: CGFloat = 0.012
    /// 질감 보존 경계 반경 = 큰 반경 × 이 값. 이보다 미세한 질감(모공)은 남는다.
    static let textureRadiusRatio: CGFloat = 0.25
    /// 잡티 완화(미디언) 혼합 비율 = 강도 × 이 값.
    static let medianMixRatio: CGFloat = 0.3
    /// 라이브 경량 경로: 블러 반경 배율과 혼합 비율(하이패스 없이 블러만 섞으므로 약하게).
    /// TODO(실기기): 저장본과 느낌이 비슷하도록 튜닝.
    static let liveRadiusRatio: CGFloat = 0.6
    static let liveMixRatio: CGFloat = 0.7
    /// 치아 미백: 채도 −40%, 노출 +0.15EV.
    static let teethSaturation: Float = 0.6
    static let teethExposureEV: Float = 0.15
    /// 피부톤 업(강도 100 기준): 노출 +0.4EV, 색온도 +900K 방향(따뜻하게). 마스크 × 강도로 섞는다.
    /// TODO(실기기): 과하면 EV를 0.3으로.
    static let brightenExposureEV: Float = 0.4
    static let brightenWarmKelvin: CGFloat = 900

    /// 보정 결과 이미지만 필요할 때.
    static func apply(_ input: CIImage, faces: [DetectedFace], params: PortraitParams,
                      quality: PortraitQuality, kernels: PortraitKernels?) -> CIImage {
        process(input, faces: faces, params: params, quality: quality, kernels: kernels).image
    }

    /// 보정 결과 + 피부 마스크(4단계 선명도가 마스크 바깥에만 적용되도록 전달).
    /// faces가 비었거나 피부·피부톤·치아 강도가 모두 0이면 입력 그대로(같은 객체, 픽셀 동일)와 마스크 nil.
    /// 돌려주는 피부 마스크(선명도 제외용)는 피부 부드럽게가 켜져 있을 때만 만든다(피부톤 업만으로는 nil — S5 동작 유지).
    static func process(_ input: CIImage, faces: [DetectedFace], params: PortraitParams,
                        quality: PortraitQuality, kernels: PortraitKernels?) -> PortraitResult {
        let skin = CGFloat(Mapping.clampUnsigned(params.skinSmooth) / 100)
        let teeth = CGFloat(Mapping.clampUnsigned(params.teethWhiten) / 100)
        let tone = CGFloat(Mapping.clampUnsigned(params.skinBrighten) / 100)
        let extent = input.extent
        guard !faces.isEmpty, skin > 0 || teeth > 0 || tone > 0, !extent.isInfinite, !extent.isEmpty else {
            return PortraitResult(image: input, skinMask: nil)
        }

        var image = input
        var skinMasks: [CIImage] = []

        for face in faces.prefix(SkinMask.maxFaces) {
            let faceWidth = face.boundingBox.width
            guard faceWidth > 0 else { continue }

            // 피부 마스크는 피부 부드럽게·피부톤 업이 함께 쓴다(얼굴당 한 번만 만든다).
            let mask = (skin > 0 || tone > 0)
                ? SkinMask.faceSkinMask(for: face, imageExtent: extent, source: input, kernels: kernels)
                : nil

            if skin > 0, let mask {
                let region = mask.extent
                let candidate: CIImage
                let mix: CGFloat
                switch quality {
                case .full:
                    if let kernels {
                        candidate = fullSmooth(input, region: region, faceWidth: faceWidth, strength: skin, kernels: kernels)
                        mix = skin
                    } else {
                        // 커널 로드 실패 폴백: 라이브와 같은 경량 블러.
                        candidate = liveSmooth(input, region: region, faceWidth: faceWidth, strength: skin)
                        mix = skin * liveMixRatio
                    }
                case .live:
                    candidate = liveSmooth(input, region: region, faceWidth: faceWidth, strength: skin)
                    mix = skin * liveMixRatio
                }
                image = blend(candidate, over: image, mask: scaleMask(mask, by: mix), extent: extent)
                skinMasks.append(mask)
            }

            // 피부톤 업: 부드럽게 한 결과 위에서 피부 영역만 밝고 따뜻하게. 라이브·저장 동일(필터 2개라 가볍다).
            if tone > 0, let mask {
                let brightened = brighten(image, region: mask.extent)
                image = blend(brightened, over: image, mask: scaleMask(mask, by: tone), extent: extent)
            }

            if teeth > 0, let mask = SkinMask.teethMask(for: face, imageExtent: extent) {
                let whitened = whiten(input.cropped(to: mask.extent))
                image = blend(whitened, over: image, mask: scaleMask(mask, by: teeth), extent: extent)
            }
        }

        return PortraitResult(image: image, skinMask: SkinMask.combine(skinMasks, imageExtent: extent))
    }

    // MARK: 피부 — 저장·앨범 품질

    /// 주파수 분리(질감 보존 밴드 제거) + 잡티 완화. 결과 extent = region.
    ///
    /// result = low + (input − mid)
    /// - low: 큰 반경 블러 → 피부 톤·요철(저주파)
    /// - input − mid: 작은 반경 하이패스 → 모공 같은 미세 질감(고주파). 0.5 오프셋 없이 커널에서 부호 있는 값으로 바로 더한다.
    /// 두 반경 사이의 중간 주파수(잡티·붉은 얼룩·요철)만 사라진다(YUCIHighPassSkinSmoothing의 "하이패스 → 블렌드" 구조를 밴드 제거로 단순화).
    /// 이어서 미디언(3×3, 1회)을 강도의 30%로 섞어 남은 작은 점(고주파 잡티)을 누그러뜨린다.
    static func fullSmooth(_ input: CIImage, region: CGRect, faceWidth: CGFloat, strength: CGFloat,
                           kernels: PortraitKernels) -> CIImage {
        let source = input.cropped(to: region)
        let lowRadius = max(1, faceWidth * lowRadiusFraction * (0.6 + 0.8 * strength))
        let midRadius = max(0.5, lowRadius * textureRadiusRatio)
        let low = gaussian(source, radius: lowRadius, region: region)
        let mid = gaussian(source, radius: midRadius, region: region)
        let combined = kernels.combine(input: source, low: low, mid: mid, in: region) ?? low

        guard let median = CIFilter(name: "CIMedianFilter") else { return combined }
        median.setValue(combined.clampedToExtent(), forKey: kCIInputImageKey)
        guard let medianOut = median.outputImage?.cropped(to: region) else { return combined }
        let d = CIFilter.dissolveTransition()
        d.inputImage = combined
        d.targetImage = medianOut
        d.time = Float(strength * medianMixRatio)
        return d.outputImage?.cropped(to: region) ?? combined
    }

    // MARK: 피부 — 라이브 경량

    /// Core Image에는 양방향 필터가 없으므로 작은 반경 가우시안 + 마스크 블렌드로 근사한다(하이패스 없음).
    /// 가장자리 보존은 피부 마스크(눈·입 제외, 피부색 한정)가 대신한다.
    static func liveSmooth(_ input: CIImage, region: CGRect, faceWidth: CGFloat, strength: CGFloat) -> CIImage {
        let radius = max(1, faceWidth * lowRadiusFraction * (0.6 + 0.8 * strength) * liveRadiusRatio)
        return gaussian(input.cropped(to: region), radius: radius, region: region)
    }

    // MARK: 피부톤 업

    /// 강도 100 기준 후보: 노출 +0.4EV → 색온도 +900K 방향. 결과 extent = region. 강도는 마스크 배율로 준다.
    /// 색온도 부호 규약은 `EnhancePipeline.applyTemperature`와 같다(neutral을 기준 6500K보다 높이면 따뜻해진다).
    static func brighten(_ input: CIImage, region: CGRect) -> CIImage {
        let source = input.cropped(to: region)
        let e = CIFilter.exposureAdjust()
        e.inputImage = source
        e.ev = brightenExposureEV
        let exposed = e.outputImage ?? source
        let t = CIFilter.temperatureAndTint()
        t.inputImage = exposed
        t.neutral = CIVector(x: CGFloat(Mapping.neutralKelvin) + brightenWarmKelvin, y: 0)
        t.targetNeutral = CIVector(x: CGFloat(Mapping.neutralKelvin), y: 0)
        return (t.outputImage ?? exposed).cropped(to: region)
    }

    // MARK: 치아

    /// 채도 −40% → 노출 +0.15EV.
    static func whiten(_ input: CIImage) -> CIImage {
        let c = CIFilter.colorControls()
        c.inputImage = input
        c.saturation = teethSaturation
        c.brightness = 0
        c.contrast = 1
        let desaturated = c.outputImage ?? input
        let e = CIFilter.exposureAdjust()
        e.inputImage = desaturated
        e.ev = teethExposureEV
        return (e.outputImage ?? desaturated).cropped(to: input.extent)
    }

    // MARK: 보조

    static func gaussian(_ image: CIImage, radius: CGFloat, region: CGRect) -> CIImage {
        let f = CIFilter.gaussianBlur()
        f.inputImage = image.clampedToExtent()
        f.radius = Float(radius)
        return f.outputImage?.cropped(to: region) ?? image
    }

    /// 그레이 마스크의 RGB에 k를 곱한다(알파 유지).
    static func scaleMask(_ mask: CIImage, by k: CGFloat) -> CIImage {
        guard k != 1 else { return mask }
        let f = CIFilter.colorMatrix()
        f.inputImage = mask
        f.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? mask
    }

    /// 마스크 안은 foreground, 밖은 background. 마스크·전경이 영역 한정이어도 결과는 background extent로 자른다.
    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = foreground
        f.backgroundImage = background
        f.maskImage = mask
        return f.outputImage?.cropped(to: extent) ?? background
    }
}
