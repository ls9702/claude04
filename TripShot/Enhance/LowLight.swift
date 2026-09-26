// 5단계 저조도(Zero-DCE++): 512×512에서 Core ML로 곡선 맵을 추정하고, 풀해상도에는 Metal 커널로 픽셀 단위 곡선을 적용한다.
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import Metal
import os

/// 마지막 저조도 실행이 어떤 경로를 탔는지(설정·디버그 표시용).
enum LowLightPath: Equatable {
    /// Zero-DCE++ 모델 + 곡선 커널.
    case model
    /// 모델 없이 감마·섀도우 보정으로 근사. 연관값은 폴백한 이유.
    case fallback(String)
}

/// Zero-DCE++ 저조도 보정기. 앱에 하나만 두고 공유한다(`AppServices.lowLight`).
///
/// 처리 흐름(PLAN §3.2 5단계, R1-S7):
/// 1. 입력을 512×512로 줄여(비율 무시) sRGB 8비트 `CVPixelBuffer`로 렌더.
/// 2. Core ML 예측 → 곡선 파라미터 맵 A (1,3,512,512), tanh(−1~1).
/// 3. A를 (A+1)/2로 0~1 float 텍스처(`CIImage`, 색 관리 없음)로 만들고 원본 크기로 선형 업샘플.
/// 4. `zeroDCECurve` 커널로 풀해상도 픽셀마다 x = x + A·(x² − x)를 8회 반복(감마 공간)하고 강도로 섞는다.
///
/// **타일 처리는 하지 않는다.** 네트워크는 항상 512×512에서만 돌고(입력 크기 고정), 풀해상도 쪽 작업은
/// 이웃 픽셀을 보지 않는 픽셀 단위 컬러 커널 1패스라 Core Image가 알아서 타일 렌더한다.
/// 따라서 4032×3024도 타일 분할 없이 처리된다. 메모리는 512×512 BGRA 입력 버퍼(1MB)와
/// 곡선 맵 512×512×4 float(4MB)뿐이다. 곡선 맵은 저주파라 비율 무시 리샘플·선형 업샘플로 충분하다.
///
/// 시간 목표: A14에서 512 추론 수십 ms + 커널 1패스. 저장 3초 이내(PLAN §8 R1-S7 완료 기준).
///
/// 실패(모델 없음·예측 오류·커널 없음)하면 모델 없는 폴백 보정을 하고 이유를 로그와 `lastPath`에 남긴다.
/// 저장이 실패하지는 않는다(PLAN 리뷰 포인트: 실패 시 건너뜀 — 여기서는 "건너뛰되 폴백으로 약하게 개선").
final class LowLightEnhancer: @unchecked Sendable {
    /// 모델 입력 한 변. `tools/convert_zero_dce.py --size`와 같아야 한다.
    static let modelInputSize = 512
    /// LE 곡선 반복 횟수(Zero-DCE++ 원본과 동일).
    static let iterations = 8
    /// 번들 모델 이름(Xcode가 ZeroDCEpp.mlpackage를 컴파일한 ZeroDCEpp.mlmodelc).
    static let modelName = "ZeroDCEpp"
    static let inputName = "image"
    static let outputName = "curve"

    private static let log = Logger(subsystem: "com.ls9702.tripshot", category: "lowlight")

    private let model: MLModel?
    private let kernel: CIColorKernel?
    /// 512 입력 렌더 전용 컨텍스트. `EnhanceRenderer`의 잠금과 무관하게 쓰기 위해 따로 둔다.
    private let ciContext: CIContext
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 예측·입력 버퍼 재사용을 직렬화한다.
    private let lock = NSLock()
    private var inputBuffer: CVPixelBuffer?
    private var _lastPath: LowLightPath?

