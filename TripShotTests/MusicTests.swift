// 음원·박자(R3-S5) 테스트: YouTube 링크 파싱, 합성 클릭 트랙 박자 검출, 비트 스냅, 칸 길이 bpm 조정, 페이드 구간, 음원 없음 폴백, 음악 포함 조립·내보내기.
import AVFoundation
import CoreImage
import XCTest
@testable import TripShot

final class MusicTests: XCTestCase {

    // MARK: 링크 파싱

    func testVideoIDParsing() {
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://youtu.be/dQw4w9WgXcQ?si=abcDEF123", "dQw4w9WgXcQ"),
            ("https://youtube.com/shorts/abcdefghijk?feature=share", "abcdefghijk"),
            ("https://m.youtube.com/watch?feature=youtu.be&v=A1b2C3d4E5_", "A1b2C3d4E5_"),
            ("  이 노래 좋아요 https://youtu.be/xyz-_123ABC 들어보세요 ", "xyz-_123ABC"),
            ("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM", "dQw4w9WgXcQ"),
            ("https://example.com/watch?v=dQw4w9WgXcQ", nil),
            ("https://notyoutube.com/watch?v=dQw4w9WgXcQ", nil),
            ("https://youtu.be/short", nil),
            ("", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MusicLibrary.videoID(from: input), expected, input)
        }
    }

    // MARK: 박자 검출

    /// 클릭 트랙(짧은 1kHz 감쇠음)을 bpm 간격으로. 첫 클릭은 offset초.
    private func clickTrack(bpm: Double, seconds: Double, sampleRate: Double = BeatDetector.sampleRate,
                            offset: Double = 0.1) -> [Float] {
        let n = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: n)
        let clickLength = Int(0.01 * sampleRate)
        var t = offset
        while t < seconds {
            let start = Int((t * sampleRate).rounded())
            for k in 0..<clickLength where start + k < n {
                let x = Double(k) / sampleRate
                samples[start + k] = Float(sin(2 * .pi * 1000 * x) * exp(-x / 0.003))
            }
            t += 60 / bpm
        }
        return samples
    }

    func testOnsetEnvelopeHasPeaksAtClicks() {
        let samples = clickTrack(bpm: 120, seconds: 4)
        let (env, hop) = BeatDetector.onsetEnvelope(samples: samples, sampleRate: BeatDetector.sampleRate)
        XCTAssertEqual(hop, 512.0 / 22050.0, accuracy: 1e-12)
        XCTAssertEqual(env.count, samples.count / 512 + 1)
        XCTAssertEqual(env.max() ?? 0, 1, accuracy: 1e-6, "최대 1로 정규화")
        // 클릭(0.1, 0.6, 1.1초…) 근처(±2홉)에 봉우리.
        for k in 0..<6 {
            let center = Int(((0.1 + 0.5 * Double(k)) / hop).rounded())
            let window = env[max(center - 2, 0)...min(center + 2, env.count - 1)]
            XCTAssertGreaterThan(window.max() ?? 0, 0.5, "클릭 \(k)")
        }
        XCTAssertTrue(BeatDetector.onsetEnvelope(samples: [], sampleRate: 22050).envelope.isEmpty)
    }

    func testEstimateTempoClickTrack() throws {
        for bpm in [120.0, 90, 128] {
            let (env, hop) = BeatDetector.onsetEnvelope(samples: clickTrack(bpm: bpm, seconds: 20), sampleRate: BeatDetector.sampleRate)
            let estimated = try XCTUnwrap(BeatDetector.estimateTempo(envelope: env, hopSeconds: hop))
            XCTAssertEqual(estimated, bpm, accuracy: 2, "\(bpm)bpm")
        }
        // 무음은 박자 없음.
        let silence = BeatDetector.onsetEnvelope(samples: [Float](repeating: 0, count: 22050 * 5), sampleRate: 22050)
        XCTAssertNil(BeatDetector.estimateTempo(envelope: silence.envelope, hopSeconds: silence.hopSeconds))
    }

    func testBeatTimesClickTrack() throws {
        let (env, hop) = BeatDetector.onsetEnvelope(samples: clickTrack(bpm: 120, seconds: 20), sampleRate: BeatDetector.sampleRate)
        let bpm = try XCTUnwrap(BeatDetector.estimateTempo(envelope: env, hopSeconds: hop))
        XCTAssertGreaterThanOrEqual(bpm, 118)
        XCTAssertLessThanOrEqual(bpm, 122)
        let beats = BeatDetector.beatTimes(envelope: env, hopSeconds: hop, bpm: bpm)
        XCTAssertGreaterThanOrEqual(beats.count, 38)
        XCTAssertEqual(beats[0], 0.1, accuracy: 0.03, "첫 비트 = 첫 클릭")
        for i in 1..<beats.count {
            XCTAssertEqual(beats[i] - beats[i - 1], 0.5, accuracy: 0.03, "비트 간격 \(i)")
        }
    }

    func testExtendBeats() {
        XCTAssertEqual(BeatDetector.extendBeats([0.5, 1.0], bpm: 120, until: 2.1), [0.5, 1.0, 1.5, 2.0])
        XCTAssertEqual(BeatDetector.extendBeats([0.5], bpm: nil, until: 10), [0.5])
        XCTAssertEqual(BeatDetector.extendBeats([], bpm: 120, until: 10), [])
    }

    // MARK: 비트 스냅

    private func cutItems(_ durations: [Double]) -> [TimelineItem] {
        ShortsTimeline.plan(sources: durations.map { (0, 10, $0) }, transition: 0)
    }

    func testSnapMovesBoundariesToBeats() {
        // 비트 0.55초 간격: 경계 1.0 → 1.1, 다음 경계(2.1) → 2.2.
        let beats = (0..<10).map { Double($0) * 0.55 }
        let snapped = ShortsTimeline.snapToBeats(items: cutItems([1, 1, 1]), beats: beats)
        XCTAssertEqual(snapped.map(\.start)[0], 0, accuracy: 1e-9)
        XCTAssertEqual(snapped[1].start, 1.1, accuracy: 1e-9)
        XCTAssertEqual(snapped[2].start, 2.2, accuracy: 1e-9)
        XCTAssertEqual(snapped[0].duration, 1.1, accuracy: 1e-9)
        XCTAssertEqual(snapped[2].duration, 1, accuracy: 1e-9, "마지막 칸 길이는 그대로")
        XCTAssertEqual(snapped.map(\.sourceStart), [0, 0, 0])
    }

    func testSnapIgnoresBeatsOutsideTolerance() {
        let items = cutItems([1, 1, 1])
        let snapped = ShortsTimeline.snapToBeats(items: items, beats: [0, 1.4, 2.8], tolerance: 0.25)
        XCTAssertEqual(snapped, items)
        XCTAssertEqual(ShortsTimeline.snapToBeats(items: items, beats: []), items)
    }

    func testSnapRespectsAvailableAndStartOffsetAndTransition() {
        // 곡 10초부터 사용 → 결과물 비트 1.2, 2.0. 첫 칸은 원본이 1.05초뿐이라 1.05까지만.
        let snapped = ShortsTimeline.snapToBeats(items: cutItems([1, 1, 1]), beats: [10, 11.2, 12.0],
                                                 startOffset: 10, available: [1.05, 10, 10])
        XCTAssertEqual(snapped[1].start, 1.05, accuracy: 1e-9)
        XCTAssertEqual(snapped[2].start, 2.0, accuracy: 1e-9, "두 번째 경계는 2.0 비트로")
        // 전환(0.4초 겹침)은 유지되고 전환 가운데가 비트에 온다.
        let dissolve = ShortsTimeline.plan(sources: [(0, 10, 2), (0, 10, 2)], transition: 0.4)
        let d = ShortsTimeline.snapToBeats(items: dissolve, beats: [2.0])
        XCTAssertEqual(d[0].end - d[1].start, 0.4, accuracy: 1e-9)
        XCTAssertEqual(d[1].start + 0.2, 2.0, accuracy: 1e-9)
    }

    func testShouldSnap() {
        XCTAssertTrue(ShortsTimeline.shouldSnap(templateBPM: 120, musicBPM: 100))
        XCTAssertTrue(ShortsTimeline.shouldSnap(templateBPM: 120, musicBPM: 144))
        XCTAssertFalse(ShortsTimeline.shouldSnap(templateBPM: 120, musicBPM: 90))
        XCTAssertFalse(ShortsTimeline.shouldSnap(templateBPM: nil, musicBPM: 120))
        XCTAssertFalse(ShortsTimeline.shouldSnap(templateBPM: 120, musicBPM: nil))
    }

    func testSlotSecondsAdjusted() throws {
        let beatCut = try XCTUnwrap(ShortsTemplateLibrary.template(for: "beatCut"))
        XCTAssertEqual(beatCut.slotSecondsAdjusted(forBPM: 120), Array(repeating: 1.0, count: 10))
        let at100 = beatCut.slotSecondsAdjusted(forBPM: 100)
        XCTAssertEqual(at100[0], 1.2, accuracy: 1e-9, "2박 = 2 × 0.6초")
        let noBPM = try XCTUnwrap(ShortsTemplateLibrary.template(for: "walkTeleport"))
        XCTAssertEqual(noBPM.slotSecondsAdjusted(forBPM: 90), noBPM.slots.map(\.seconds), "권장 박자 없는 템플릿은 그대로")
    }

    // MARK: 음악 구간·페이드·폴백

    func testFadeRange() {
        let a = MusicSelection.fadeRange(total: 12, fade: 1.5)
        XCTAssertEqual(a.start, 10.5, accuracy: 1e-9)
        XCTAssertEqual(a.duration, 1.5, accuracy: 1e-9)
        let b = MusicSelection.fadeRange(total: 1, fade: 1.5)
        XCTAssertEqual(b.start, 0, accuracy: 1e-9)
        XCTAssertEqual(b.duration, 1, accuracy: 1e-9)
    }

    func testMusicSpan() {
        let full = MusicSelection.span(total: 10, musicDuration: 180, start: 30)
        XCTAssertEqual(full.start, 30); XCTAssertEqual(full.duration, 10)
        let short = MusicSelection.span(total: 10, musicDuration: 34, start: 30)
        XCTAssertEqual(short.duration, 4, accuracy: 1e-9, "곡이 짧으면 곡 끝까지(반복 없음)")
        let clamped = MusicSelection.span(total: 10, musicDuration: 20, start: -5)
        XCTAssertEqual(clamped.start, 0)
    }

    func testMusicAvailability() {
        let id = UUID()
        XCTAssertEqual(MusicLibrary.availability(trackID: nil, trackExists: false, fileExists: false), .none)
        XCTAssertEqual(MusicLibrary.availability(trackID: id, trackExists: true, fileExists: true), .available)
        XCTAssertEqual(MusicLibrary.availability(trackID: id, trackExists: true, fileExists: false), .missing, "파일 삭제됨")
        XCTAssertEqual(MusicLibrary.availability(trackID: id, trackExists: false, fileExists: false), .missing, "레코드 삭제됨")
        XCTAssertFalse(UserMessage.text(for: MusicImportError.extractionFailed).isEmpty)
        XCTAssertTrue(UserMessage.text(for: MusicImportError.extractionFailed).contains("파일 앱"))
    }

    func testMusicTrackBeatsRoundTrip() {
        let track = MusicTrack(title: "t", fileName: "t.m4a", durationSeconds: 10, sourceURL: nil)
        XCTAssertEqual(track.beats, [])
        track.beats = [0.5, 1.0]
        XCTAssertEqual(track.beats, [0.5, 1.0])
        XCTAssertFalse(track.isFromYouTube)
    }

    // MARK: 실제 파일 (AVAssetReader·조립)

    /// 120bpm 클릭 트랙 m4a(AAC 44.1kHz) 파일.
    private func makeClickFile(bpm: Double = 120, seconds: Double = 10) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("click-\(UUID().uuidString).m4a")
        let rate = 44100.0
        let samples = clickTrack(bpm: bpm, seconds: seconds, sampleRate: rate)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<samples.count { channel[i] = samples[i] * 0.8 }
        // 파일은 이 스코프를 벗어나며 닫힌다.
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
            ])
            try file.write(from: buffer)
        }
        return url
    }

    func testAnalyzeFileWithAssetReader() async throws {
        let url = try makeClickFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await BeatDetector.analyze(url: url)
        let bpm = try XCTUnwrap(result.bpm)
        XCTAssertEqual(bpm, 120, accuracy: 2)
        XCTAssertGreaterThan(result.beats.count, 15)
        let info = try await MusicLibrary.loadInfo(url: url)
        XCTAssertEqual(info.duration, 10, accuracy: 0.2)
    }

    /// 단색 영상(음성 없음).
    private func makeClip(_ color: CIColor, seconds: Double) async throws -> URL {
        let url = VideoRecorder.temporaryURL()
        let recorder = try VideoRecorder(url: url, unmirror: false, withAudio: false)
        for i in 0..<Int(seconds * 30) {
            recorder.appendVideo(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 540, height: 960)),
                                 time: CMTime(value: CMTimeValue(i), timescale: 30))
            try await Task.sleep(for: .milliseconds(34))
        }
        let out = await recorder.finish()
        return try XCTUnwrap(out)
    }

    /// 완료 기준: 음악 포함 쇼츠 — 비트 맞춤(템플릿 120bpm, 음악 100bpm → 칸 1.2초)으로 조립하고 내보낸 파일에 소리 트랙이 있다.
    func testAssembleWithMusicAndBeatAlign() async throws {
        let music = try makeClickFile(bpm: 100, seconds: 12)
        let clips = [try await makeClip(.red, seconds: 1.6), try await makeClip(.green, seconds: 1.6), try await makeClip(.blue, seconds: 1.6)]
        defer { ([music] + clips).forEach { try? FileManager.default.removeItem(at: $0) } }
        let template = ShortsTemplate(
            id: "beatTest", name: "비트 테스트", summary: "", symbol: "metronome",
            slots: (0..<3).map { SlotSpec(index: $0, title: "\($0)", instruction: "x", seconds: 1.0, guide: SlotGuide()) },
            transition: .cut, beatsPerMinute: 120)
        var sources: [AssemblySource] = []
        for url in clips {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            sources.append(AssemblySource(asset: asset, start: 0, end: duration))
        }
        let beats = (0..<20).map { Double($0) * 0.6 }
        let selection = MusicSelection(fileURL: music, startSeconds: 0, beats: beats, bpm: 100, alignToBeats: true)
        let (composition, videoComposition, audioMix) = try await ShortsAssembler.build(
            template: template, sources: sources, keepOriginalAudio: false, music: selection)
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 2)
        XCTAssertEqual(audioTracks.count, 1, "음악 트랙 하나")
        XCTAssertEqual(audioMix?.inputParameters.count, 1)
        let total = try await composition.load(.duration).seconds
        XCTAssertEqual(total, 3.6, accuracy: 0.05, "칸 3 × 1.2초(100bpm 2박)")

        let out = try await ShortsAssembler.export(composition: composition, videoComposition: videoComposition,
                                                   audioMix: audioMix) { _ in }
        defer { try? FileManager.default.removeItem(at: out) }
        let result = AVURLAsset(url: out)
        let outAudio = try await result.loadTracks(withMediaType: .audio)
        XCTAssertFalse(outAudio.isEmpty, "내보낸 쇼츠에 음악")
        let outDuration = try await result.load(.duration).seconds
        XCTAssertEqual(outDuration, 3.6, accuracy: 0.15)
    }

    func testBuildWithMissingMusicThrows() async throws {
        let clip = try await makeClip(.red, seconds: 1.2)
        defer { try? FileManager.default.removeItem(at: clip) }
        let template = ShortsTemplate(
            id: "t", name: "t", summary: "", symbol: "film",
            slots: [SlotSpec(index: 0, title: "0", instruction: "x", seconds: 1, guide: SlotGuide())],
            transition: .cut, beatsPerMinute: nil)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("없음-\(UUID().uuidString).m4a")
        do {
            _ = try await ShortsAssembler.build(template: template, sources: [AssemblySource(asset: AVURLAsset(url: clip), start: 0, end: 1)],
                                                keepOriginalAudio: false, music: MusicSelection(fileURL: missing, startSeconds: 0))
            XCTFail("음악 파일이 없으면 musicUnavailable")
        } catch ShortsAssemblyError.musicUnavailable {
            // 기대한 오류
        }
    }
}
