// PresetParams → CIImage 보정 파이프라인 (PLAN §3.2 순서 고정). 모든 단계는 부작용 없는 순수 함수.
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 파이프라인 단계. rawValue는 PLAN §3.2 표의 번호.
enum EnhanceStage: Int, CaseIterable {
    case auto = 1
    case tone
    case portrait
    case sharpen
    case lowLight
    case lut
    case finish
}

/// 3단계 인물 hook의 결과. 보정된 이미지와, 4단계 선명도가 피하도록 넘길 피부 마스크(0~1 그레이, 1 = 피부).
struct PortraitResult {
    var image: CIImage
    /// nil이면 선명도를 이미지 전체에 적용한다(얼굴 없음·피부 보정 0).
    var skinMask: CIImage?
}

/// 파이프라인이 이미지 외에 필요로 하는 외부 입력. 값 타입이며 파이프라인은 이를 읽기만 한다.
struct PipelineContext {
    /// 이름 → LUT. 보통 `LUTLibrary.bundled`.
    var luts: [String: LUT] = [:]
    /// 3단계 인물 보정 hook (`PortraitStage.full`/`.live`). nil이면 건너뜀.
    /// 결과의 `skinMask`는 4단계 선명도에 전달된다(PLAN §3.2: 선명도는 피부 마스크 바깥에만).
    var portraitStage: ((CIImage, PortraitParams) -> PortraitResult)? = nil
    /// 앨범 프리뷰용 인물 hook(R1-S8b). `isPreview`가 true이고 이 값이 있으면 `portraitStage` 대신 쓴다.
    /// 차이는 배경 흐림의 인물 분리 품질뿐이다(프리뷰 `.balanced`, 저장 `.accurate`).
    var portraitPreviewStage: ((CIImage, PortraitParams) -> PortraitResult)? = nil
    /// 앨범 프리뷰 렌더인지(R1-S8b). `EnhanceViewModel`이 프리뷰 렌더 컨텍스트에서만 true로 세운다. 저장 경로는 false.
    var isPreview: Bool = false
    /// 5단계 저조도 hook (R1-S7 Zero-DCE++, `LowLightStage.make`). nil이면 건너뜀. `params.lowLight > 0`일 때만 호출.
    /// 두 번째 인자는 강도 0~1(`params.lowLight / 100`). 라이브 프리뷰 컨텍스트는 nil(PLAN §3.2: 프리뷰 비활성·저장 시만).
    var lowLightStage: ((CIImage, Double) -> CIImage)? = nil
    /// 7단계 수평 보정 회전각(라디안, 반시계 방향 +). 이미지를 이 각도만큼 돌려 수평을 맞춘다.
    /// Vision 검출 결과를 호출 측이 변환해 넣는다. nil이면 수평 보정 없음.
    var horizonAngle: Double? = nil
    /// .cube 값이 정의된 색공간. 일반적인 .cube는 sRGB(감마) 기준.
    var lutColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// 테스트·디버그용: 각 단계가 끝날 때마다 (단계, 그 단계의 출력)으로 호출된다. 이미지에 영향 없음.
    var onStage: ((EnhanceStage, CIImage) -> Void)? = nil
}

extension PipelineContext {
    /// 이번 렌더에 쓸 인물 hook: 프리뷰면 프리뷰용(있으면), 아니면 저장용.
    var resolvedPortraitStage: ((CIImage, PortraitParams) -> PortraitResult)? {
        if isPreview, let preview = portraitPreviewStage { return preview }
        return portraitStage
    }
}

/// 보정 파이프라인. 네임스페이스로만 쓰며 상태를 갖지 않는다.
/// 각 단계 함수는 강도가 0이면 필터를 만들지 않고 입력을 그대로 반환한다(픽셀 동일 보장).
enum EnhancePipeline {

