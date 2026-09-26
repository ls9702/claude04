// 배경 흐림(R1-S8b): Vision 인물 분리 마스크를 만들고, 사람은 원본·배경은 가우시안 블러로 합성한다. 저장·앨범 전용(라이브 미적용).
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

/// 배경 흐림. 네임스페이스로만 쓰며 상태가 없다(공유 CIContext만 있음, 스레드 안전).
enum BackgroundBlur {
    /// 블러 반경 = 긴 변 × 이 값 × 강도(0~1). 1024 프리뷰에서 최대 약 12px, 4032 저장본에서 약 48px — 해상도에 비례해 보이는 결과가 같다.
    /// TODO(실기기): 강도 100에서 흐림이 약하면 0.02로 올린다.
    static let radiusFraction: CGFloat = 0.012
    /// 마스크 경계 페더 반경 = 긴 변 × 이 값. 머리카락·어깨 경계를 부드럽게.
    static let featherFraction: CGFloat = 0.003
    /// 인물 분리에 넘길 이미지 긴 변. 풀해상도 12MP를 Vision에 넘기지 않는다(마스크는 어차피 저해상도).
    static let segmentationMaxDimension: CGFloat = 1536
    /// 마스크 최대값이 이보다 낮으면 "사람 없음"으로 본다(0~1).
    static let personPresenceThreshold: CGFloat = 0.5

    /// 사람 판정용 1×1 렌더 컨텍스트. 색 관리 없이(마스크 값 그대로) 읽는다.
    private static let probeContext = CIContext(options: [.workingColorSpace: NSNull(),
                                                          .outputColorSpace: NSNull(),
                                                          .cacheIntermediates: false])
    /// Vision이 입력을 렌더할 때 쓰는 컨텍스트(기본 색 관리). `FaceDetector`와 같은 설정.
    private static let visionContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: 마스크

    /// 사람 마스크(입력 extent와 같은 좌표·크기, 사람 = 1, 배경 = 0). 사람이 없거나 실패하면 nil.
    /// - Parameters:
    ///   - quality: `.live`면 항상 nil(라이브 금지, 비용). `.full`만 분리한다.
    ///   - isPreview: 앨범 프리뷰면 `.balanced`, 저장이면 `.accurate`.
    static func mask(for image: CIImage, quality: PortraitQuality, isPreview: Bool = false) -> CIImage? {
        guard quality == .full else { return nil }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }

        var small = EnhanceRenderer.downsample(image, maxDimension: segmentationMaxDimension)
        if small.extent.origin != .zero {
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        }

        // 시그니처(iOS 15+): VNGeneratePersonSegmentationRequest.qualityLevel: QualityLevel(.fast/.balanced/.accurate)
        //                    .outputPixelFormat: OSType, results: [VNPixelBufferObservation]?
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = isPreview ? .balanced : .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [.ciContext: visionContext])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let raw = grayscale(CIImage(cvPixelBuffer: buffer))
        guard hasPerson(raw) else { return nil }
        return scaled(raw, to: extent)
    }

    /// 한 채널 마스크를 R 값 기준 회색(r=g=b=R, a=1)으로 맞춘다. OneComponent8 버퍼가 CIImage에서
    /// (v, v, v) 또는 (v, 0, 0) 어느 쪽으로 읽혀도 같은 결과가 되게 한다.
    /// TODO(검증): OneComponent8 → CIImage 채널 해석. 이 함수가 두 경우를 모두 흡수하므로 동작에는 영향 없음.
    static func grayscale(_ mask: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = mask
        f.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (f.outputImage ?? mask).cropped(to: mask.extent)
    }

    /// 마스크 최대값(`CIAreaMaximum`)이 임계값 이상이면 사람이 있다고 본다.
    static func hasPerson(_ mask: CIImage) -> Bool {
        let extent = mask.extent
        guard !extent.isInfinite, !extent.isEmpty else { return false }
        let f = CIFilter.areaMaximum()
        f.inputImage = mask
        f.extent = extent
        guard let output = f.outputImage else { return false }
        // 출력은 1×1. 원점은 구현에 따라 입력 extent 원점일 수 있어 출력 extent 원점을 쓴다.
        // TODO(검증): 사람이 뚜렷한 사진에서 hasPerson이 false로 나오면(마스크 전체가 흐림 없이 그대로) 이 판정·임계값부터 확인.
        let origin = output.extent.isInfinite ? extent.origin : output.extent.origin
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { ptr in
            probeContext.render(output, toBitmap: ptr.baseAddress!, rowBytes: 4,
                                bounds: CGRect(origin: origin, size: CGSize(width: 1, height: 1)),
                                format: .RGBA8, colorSpace: nil)
        }
        return CGFloat(pixel[0]) / 255 >= personPresenceThreshold
    }

    /// 저해상도 마스크를 입력 extent 크기·위치로 늘린다(이중선형). 순수 함수.
    static func scaled(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let m = mask.extent
        guard !m.isEmpty, !m.isInfinite, !extent.isEmpty, !extent.isInfinite else { return mask }
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: extent.width / m.width, y: extent.height / m.height)
            .translatedBy(x: -m.minX, y: -m.minY)
        return mask.clampedToExtent().samplingLinear().transformed(by: transform).cropped(to: extent)
    }

    // MARK: 합성

    /// 사람(마스크 1)은 원본, 배경(마스크 0)은 블러. 강도 0이면 입력 그대로(같은 객체). 순수 함수.
    /// - Parameters:
    ///   - personMask: 입력 extent 좌표의 회색 마스크(사람 = 1).
    ///   - strength: 0~1 (`PortraitParams.backgroundBlur / 100`).
    static func apply(_ input: CIImage, personMask: CIImage, strength: Double) -> CIImage {
        let s = min(max(strength, 0), 1)
        let extent = input.extent
        guard s > 0, !extent.isInfinite, !extent.isEmpty else { return input }
        let longSide = max(extent.width, extent.height)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(longSide * radiusFraction * CGFloat(s))
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return input }

        // 마스크 바깥(입력 extent 중 마스크가 없는 곳)은 배경(0)으로 본다.
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        var mask = personMask.cropped(to: extent).composited(over: black)
        let featherRadius = longSide * featherFraction
        if featherRadius >= 0.5 {
            let feather = CIFilter.gaussianBlur()
            feather.inputImage = mask.clampedToExtent()
            feather.radius = Float(featherRadius)
            mask = feather.outputImage?.cropped(to: extent) ?? mask
        }

        // TODO(검증): 실기기에서 사람·배경이 반대로 흐려지면 inputImage/backgroundImage를 맞바꾼다(마스크 1 = inputImage가 기대 동작).
        let blend = CIFilter.blendWithMask()
        blend.inputImage = input
        blend.backgroundImage = blurred
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? input
    }
}
