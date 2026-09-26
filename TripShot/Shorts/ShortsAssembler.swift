// 쇼츠 조립(R3-S4·S5): 칸 영상들을 템플릿 길이로 잘라 이어 붙이고(음악 박자에 컷 맞춤), 칸 사이 전환을 자체 합성기(Core Image)로 그리고, 음악(끝 페이드아웃)을 얹어 1080×1920으로 내보낸다.
import AVFoundation
import CoreImage
import Foundation
import Metal
import Photos

// MARK: - 타임라인 (순수 계산, 테스트 대상)

/// 조립 계획에서 칸 하나.
struct TimelineItem: Equatable {
    /// 결과물에서 시작 시각(초).
    var start: Double
    /// 결과물에서 차지하는 길이(초).
    var duration: Double
    /// 원본 영상에서 가져올 시작 지점(초).
    var sourceStart: Double
    /// 두 영상 트랙 중 어느 쪽(0/1, 전환이 겹치도록 번갈아).
    var track: Int

    var end: Double { start + duration }
}

enum ShortsTimeline {
    /// 칸별 (원본 시작, 쓸 수 있는 길이, 칸 길이) → 결과물 배치. 쓸 수 있는 길이가 칸보다 짧으면 그만큼만.
    /// 전환 길이 T만큼 앞 칸과 겹친다(컷이면 0). 전환이 칸보다 길면 칸 길이의 절반으로 줄인다.
    static func plan(sources: [(start: Double, available: Double, slotSeconds: Double)], transition: Double) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var cursor = 0.0
        for (i, s) in sources.enumerated() {
            let duration = max(min(s.available, s.slotSeconds), 0.1)
            if i > 0 {
                let overlap = min(transition, duration / 2, items[i - 1].duration / 2)
                cursor -= overlap
            }
            items.append(TimelineItem(start: cursor, duration: duration, sourceStart: s.start, track: i % 2))
            cursor += duration
        }
        return items
    }

    /// 결과물 전체 길이.
    static func totalDuration(_ items: [TimelineItem]) -> Double { items.last?.end ?? 0 }

    /// 비트 컷 맞춤 허용 폭(초).
    static let beatTolerance: Double = 0.25
    /// 템플릿 권장 bpm과 음악 bpm이 이 비율 안이면 맞춘다.
    static let bpmMatchRatio: Double = 0.2

    /// 템플릿에 권장 bpm이 있고 음악 bpm이 그 ±20% 안이면 비트에 맞춘다.
    static func shouldSnap(templateBPM: Double?, musicBPM: Double?) -> Bool {
        guard let t = templateBPM, let m = musicBPM, t > 0, m > 0 else { return false }
        return abs(m - t) / t <= bpmMatchRatio
    }

    /// 칸 경계(컷 시각 = 전환 구간 가운데)를 가장 가까운 비트(±tolerance)로 옮긴다.
    /// 앞 칸 길이를 늘리거나 줄여 맞추고 뒤 칸들은 그만큼 민다 — 전환 길이(겹침)는 그대로.
    /// 앞 칸 길이는 `available`(원본에서 쓸 수 있는 길이) 이하, 앞뒤 전환 겹침 합 이상으로만 바꾼다.
    /// - Parameters:
    ///   - beats: 곡 기준 비트 시각(초).
    ///   - startOffset: 곡에서 음악을 시작하는 지점(초). 결과물 시각 = 비트 − startOffset.
    ///   - available: 칸별 쓸 수 있는 원본 길이. nil이면 제한 없음.
    static func snapToBeats(items: [TimelineItem], beats: [Double], startOffset: Double = 0,
                            tolerance: Double = beatTolerance, available: [Double]? = nil) -> [TimelineItem] {
        guard items.count > 1, !beats.isEmpty else { return items }
        let outputBeats = beats.map { $0 - startOffset }.filter { $0 > 0 }.sorted()
        guard !outputBeats.isEmpty else { return items }
        var result = items
        for i in 0..<(result.count - 1) {
            let overlap = max(result[i].end - result[i + 1].start, 0)
            let boundary = result[i + 1].start + overlap / 2
            guard let beat = nearest(outputBeats, to: boundary), abs(beat - boundary) <= tolerance else { continue }
            let prevOverlap = i > 0 ? max(result[i - 1].end - result[i].start, 0) : 0
            let lower = max(prevOverlap + overlap, 0.1)
            var upper = Double.infinity
            if let available, i < available.count { upper = available[i] }
            guard upper >= lower else { continue }
            let newDuration = min(max(result[i].duration + (beat - boundary), lower), upper)
            let delta = newDuration - result[i].duration
            guard abs(delta) > 1e-9 else { continue }
            result[i].duration = newDuration
            for j in (i + 1)..<result.count { result[j].start += delta }
        }
        return result
    }

    /// 정렬된 배열에서 x에 가장 가까운 값.
    static func nearest(_ sorted: [Double], to x: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(sorted[lo - 1] - x) <= abs(sorted[lo] - x) { return sorted[lo - 1] }
        return sorted[lo]
    }
}