    /// 전체 파이프라인. 순서: 1 자동 → 2 톤·색 → 3 인물 → 4 선명도 → 5 저조도 → 6 LUT → 7 마무리.
    /// 공간 필터(반경이 있는 필터)의 반경은 입력 해상도에 비례시켜 프리뷰와 저장본의 결과가 같아 보이게 한다.
    static func apply(_ params: PresetParams, to input: CIImage, context: PipelineContext) -> CIImage {
        let scale = Mapping.resolutionScale(for: input.extent)
        var image = input

        image = applyAuto(params, to: image)
        context.onStage?(.auto, image)

        image = applyTone(params, to: image)
        context.onStage?(.tone, image)

        let portrait = applyPortrait(params, to: image, hook: context.resolvedPortraitStage)
        image = portrait.image
        context.onStage?(.portrait, image)

        image = applySharpen(params, to: image, resolutionScale: scale, skinMask: portrait.skinMask)
        context.onStage?(.sharpen, image)

        image = applyLowLight(params, to: image, hook: context.lowLightStage)
        context.onStage?(.lowLight, image)

        image = applyLUT(params, to: image, luts: context.luts, colorSpace: context.lutColorSpace)
        context.onStage?(.lut, image)

        image = applyFinish(params, to: image, horizonAngle: context.horizonAngle)
        context.onStage?(.finish, image)

        return image
    }

    // MARK: 1 자동

    /// Apple 자동 개선. `params.auto`가 false면 입력 그대로.
    /// 적목 보정은 끈다(얼굴 검출 비용·오검출 방지, 인물 보정은 3단계 담당).
    /// 참고: 자동 필터 값은 이미지 내용을 분석해 정해지므로 프리뷰(다운샘플)와 풀해상도의 결과가 미세하게 다를 수 있다.
    /// TODO(검증): 풀해상도 분석 비용이 크면 프리뷰에서 얻은 필터 값을 저장 시 재사용하도록 R1-S3에서 조정.
    static func applyAuto(_ params: PresetParams, to input: CIImage) -> CIImage {
        guard params.auto else { return input }
        return applyAutoFilters(autoFilters(for: input), to: input)
    }

    /// 1단계의 "분석" 부분: 이미지 내용을 보고 자동 개선 필터 목록을 만든다(CPU 비용이 있음).
    /// 라이브 프리뷰(R1-S4 `LivePipeline`)는 이 결과를 몇 프레임 동안 재사용한다.
    static func autoFilters(for input: CIImage) -> [CIFilter] {
        // crop·level은 명시적으로 꺼서 자동 크롭·기울기 보정 필터가 섞이지 않게 한다(수평은 7단계 담당).
        input.autoAdjustmentFilters(options: [.redEye: false, .enhance: true, .crop: false, .level: false])
    }

    /// 1단계의 "적용" 부분: `autoFilters(for:)`가 만든 필터를 순서대로 적용하고 입력 영역으로 자른다.
    /// 필터 객체의 inputImage를 바꾸므로 같은 필터 목록을 여러 스레드에서 동시에 쓰지 않는다.
    static func applyAutoFilters(_ filters: [CIFilter], to input: CIImage) -> CIImage {
        guard !filters.isEmpty else { return input }
        var image = input
        for filter in filters {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let out = filter.outputImage { image = out }
        }
        return image.cropped(to: input.extent)
    }

    // MARK: 2 톤·색

    /// 노출 → 대비 → 하이라이트/섀도우 → 화이트밸런스 → 생동감. 값이 0인 항목은 건너뜀.
    static func applyTone(_ params: PresetParams, to input: CIImage) -> CIImage {
        var image = input
        image = applyExposure(params.exposure, to: image)
        image = applyContrast(params.contrast, to: image)
        image = applyHighlightShadow(highlights: params.highlights, shadows: params.shadows, to: image)
        image = applyTemperature(params.temperature, to: image)
        image = applyVibrance(params.vibrance, to: image)
        return image
    }

    static func applyExposure(_ value: Double, to input: CIImage) -> CIImage {
        let ev = Mapping.exposureEV(value)
        guard ev != 0 else { return input }
        let f = CIFilter.exposureAdjust()
        f.inputImage = input
        f.ev = Float(ev)
        return f.outputImage ?? input
    }

    static func applyContrast(_ value: Double, to input: CIImage) -> CIImage {
        let c = Mapping.contrast(value)
        guard c != 1 else { return input }
        let f = CIFilter.colorControls()
        f.inputImage = input
        f.contrast = Float(c)
        // 기본값을 명시해 대비만 바뀌게 한다.
        f.saturation = 1
        f.brightness = 0
        return f.outputImage ?? input
    }