    /// 테스트·주입용. `model`/`kernel`이 nil이면 폴백 경로만 탄다.
    init(model: MLModel?, kernel: CIColorKernel?) {
        self.model = model
        self.kernel = kernel
        let options: [CIContextOption: Any] = [
            .workingColorSpace: EnhanceRenderer.workingColorSpace,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
    }

    /// 번들에서 모델과 커널을 로드한다. 없으면 각각 nil(폴백 경로).
    convenience init(bundle: Bundle = .main) {
        self.init(model: Self.loadModel(bundle: bundle), kernel: EnhanceKernels.load(bundle: bundle)?.zeroDCECurve)
    }

    /// 번들의 ZeroDCEpp.mlmodelc를 로드한다. Xcode 자동 생성 클래스는 쓰지 않는다(모델이 저장소에 없어도 컴파일되게).
    static func loadModel(bundle: Bundle = .main) -> MLModel? {
        guard let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") else {
            log.info("저조도 모델 없음(\(Self.modelName, privacy: .public).mlmodelc) → 폴백 사용")
            return nil
        }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // iOS 27 시뮬레이터(Xcode 27)에서는 GPU 경로(.all/.cpuAndGPU)가 이 FP16 mlprogram의 출력을 전부 0으로 내놓는다
        // (BUILD_LOG 09-26). 실기기와 무관한 시뮬레이터 결함이므로 시뮬레이터에서만 CPU로 돌린다.
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        do {
            return try MLModel(contentsOf: url, configuration: config)
        } catch {
            log.error("저조도 모델 로드 실패: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 모델이 번들에 있고 로드됐는지(설정 화면 표시용).
    var isModelAvailable: Bool { model != nil }

    /// 마지막 `enhance` 실행 경로. 아직 실행 전이면 nil.
    var lastPath: LowLightPath? {
        lock.lock(); defer { lock.unlock() }
        return _lastPath
    }

    private func record(_ path: LowLightPath) {
        lock.lock(); _lastPath = path; lock.unlock()
        if case .fallback(let reason) = path {
            Self.log.notice("저조도 폴백: \(reason, privacy: .public)")
        }
    }

    // MARK: 보정

    /// 저조도 보정. `strength` 0~1(0이면 입력 그대로 — 같은 객체 반환).
    func enhance(_ input: CIImage, strength: Double) -> CIImage {
        let s = min(max(strength, 0), 1)
        guard s > 0 else { return input }
        let extent = input.extent
        guard !extent.isInfinite, !extent.isEmpty else { return input }

        guard let model else {
            record(.fallback("모델 없음"))
            return Self.fallbackEnhance(input, strength: s)
        }
        guard let kernel else {
            record(.fallback("곡선 커널 없음(default.metallib)"))
            return Self.fallbackEnhance(input, strength: s)
        }
        do {
            let curve = try predictCurve(for: input, model: model)
            guard let out = Self.applyCurve(kernel: kernel, input: input, curve: curve, strength: s) else {
                record(.fallback("곡선 커널 적용 실패"))
                return Self.fallbackEnhance(input, strength: s)
            }
            record(.model)
            return out
        } catch {
            record(.fallback("예측 실패: \(error.localizedDescription)"))
            return Self.fallbackEnhance(input, strength: s)
        }
    }

    /// 1~2단계: 512 입력 렌더 → 예측 → 512×512 곡선 맵 CIImage(0~1, 원점 (0,0)).
    private func predictCurve(for input: CIImage, model: MLModel) throws -> CIImage {
        lock.lock(); defer { lock.unlock() }
        let start = CFAbsoluteTimeGetCurrent()
        let buffer = try renderModelInput(input)

        let features = try MLDictionaryFeatureProvider(dictionary: [inputName(of: model): MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: features)
        guard let array = output.featureValue(for: Self.outputName)?.multiArrayValue
                ?? output.featureNames.lazy.compactMap({ output.featureValue(for: $0)?.multiArrayValue }).first
        else { throw LowLightError.missingOutput }
        guard let curve = Self.curveImage(from: array) else { throw LowLightError.badOutputShape(array.shape.map(\.intValue)) }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Self.log.debug("저조도 추론 \(Int(ms))ms (입력 \(Int(input.extent.width))×\(Int(input.extent.height)))")
        return curve
    }

    /// 입력을 모델 입력 크기의 sRGB BGRA 버퍼로 렌더한다(버퍼는 재사용). 버퍼 행 0 = 이미지 위쪽.
    /// 잠금 안에서 호출한다(테스트는 단일 스레드라 직접 호출해도 된다).
    /// TODO(검증): CIRenderDestination(pixelBuffer:)의 기본 방향이 "행 0 = 위쪽"인지 — `LowLightTests.testModelInputKeepsOrientation`이 확인한다.
    ///   뒤집혀 있으면 `destination.isFlipped = true`로 맞춘다(곡선 맵이 상하 반전되면 밝힐 곳을 잘못 밝힌다).
    func renderModelInput(_ input: CIImage) throws -> CVPixelBuffer {
        let size = Self.modelInputSize
        let buffer = try reusableInputBuffer(size: size)
        let small = Self.resampleToSquare(input, size: size)
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = sRGB   // 모델은 sRGB 감마 0~255 입력으로 학습됨
        // 렌더 완료를 기다린 뒤 예측한다(비동기 GPU 렌더가 끝나기 전에 버퍼를 읽지 않게).
        _ = try ciContext.startTask(toRender: small, to: destination).waitUntilCompleted()
        return buffer
    }

    /// 모델 입력 이름. 변환 스크립트는 "image"로 만든다. 다르면 첫 입력 이름을 쓴다.
    private func inputName(of model: MLModel) -> String {
        let inputs = model.modelDescription.inputDescriptionsByName
        if inputs[Self.inputName] != nil { return Self.inputName }
        return inputs.keys.first ?? Self.inputName
    }

    /// size×size BGRA 버퍼를 한 번 만들어 재사용한다. 잠금 안에서 호출.
    private func reusableInputBuffer(size: Int) throws -> CVPixelBuffer {
        if let inputBuffer, CVPixelBufferGetWidth(inputBuffer) == size { return inputBuffer }
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw LowLightError.pixelBuffer(status) }
        inputBuffer = buffer
        return buffer
    }

    // MARK: 순수 함수

    /// 입력을 size×size(비율 무시)로 줄여 원점 (0,0)에 둔다. 가장자리가 투명과 섞이지 않게 확장 후 자른다.
    static func resampleToSquare(_ input: CIImage, size: Int) -> CIImage {
        let extent = input.extent
        let side = CGFloat(size)
        let origin = input.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = origin.clampedToExtent()
        f.scale = Float(side / extent.height)
        f.aspectRatio = Float(extent.height / extent.width)   // 가로 배율 = scale·aspectRatio = side / width
        let scaled = f.outputImage
            ?? origin.transformed(by: CGAffineTransform(scaleX: side / extent.width, y: side / extent.height))
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// 모델 출력 (1,3,H,W) 또는 (3,H,W) → RGBAf CIImage(H×W, 원점 (0,0), 색 관리 없음).
    /// 각 채널 A(−1~1)를 (A+1)/2(0~1)로 담는다. 알파는 1. 배열의 행 0이 이미지 위쪽(Core Image 비트맵 규약과 같음).
    /// 형태가 맞지 않으면 nil.
    static func curveImage(from array: MLMultiArray) -> CIImage? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 3 else { return nil }
        let n = shape.count
        let channels = shape[n - 3], height = shape[n - 2], width = shape[n - 1]
        guard channels >= 3, height > 0, width > 0 else { return nil }
        let cs = strides[n - 3], hs = strides[n - 2], ws = strides[n - 1]
        // 앞쪽 배치 차원은 0번째만 쓴다(오프셋 0).
        let maxOffset = (channels - 1) * cs + (height - 1) * hs + (width - 1) * ws

        var rgba = [Float](repeating: 1, count: width * height * 4)
        func fill(_ read: (Int) -> Float) {
            for y in 0..<height {
                for x in 0..<width {
                    let base = y * hs + x * ws
                    let o = (y * width + x) * 4
                    for c in 0..<3 {
                        let a = read(base + c * cs)
                        rgba[o + c] = min(max((a + 1) * 0.5, 0), 1)
                    }
                }
            }
        }

        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: maxOffset + 1)
            fill { p[$0] }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: maxOffset + 1)
            fill { Float(p[$0]) }
        case .float16:
            // mlprogram 출력이 FLOAT16으로 나오는 경우. iOS(arm64)에서는 Swift Float16 사용 가능.
            let p = array.dataPointer.bindMemory(to: Float16.self, capacity: maxOffset + 1)
            fill { Float(p[$0]) }
        default:
            // 드문 형식은 느리지만 확실한 NSNumber 첨자로 읽는다(선형 오프셋 → 다차원 인덱스 대신 전체 첨자).
            let lead = [NSNumber](repeating: 0, count: n - 3)
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    for c in 0..<3 {
                        let a = array[lead + [NSNumber(value: c), NSNumber(value: y), NSNumber(value: x)]].floatValue
                        rgba[o + c] = min(max((a + 1) * 0.5, 0), 1)
                    }
                }
            }
        }

        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }

    /// 곡선 맵(작은 해상도, 원점 (0,0))을 입력 extent 크기로 선형 업샘플하고 커널로 풀해상도 곡선을 적용한다.
    static func applyCurve(kernel: CIColorKernel, input: CIImage, curve: CIImage, strength: Double) -> CIImage? {
        let extent = input.extent
        let ce = curve.extent
        guard !extent.isInfinite, !extent.isEmpty, !ce.isEmpty, !ce.isInfinite else { return nil }
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: extent.width / ce.width, y: extent.height / ce.height)
            .translatedBy(x: -ce.minX, y: -ce.minY)
        let upsampled = curve.samplingLinear().clampedToExtent().transformed(by: transform).cropped(to: extent)
        return kernel.apply(extent: extent, arguments: [
            input, upsampled,
            NSNumber(value: Float(iterations)),
            NSNumber(value: Float(min(max(strength, 0), 1))),
        ])
    }

    /// 모델 없이 저조도를 근사 개선: 감마 x^(1/(1+0.8s)) + 섀도우 올림(0.6s).
    /// 두 필터 값이 이미 강도에 비례하므로 원본과 다시 섞지 않는다(섞으면 강도가 이중으로 약해짐).
    static func fallbackEnhance(_ input: CIImage, strength: Double) -> CIImage {
        let s = min(max(strength, 0), 1)
        guard s > 0 else { return input }
        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = input
        gamma.power = Float(1 / (1 + 0.8 * s))
        var image = gamma.outputImage ?? input
        let hs = CIFilter.highlightShadowAdjust()
        hs.inputImage = image.clampedToExtent()   // 내부 블러가 가장자리 투명 픽셀을 섞지 않게
        hs.highlightAmount = 1
        hs.shadowAmount = Float(0.6 * s)
        image = hs.outputImage?.cropped(to: input.extent) ?? image
        return image
    }
}

/// 모델 경로 실패 이유(폴백 로그용).
enum LowLightError: LocalizedError {
    case pixelBuffer(CVReturn)
    case missingOutput
    case badOutputShape([Int])

    var errorDescription: String? {
        switch self {
        case .pixelBuffer(let status): return "입력 버퍼 생성 실패(\(status))"
        case .missingOutput: return "모델 출력(curve) 없음"
        case .badOutputShape(let shape): return "모델 출력 형태 오류 \(shape)"
        }
    }
}

/// 파이프라인 5단계 hook을 만든다(`PipelineContext.lowLightStage`).
enum LowLightStage {
    /// (이미지, 강도 0~1) → 보정 결과.
    static func make(enhancer: LowLightEnhancer) -> (CIImage, Double) -> CIImage {
        { image, strength in enhancer.enhance(image, strength: strength) }
    }
}