// MARK: - 음악 선택

/// 조립에 얹을 음악. `fileURL`은 Music/ 폴더의 파일.
struct MusicSelection: Equatable {
    var fileURL: URL
    /// 곡에서 시작 지점(초).
    var startSeconds: Double
    /// 끝 페이드아웃 길이(초).
    var fadeOutSeconds: Double = 1.5
    var volume: Float = 1.0
    /// 원래 소리 켬일 때 영상 소리를 이만큼으로 낮춘다(더킹).
    var originalVolume: Float = 0.3
    /// 곡 기준 비트 시각(초). 비트 맞춤에 쓴다.
    var beats: [Double] = []
    /// 곡 bpm(검출 값).
    var bpm: Double? = nil
    /// 칸 경계를 비트에 맞출지(사용자 토글). 템플릿 bpm과 맞을 때만 실제로 맞춘다.
    var alignToBeats: Bool = false

    /// 끝 페이드 구간: 길이 total인 음악의 마지막 fade초(음악보다 길면 음악 전체).
    static func fadeRange(total: Double, fade: Double) -> (start: Double, duration: Double) {
        let total = max(total, 0)
        let duration = min(max(fade, 0), total)
        return (total - duration, duration)
    }

    /// 곡에서 가져올 구간: 시작 지점을 곡 안으로 맞추고, 결과물 길이만큼(곡이 짧으면 곡 끝까지, 반복 없음).
    static func span(total: Double, musicDuration: Double, start: Double) -> (start: Double, duration: Double) {
        guard musicDuration > 0, total > 0 else { return (0, 0) }
        let s = min(max(start, 0), max(musicDuration - 0.1, 0))
        return (s, max(min(total, musicDuration - s), 0))
    }
}

// MARK: - 합성기 지시

/// 한 구간의 합성 지시: 한 트랙 그대로 또는 두 트랙 사이 전환.
final class ShortsInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let fromTrack: CMPersistentTrackID
    let toTrack: CMPersistentTrackID?
    let transition: ShortsTransition
    /// 트랙별 원본 방향 변환(preferredTransform).
    let transforms: [CMPersistentTrackID: CGAffineTransform]

    init(timeRange: CMTimeRange, fromTrack: CMPersistentTrackID, toTrack: CMPersistentTrackID?,
         transition: ShortsTransition, transforms: [CMPersistentTrackID: CGAffineTransform]) {
        self.timeRange = timeRange
        self.fromTrack = fromTrack
        self.toTrack = toTrack
        self.transition = transition
        self.transforms = transforms
        var ids = [NSNumber(value: fromTrack)]
        if let toTrack { ids.append(NSNumber(value: toTrack)) }
        requiredSourceTrackIDs = ids
    }
}

