// 보정 파이프라인을 실제 픽셀로 렌더링한다: 프리뷰(다운샘플 UIImage)와 저장용(풀해상도 CGImage).
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import UIKit

/// CIContext를 한 번만 만들어 재사용하는 렌더러. 앱에 하나만 두고 공유한다.
/// 렌더는 잠금으로 직렬화해 큰 이미지를 동시에 여러 장 처리하지 않는다(메모리 급증 방지).
final class EnhanceRenderer {
    /// 재사용하는 Core Image 컨텍스트. 생성 비용이 크므로 렌더마다 만들지 않는다.
    let ciContext: CIContext
    /// LUT·hook 등 파이프라인 외부 입력. 수평 각도처럼 사진마다 달라지는 값은 호출 시 덮어쓴다.
    var pipelineContext: PipelineContext

    private let lock = NSLock()

    /// 작업 색공간: 선형 확장 Display P3.
    /// Display P3 색역을 잃지 않으면서, Core Image 필터(노출·블러 등)가 가정하는 선형 공간에서 계산한다.
    /// sRGB 입력도 P3 안에 포함되므로 색 손실이 없다.
    static let workingColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()
    /// 프리뷰 출력 색공간(아이폰 화면은 P3).
    static let previewColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    static let sRGB: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(pipelineContext: PipelineContext = PipelineContext(luts: LUTLibrary.bundled)) {
        self.pipelineContext = pipelineContext
        let options: [CIContextOption: Any] = [
            .workingColorSpace: Self.workingColorSpace,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
    }

    // MARK: 프리뷰

    /// 긴 변이 `maxDimension` 이하가 되도록 줄인 뒤 파이프라인을 적용한다.
    /// 방향(EXIF orientation)은 파이프라인 전에 픽셀에 반영해, 수평·비네팅이 보이는 방향 기준으로 계산되게 한다.
    /// 결과 UIImage는 `.up` 방향이며 화면에서 원본과 같은 방향으로 보인다.
    func previewImage(from ui: UIImage, params: PresetParams, maxDimension: CGFloat = 1024) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return renderPreview(from: ui, params: params, maxDimension: maxDimension, context: pipelineContext)
    }

    /// 호출 측이 만든 컨텍스트로 프리뷰를 렌더한다(예: `AppServices.pipelineContext()` — 인물 모드 스위치 반영).
    /// 공유 `pipelineContext`는 바꾸지 않는다.
    func previewImage(from ui: UIImage, params: PresetParams, maxDimension: CGFloat = 1024, context: PipelineContext) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return renderPreview(from: ui, params: params, maxDimension: maxDimension, context: context)
    }

    /// 프리뷰 렌더 본체. 잠금은 호출 측이 잡는다.
    private func renderPreview(from ui: UIImage, params: PresetParams, maxDimension: CGFloat, context: PipelineContext) -> UIImage? {
        autoreleasepool { () -> UIImage? in
            guard let source = Self.ciImage(from: ui) else { return nil }
            let upright = source.oriented(Self.cgOrientation(ui.imageOrientation))
            let small = Self.downsample(upright, maxDimension: maxDimension)
            let output = EnhancePipeline.apply(params, to: small, context: context)
            let extent = output.extent
            guard !extent.isInfinite, !extent.isEmpty,
                  let cg = ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: Self.previewColorSpace)
            else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
    }

    // MARK: 저장용

    /// 풀해상도 렌더. `outputColorSpace`는 원본 색공간을 넘긴다(`colorSpace(of:)` 참고) — sRGB면 sRGB, P3면 P3.
    /// 인코딩(HEIF/JPEG)과 메타데이터 복사는 `ImageEncoder`·`ImageMetadata`(R1-S2) 담당이라 여기서는 CGImage까지만 만든다.
    /// 입력 CIImage는 방향이 이미 반영된 상태여야 한다(비파괴 편집 입력은 `.oriented(...)` 후 전달).
    /// - Parameters:
    ///   - pixelFormat: 출력 CGImage 픽셀 형식. 기본 `.RGBA8`(JPEG용). 10비트 HEIF 원본의 계조를 지키려면 `.RGBA16`.
    ///   - adjustContext: 이 렌더에만 적용할 컨텍스트 변경(예: 사진별 수평 각도). 공유 `pipelineContext`는 바꾸지 않는다.
    func renderFullResolution(ciImage: CIImage,
                              params: PresetParams,
                              outputColorSpace: CGColorSpace,
                              pixelFormat: CIFormat = .RGBA8,
                              adjustContext: ((inout PipelineContext) -> Void)? = nil) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return autoreleasepool { () -> CGImage? in
            var context = pipelineContext
            adjustContext?(&context)
            let output = EnhancePipeline.apply(params, to: ciImage, context: context)
            let extent = output.extent
            guard !extent.isInfinite, !extent.isEmpty else { return nil }
            return ciContext.createCGImage(output, from: extent, format: pixelFormat, colorSpace: outputColorSpace)
        }
    }

    // MARK: 보조 함수 (순수)

    /// 원본 CIImage의 색공간이 RGB면 그대로, 아니면(흑백·CMYK·태그 없음) sRGB.
    static func colorSpace(of image: CIImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return sRGB
    }

    /// 긴 변이 maxDimension보다 크면 Lanczos로 줄인다. 작으면 입력 그대로.
    static func downsample(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        guard !extent.isInfinite, longSide > maxDimension, maxDimension > 0 else { return image }
        let scale = maxDimension / longSide
        // 원점을 0으로 옮기고 가장자리를 늘려(투명 테두리 방지) 축소한 뒤, 정수 크기로 자른다.
        let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = atOrigin.clampedToExtent()
        f.scale = Float(scale)
        f.aspectRatio = 1
        guard let out = f.outputImage else { return image }
        let target = CGRect(x: 0, y: 0,
                            width: max(1, floor(extent.width * scale)),
                            height: max(1, floor(extent.height * scale)))
        return out.cropped(to: target)
    }

    /// UIImage → CIImage. CGImage 기반이면 원래 색공간 태그를 유지한다.
    static func ciImage(from ui: UIImage) -> CIImage? {
        if let cg = ui.cgImage { return CIImage(cgImage: cg) }
        return ui.ciImage
    }

    /// UIImage.Orientation → CGImagePropertyOrientation.
    static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