    static func applyHighlightShadow(highlights: Double, shadows: Double, to input: CIImage) -> CIImage {
        let h = Mapping.highlightAmount(highlights)
        let s = Mapping.shadowAmount(shadows)
        guard h != 1 || s != 0 else { return input }
        let f = CIFilter.highlightShadowAdjust()
        // 내부 블러가 가장자리에서 투명 픽셀을 섞지 않도록 확장 후 원래 영역으로 자른다.
        f.inputImage = input.clampedToExtent()
        f.highlightAmount = Float(h)
        f.shadowAmount = Float(s)
        return f.outputImage?.cropped(to: input.extent) ?? input
    }

    static func applyTemperature(_ value: Double, to input: CIImage) -> CIImage {
        let kelvin = Mapping.temperatureKelvin(value)
        guard kelvin != Mapping.neutralKelvin else { return input }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = input
        // neutral = 촬영 광원으로 가정할 색온도, targetNeutral = 기준 6500K.
        // neutral을 높이면(8500K) 푸른 빛을 보정하는 방향이라 결과가 따뜻해진다(라이트룸 슬라이더와 같은 방향).
        // TODO(검증): 실기기에서 +값이 따뜻해지는지 확인. 반대면 neutral/targetNeutral을 맞바꾼다.
        f.neutral = CIVector(x: CGFloat(kelvin), y: 0)
        f.targetNeutral = CIVector(x: CGFloat(Mapping.neutralKelvin), y: 0)
        return f.outputImage ?? input
    }

    static func applyVibrance(_ value: Double, to input: CIImage) -> CIImage {
        let amount = Mapping.vibranceAmount(value)
        guard amount != 0 else { return input }
        let f = CIFilter.vibrance()
        f.inputImage = input
        f.amount = Float(amount)
        return f.outputImage ?? input
    }

    // MARK: 3 인물 (hook)

    /// 인물 보정 hook. hook이 없거나 `portrait.enabled == false`면 입력 그대로(마스크 nil).
    static func applyPortrait(_ params: PresetParams, to input: CIImage,
                              hook: ((CIImage, PortraitParams) -> PortraitResult)?) -> PortraitResult {
        guard let hook, params.portrait.enabled else { return PortraitResult(image: input, skinMask: nil) }
        return hook(input, params.portrait)
    }

    // MARK: 4 선명도