/// 두 트랙 프레임을 Core Image로 합성한다. AVFoundation이 내부 큐에서 부른다.
final class ShortsCompositor: NSObject, AVVideoCompositing {
    static let renderSize = CGSize(width: 1080, height: 1920)

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
        return CIContext()
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ShortsInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "TripShot.Shorts", code: 1))
            return
        }
        func frame(_ track: CMPersistentTrackID) -> CIImage? {
            guard let buffer = request.sourceFrame(byTrackID: track) else { return nil }
            let raw = CIImage(cvPixelBuffer: buffer)
            return Self.fill(raw, transform: instruction.transforms[track] ?? .identity)
        }
        let size = Self.renderSize
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        var image = frame(instruction.fromTrack) ?? black
        if let to = instruction.toTrack, let next = frame(to) {
            let t = CMTimeGetSeconds(request.compositionTime - instruction.timeRange.start)
                / max(CMTimeGetSeconds(instruction.timeRange.duration), 0.001)
            image = ShortsTransitionRenderer.blend(from: image, to: next, progress: min(max(t, 0), 1),
                                                   kind: instruction.transition, size: size)
        }
        ciContext.render(image.composited(over: black), to: output, bounds: CGRect(origin: .zero, size: size),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: output)
    }

    /// 원본 프레임(센서 방향) → 방향 맞춤 → 1080×1920을 가득 채우게(넘치는 쪽 잘림) 가운데 정렬.
    static func fill(_ raw: CIImage, transform: CGAffineTransform) -> CIImage {
        // preferredTransform은 좌상단 원점 기준이라 Core Image(좌하단)에 맞게 y를 뒤집어 적용한다.
        let h = raw.extent.height
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        var img = raw.transformed(by: flip.concatenating(transform))
        let e0 = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e0.minX, y: -e0.minY))
        let flippedBack = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: img.extent.height)
        img = img.transformed(by: flippedBack)
        let e = img.extent
        let size = renderSize
        let scale = max(size.width / e.width, size.height / e.height)
        let t = CGAffineTransform(translationX: (size.width - e.width * scale) / 2, y: (size.height - e.height * scale) / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -e.minX, y: -e.minY)
        return img.transformed(by: t).cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// 전환 그리기(순수 CI 그래프).
enum ShortsTransitionRenderer {
    static func blend(from a: CIImage, to b: CIImage, progress p: Double, kind: ShortsTransition, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let ease = p * p * (3 - 2 * p)
        switch kind {
        case .cut:
            return p < 0.5 ? a : b
        case .dissolve:
            return fade(b, alpha: ease).composited(over: a).cropped(to: rect)
        case .whipRight:
            // 앞 장면은 왼쪽으로, 다음 장면은 오른쪽에서 밀려 들어오며 가로 흔들림 블러.
            let dx = size.width * CGFloat(ease)
            let blur = CGFloat(sin(p * .pi)) * size.width * 0.06
            let moving = b.transformed(by: CGAffineTransform(translationX: size.width - dx, y: 0))
                .composited(over: a.transformed(by: CGAffineTransform(translationX: -dx, y: 0)))
            return motionBlur(moving, radius: blur).cropped(to: rect)
        case .zoomIn:
            // 앞 장면을 가운데로 확대하며 흐리게, 다음 장면이 겹쳐 나타남.
            let s = 1 + CGFloat(ease) * 1.5
            let zoomed = a.transformed(by: CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: s, y: s).translatedBy(x: -size.width / 2, y: -size.height / 2))
            return fade(b, alpha: ease).composited(over: zoomed).cropped(to: rect)
        case .spin:
            // 앞 장면은 시계 방향으로 돌며 커지고, 다음 장면은 반대편에서 돌아 들어온다(회전 블러 대신 줌 블러).
            let c = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            func turned(_ img: CIImage, angle: CGFloat, scale: CGFloat) -> CIImage {
                img.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                    .concatenating(CGAffineTransform(rotationAngle: angle)).concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(c))
            }
            let a1 = turned(a, angle: -CGFloat(ease) * .pi / 2, scale: 1 + CGFloat(ease) * 0.6)
            let b1 = turned(b, angle: CGFloat(1 - ease) * .pi / 2, scale: 1.6 - CGFloat(ease) * 0.6)
            let mixed = fade(b1, alpha: ease).composited(over: a1)
            let blur = CGFloat(sin(p * .pi)) * 18
            guard blur > 0.5 else { return mixed.cropped(to: rect) }
            return mixed.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2), "inputAmount": blur,
            ]).cropped(to: rect)
        case .slideUp:
            let dy = size.height * CGFloat(ease)
            let moving = b.transformed(by: CGAffineTransform(translationX: 0, y: -size.height + dy))
                .composited(over: a.transformed(by: CGAffineTransform(translationX: 0, y: dy)))
            return motionBlur(moving, radius: CGFloat(sin(p * .pi)) * size.height * 0.03, angle: .pi / 2).cropped(to: rect)
        }
    }

    static func fade(_ image: CIImage, alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
    }

    static func motionBlur(_ image: CIImage, radius: CGFloat, angle: CGFloat = 0) -> CIImage {
        guard radius > 0.5 else { return image }
        return image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angle])
    }
}

