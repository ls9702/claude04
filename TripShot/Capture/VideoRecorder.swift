// 영상 녹화(R3-S1): 라이브 보정이 끝난 프레임(CIImage)을 1080×1920 HEVC로, 마이크 소리를 AAC로 기록한다("보이는 대로 굽기").
import AVFoundation
import CoreImage
import Foundation
import Metal

/// 한 번의 녹화. `appendVideo`는 비디오 큐, `appendAudio`는 오디오 큐에서 불린다(내부 잠금으로 순서 보호).
final class VideoRecorder: @unchecked Sendable {
    /// 출력 크기(세로 9:16).
    static let outputSize = CGSize(width: 1080, height: 1920)
    static let videoBitRate = 12_000_000

    let url: URL
    /// 전면 카메라 프레임은 프리뷰용으로 좌우 반전돼 오므로 저장할 때 되돌린다(사진과 같은 규칙).
    let unmirror: Bool

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let ciContext: CIContext
    private let lock = NSLock()
    private var sessionStarted = false
    /// 오디오 입력을 writer에 붙였는지. 붙이지 않은 입력에 markAsFinished를 부르면 예외로 앱이 죽는다.
    private let hasAudio: Bool
    private var finished = false
    private var firstTime: CMTime = .invalid
    private var lastVideoTime: CMTime = .invalid
    private(set) var framesWritten = 0

    init(url: URL, unmirror: Bool, withAudio: Bool = true) throws {
        self.url = url
        self.unmirror = unmirror
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let size = Self.outputSize
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(videoInput)
        if withAudio, writer.canAdd(audioInput) {
            writer.add(audioInput)
            hasAudio = true
        } else {
            hasAudio = false
        }

        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: EnhanceRenderer.workingColorSpace, .cacheIntermediates: false,
            ])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// 녹화된 길이(초).
    var duration: Double {
        lock.withLock {
            guard firstTime.isValid, lastVideoTime.isValid else { return 0 }
            return (lastVideoTime - firstTime).seconds
        }
    }

    /// 보정된 프레임 하나. 출력 크기(9:16)에 가득 차게 가운데를 맞춘다.
    func appendVideo(_ image: CIImage, time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
            firstTime = time
        }
        // 같은 시각이 두 번 오면 인코더가 거부하므로 건너뛴다.
        if lastVideoTime.isValid, time <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        ciContext.render(Self.fitted(image, unmirror: unmirror), to: buffer,
                         bounds: CGRect(origin: .zero, size: Self.outputSize),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if adaptor.append(buffer, withPresentationTime: time) {
            lastVideoTime = time
            framesWritten += 1
        }
    }

    /// 마이크 소리. 첫 영상 프레임 전의 소리는 버린다(세션 시작 시각 이전).
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard hasAudio, !finished, sessionStarted, writer.status == .writing,
              CMSampleBufferGetPresentationTimeStamp(sample) >= firstTime,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    /// 녹화를 끝내고 파일을 닫는다. 한 프레임도 없으면 nil.
    func finish() async -> URL? {
        let hasFrames: Bool = lock.withLock {
            finished = true
            return framesWritten > 0
        }
        guard hasFrames, writer.status == .writing else {
            writer.cancelWriting()
            return nil
        }
        videoInput.markAsFinished()
        if hasAudio { audioInput.markAsFinished() }
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    /// 9:16 출력에 가득 차게(넘치는 쪽 잘림) 가운데 정렬, 원점 (0,0). 필요하면 좌우 반전.
    static func fitted(_ image: CIImage, unmirror: Bool) -> CIImage {
        var img = image
        let e = img.extent
        if unmirror {
            img = img.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * e.midX, ty: 0))
        }
        let size = outputSize
        let scale = max(size.width / e.width, size.height / e.height)
        let w = e.width * scale, h = e.height * scale
        let t = CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -e.minX, y: -e.minY)
        return img.transformed(by: t).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 임시 파일 위치(녹화마다 새 이름).
    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).mov")
    }
}