    /// 언샤프 마스크(sharpness) + 로컬 대비(clarity; 큰 반경·낮은 강도의 언샤프 마스크로 근사).
    /// 로컬 대비를 먼저, 세부 선명도를 나중에 적용한다.
    /// `skinMask`가 있으면 PLAN §3.2대로 **피부 마스크 바깥에만** 적용한다(마스크 1 = 입력 유지, 0 = 선명 결과).
    static func applySharpen(_ params: PresetParams, to input: CIImage, resolutionScale: Double,
                             skinMask: CIImage? = nil) -> CIImage {
        var image = input
        let clarity = Mapping.clarity(params.clarity, resolutionScale: resolutionScale)
        image = unsharp(image, radius: clarity.radius, intensity: clarity.intensity)
        let sharp = Mapping.sharpness(params.sharpness, resolutionScale: resolutionScale)
        image = unsharp(image, radius: sharp.radius, intensity: sharp.intensity)
        guard let skinMask, image !== input, !input.extent.isInfinite else { return image }
        // 마스크가 이미지보다 작아도 바깥은 0(선명 결과)이 되도록 검정 배경 위에 둔다.
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: input.extent)
        let f = CIFilter.blendWithMask()
        f.inputImage = input
        f.backgroundImage = image
        f.maskImage = skinMask.composited(over: black).cropped(to: input.extent)
        return f.outputImage?.cropped(to: input.extent) ?? image
    }

    private static func unsharp(_ input: CIImage, radius: Double, intensity: Double) -> CIImage {
        guard intensity > 0, radius > 0 else { return input }
        let f = CIFilter.unsharpMask()
        f.inputImage = input.clampedToExtent()
        f.radius = Float(radius)
        f.intensity = Float(intensity)
        return f.outputImage?.cropped(to: input.extent) ?? input
    }

    // MARK: 5 저조도 (hook)

    /// 저조도 hook. `params.lowLight == 0`이거나 hook이 없으면 입력 그대로. hook에는 강도 0~1을 넘긴다.
    static func applyLowLight(_ params: PresetParams, to input: CIImage, hook: ((CIImage, Double) -> CIImage)?) -> CIImage {
        let strength = Mapping.lowLightStrength(params.lowLight)
        guard let hook, strength > 0 else { return input }
        return hook(input, strength)
    }

    // MARK: 6 색감 룩 (LUT)

    /// `lutName`에 해당하는 LUT를 적용하고 `lutIntensity`로 원본과 섞는다.
    /// LUT 이름이 없거나, 사전에 없거나, 강도가 0이면 입력 그대로.
    static func applyLUT(_ params: PresetParams, to input: CIImage, luts: [String: LUT], colorSpace: CGColorSpace) -> CIImage {
        guard let name = params.lutName, let lut = luts[name] else { return input }
        let t = Mapping.lutMix(params.lutIntensity)
        guard t > 0 else { return input }
        let looked = lut.ciFilter(input: input, colorSpace: colorSpace)
        guard t < 1 else { return looked }
        // 디졸브: time 0 = inputImage(원본), 1 = targetImage(LUT 결과)
        let f = CIFilter.dissolveTransition()
        f.inputImage = input
        f.targetImage = looked
        f.time = Float(t)
        return f.outputImage?.cropped(to: input.extent) ?? looked
    }

    // MARK: 7 마무리

    /// 수평 보정(회전+크롭) 후 비네팅. 크롭된 화면 기준으로 비네팅 중심이 잡히도록 이 순서.
    static func applyFinish(_ params: PresetParams, to input: CIImage, horizonAngle: Double?) -> CIImage {
        var image = input
        if params.autoHorizon, let angle = horizonAngle {
            image = applyHorizon(angle: angle, to: image)
        }
        image = applyVignette(params.vignette, to: image)
        return image
    }

    /// 이미지 중심 기준으로 `angle`(라디안)만큼 회전하고, 빈 모서리가 보이지 않게
    /// 같은 비율의 가장 큰 사각형으로 크롭한다. 출력 extent의 원점은 입력과 같게 맞춘다.
    /// 각도가 매우 작거나(0.001rad 미만) 45°를 넘으면(검출 오류로 간주) 입력 그대로.
    static func applyHorizon(angle: Double, to input: CIImage) -> CIImage {
        let extent = input.extent
        guard !extent.isInfinite, abs(angle) >= 0.001, abs(angle) <= .pi / 4 else { return input }
        let s = Mapping.horizonCropScale(width: extent.width, height: extent.height, angle: angle)
        let cx = extent.midX, cy = extent.midY
        let rotation = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: CGFloat(angle))
            .translatedBy(x: -cx, y: -cy)
        let rotated = input.transformed(by: rotation)
        // 정수 픽셀 크기로 내림해 투명 가장자리가 섞이지 않게 한다.
        let w = floor(extent.width * s)
        let h = floor(extent.height * s)
        let crop = CGRect(x: (cx - w / 2).rounded(.up), y: (cy - h / 2).rounded(.up), width: w, height: h)
        let cropped = rotated.cropped(to: crop)
        return cropped.transformed(by: CGAffineTransform(translationX: extent.minX - crop.minX, y: extent.minY - crop.minY))
    }

    static func applyVignette(_ value: Double, to input: CIImage) -> CIImage {
        let intensity = Mapping.vignetteIntensity(value)
        let extent = input.extent
        guard intensity > 0, !extent.isInfinite else { return input }
        let f = CIFilter.vignetteEffect()
        f.inputImage = input
        f.center = CGPoint(x: extent.midX, y: extent.midY)
        f.radius = Float(Mapping.vignetteRadius(width: extent.width, height: extent.height))
        f.intensity = Float(intensity)
        return f.outputImage?.cropped(to: extent) ?? input
    }
}

// MARK: - 값 매핑

/// UI 값(0~100 또는 -100~100)을 각 Core Image 필터의 실제 범위로 바꾸는 순수 함수 모음.
/// 범위를 벗어난 입력은 먼저 잘라낸다. 0은 항상 "효과 없음" 값으로 매핑된다.
/// 수치는 R1-S3 실사용에서 조정한다.
enum Mapping {
    /// 공간 반경의 기준 해상도(긴 변 픽셀). 프리뷰 기본 크기와 같다.
    static let referenceDimension: Double = 1024
    static let neutralKelvin: Double = 6500