// MARK: - 조립기

enum ShortsAssemblyError: LocalizedError {
    case missingClip(Int)
    case assetUnavailable(Int)
    case noVideoTrack(Int)
    case exportFailed(String)
    /// 고른 음악 파일을 열 수 없음(삭제·손상) → 화면이 음악 없이 다시 조립한다.
    case musicUnavailable

    var errorDescription: String? {
        switch self {
        case .missingClip(let i): return "\(i + 1)번 칸이 비어 있습니다."
        case .assetUnavailable(let i): return "\(i + 1)번 칸 영상을 불러오지 못했습니다(삭제됐거나 iCloud에서 받는 중)."
        case .noVideoTrack(let i): return "\(i + 1)번 칸에 영상 트랙이 없습니다."
        case .exportFailed(let s): return "내보내기 실패: \(s)"
        case .musicUnavailable: return UserMessage.musicMissing
        }
    }
}

/// 조립 입력: 칸 순서대로 (원본 영상, 쓸 구간).
struct AssemblySource {
    var asset: AVAsset
    var start: Double
    var end: Double
}

enum ShortsAssembler {
    /// 컴포지션·합성 지시를 만든다(내보내기와 미리보기에서 함께 쓴다). 음악 없음.
    static func build(template: ShortsTemplate, sources: [AssemblySource], keepOriginalAudio: Bool)
    async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        try await build(template: template, sources: sources, keepOriginalAudio: keepOriginalAudio, music: nil)
    }

    /// 음악 포함 조립. 음악이 있으면 원래 소리는 `originalVolume`으로 낮추고, 음악은 끝 `fadeOutSeconds` 동안 1→0.
    /// 비트 맞춤(`alignToBeats` + 템플릿 bpm과 20% 이내)이면 칸 길이를 음악 bpm으로 다시 계산하고 경계를 비트로 스냅한다.
    /// 음악 파일에 오디오 트랙이 없으면 `ShortsAssemblyError.musicUnavailable`.
    static func build(template: ShortsTemplate, sources: [AssemblySource], keepOriginalAudio: Bool, music: MusicSelection?)
    async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        // 음악 트랙은 컴포지션을 만지기 전에 확인한다(없으면 화면이 음악 없이 다시 부른다).
        var musicSource: (track: AVAssetTrack, duration: Double)?
        if let music {
            let asset = AVURLAsset(url: music.fileURL)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
                throw ShortsAssemblyError.musicUnavailable
            }
            musicSource = (track, duration)
        }
        let snapBPM: Double? = {
            guard let music, music.alignToBeats,
                  ShortsTimeline.shouldSnap(templateBPM: template.beatsPerMinute, musicBPM: music.bpm) else { return nil }
            return music.bpm
        }()
        let slotLengths = snapBPM.map { template.slotSecondsAdjusted(forBPM: $0) } ?? template.slots.map(\.seconds)

        let composition = AVMutableComposition()
        guard let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ShortsAssemblyError.exportFailed("트랙 생성")
        }
        let videoTracks = [trackA, trackB]
        let audioTracks = keepOriginalAudio
            ? [composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
               composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)]
            : []

        var plans: [(start: Double, available: Double, slotSeconds: Double)] = []
        for (i, source) in sources.enumerated() {
            let slotSeconds = i < slotLengths.count ? slotLengths[i] : source.end - source.start
            plans.append((source.start, max(source.end - source.start, 0.1), slotSeconds))
        }
        var items = ShortsTimeline.plan(sources: plans, transition: template.transition.duration)
        if snapBPM != nil, let music, !music.beats.isEmpty {
            items = ShortsTimeline.snapToBeats(items: items, beats: music.beats, startOffset: music.startSeconds,
                                               available: plans.map { $0.available })
        }

        var transforms: [CMPersistentTrackID: CGAffineTransform] = [:]
        let timescale: CMTimeScale = 600
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

        for (i, item) in items.enumerated() {
            let asset = sources[i].asset
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw ShortsAssemblyError.noVideoTrack(i)
            }
            let range = CMTimeRange(start: time(item.sourceStart), duration: time(item.duration))
            let target = videoTracks[item.track]
            try target.insertTimeRange(range, of: sourceVideo, at: time(item.start))
            // 칸마다 방향이 다를 수 있지만 트랙당 변환은 하나라 트랙 변환 대신 지시에 칸별로 넘긴다(아래).
            transforms[target.trackID] = try await sourceVideo.load(.preferredTransform)
            if keepOriginalAudio, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTarget = audioTracks[item.track] {
                try? audioTarget.insertTimeRange(range, of: sourceAudio, at: time(item.start))
            }
        }

        // 합성 지시: 칸 단독 구간 + 전환 구간.
        var instructions: [ShortsInstruction] = []
        var itemTransforms: [[CMPersistentTrackID: CGAffineTransform]] = []
        for (i, item) in items.enumerated() {
            let tid = videoTracks[item.track].trackID
            let t = try await sources[i].asset.loadTracks(withMediaType: .video).first?.load(.preferredTransform) ?? .identity
            itemTransforms.append([tid: t])
        }
        for (i, item) in items.enumerated() {
            let tid = videoTracks[item.track].trackID
            let soloStart = i > 0 ? items[i - 1].end : item.start
            let soloEnd = i + 1 < items.count ? items[i + 1].start : item.end
            if soloEnd > soloStart {
                instructions.append(ShortsInstruction(timeRange: CMTimeRange(start: time(soloStart), end: time(soloEnd)),
                                                      fromTrack: tid, toTrack: nil, transition: template.transition,
                                                      transforms: itemTransforms[i]))
            }
            if i + 1 < items.count, items[i + 1].start < item.end {
                let nextID = videoTracks[items[i + 1].track].trackID
                var both = itemTransforms[i]
                both.merge(itemTransforms[i + 1]) { _, new in new }
                instructions.append(ShortsInstruction(timeRange: CMTimeRange(start: time(items[i + 1].start), end: time(item.end)),
                                                      fromTrack: tid, toTrack: nextID, transition: template.transition,
                                                      transforms: both))
            }
        }
        _ = transforms

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ShortsCompositor.self
        videoComposition.renderSize = ShortsCompositor.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        // 오디오 믹스: 원래 소리(음악이 있으면 더킹) + 음악(끝 페이드아웃).
        var parameters: [AVMutableAudioMixInputParameters] = []
        if keepOriginalAudio {
            let originalVolume: Float = music?.originalVolume ?? 1
            parameters += audioTracks.compactMap { $0 }.map { track in
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(originalVolume, at: .zero)
                return p
            }
        }
        if let music, let musicSource {
            let total = ShortsTimeline.totalDuration(items)
            let span = MusicSelection.span(total: total, musicDuration: musicSource.duration, start: music.startSeconds)
            if span.duration > 0.05,
               let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try musicTrack.insertTimeRange(CMTimeRange(start: time(span.start), duration: time(span.duration)),
                                               of: musicSource.track, at: .zero)
                let p = AVMutableAudioMixInputParameters(track: musicTrack)
                p.setVolume(music.volume, at: .zero)
                let fade = MusicSelection.fadeRange(total: span.duration, fade: music.fadeOutSeconds)
                if fade.duration > 0 {
                    p.setVolumeRamp(fromStartVolume: music.volume, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: time(fade.start), duration: time(fade.duration)))
                }
                parameters.append(p)
            }
        }
        var audioMix: AVAudioMix?
        if !parameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            audioMix = mix
        }
        return (composition, videoComposition, audioMix)
    }

    /// 내보내기 → 임시 .mov. 진행률(0~1)을 알려 준다.
    static func export(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, audioMix: AVAudioMix?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shorts-\(UUID().uuidString).mov")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw ShortsAssemblyError.exportFailed("내보내기 세션")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        do {
            try await session.export(to: url, as: .mov)
        } catch {
            throw ShortsAssemblyError.exportFailed(error.localizedDescription)
        }
        progress(1)
        return url
    }

    /// 사진 보관함 에셋 → AVAsset(iCloud 받기 허용).
    static func loadAsset(localID: String) async -> AVAsset? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        return await withCheckedContinuation { cont in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in cont.resume(returning: av) }
        }
    }
}