    static func clampSigned(_ v: Double) -> Double { min(max(v, -100), 100) }
    static func clampUnsigned(_ v: Double) -> Double { min(max(v, 0), 100) }

    /// 긴 변 / 1024. 반경 계열 값에 곱한다. 무한 extent면 1.
    static func resolutionScale(for extent: CGRect) -> Double {
        guard !extent.isInfinite, !extent.isEmpty else { return 1 }
        return Double(max(extent.width, extent.height)) / referenceDimension
    }

    /// -100…100 → EV -2…+2
    static func exposureEV(_ v: Double) -> Double { clampSigned(v) / 50 }

    /// -100…100 → CIColorControls.contrast 0.8…1.2 (1 = 변화 없음)
    static func contrast(_ v: Double) -> Double { 1 + clampSigned(v) * 0.002 }

    /// -100…100 → CIHighlightShadowAdjust.highlightAmount.
    /// 이 필터는 1이 원본이고 낮출수록 하이라이트를 누른다(권장 하한 0.3). 따라서 음수만 효과가 있고
    /// -100 → 0.3, 0 이상 → 1(변화 없음).
    /// TODO(R1-S3): +값(하이라이트 밝히기)이 필요하면 톤 커브로 별도 구현.
    static func highlightAmount(_ v: Double) -> Double { 1 + min(clampSigned(v), 0) / 100 * 0.7 }

    /// -100…100 → CIHighlightShadowAdjust.shadowAmount -1…1 (0 = 변화 없음)
    static func shadowAmount(_ v: Double) -> Double { clampSigned(v) / 100 }

    /// -100(차가움)…100(따뜻함) → 광원 가정 색온도 4500K…8500K (0 = 6500K)
    static func temperatureKelvin(_ v: Double) -> Double { neutralKelvin + clampSigned(v) * 20 }

    /// -100…100 → CIVibrance.amount -1…1
    static func vibranceAmount(_ v: Double) -> Double { clampSigned(v) / 100 }

    /// 0…100 → 언샤프 마스크 (반경 1.5px@1024, 강도 0…1)
    static func sharpness(_ v: Double, resolutionScale: Double) -> (radius: Double, intensity: Double) {
        (radius: 1.5 * max(resolutionScale, 0.25), intensity: clampUnsigned(v) / 100)
    }

    /// 0…100 → 로컬 대비 근사 (반경 20px@1024, 강도 0…0.5)
    static func clarity(_ v: Double, resolutionScale: Double) -> (radius: Double, intensity: Double) {
        (radius: 20 * max(resolutionScale, 0.25), intensity: clampUnsigned(v) / 100 * 0.5)
    }

    /// 0…100 → 저조도 강도 0…1 (Zero-DCE++ 곡선 결과와 원본의 혼합 비율)
    static func lowLightStrength(_ v: Double) -> Double { clampUnsigned(v) / 100 }

    /// 0…100 → 디졸브 비율 0…1
    static func lutMix(_ v: Double) -> Double { clampUnsigned(v) / 100 }

    /// 0…100 → CIVignetteEffect.intensity 0…1
    static func vignetteIntensity(_ v: Double) -> Double { clampUnsigned(v) / 100 }

    /// 비네팅 시작 반경: 대각선 절반의 75%. 해상도에 비례하므로 프리뷰/저장 결과가 같다.
    static func vignetteRadius(width: CGFloat, height: CGFloat) -> Double {
        Double((width * width + height * height).squareRoot()) / 2 * 0.75
    }

    /// w×h 이미지를 angle만큼 돌렸을 때, 돌린 이미지 안에 들어가는 같은 비율 사각형의 배율(≤ 1).
    /// 조건: w·s·cos + h·s·sin ≤ w, w·s·sin + h·s·cos ≤ h
    static func horizonCropScale(width: CGFloat, height: CGFloat, angle: Double) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let c = CGFloat(abs(cos(angle)))
        let s = CGFloat(abs(sin(angle)))
        let a = width / (width * c + height * s)
        let b = height / (width * s + height * c)
        return min(a, b, 1)
    }
}
