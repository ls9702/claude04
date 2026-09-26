// 쇼츠(R3-S2~S4) 테스트: 템플릿 10개 구성, 타임라인(전환 겹침), 칸 구간, 가이드 좌표, 합성 조립·내보내기(실제 파일).
import AVFoundation
import CoreImage
import XCTest
@testable import TripShot

final class ShortsTests: XCTestCase {

    // MARK: 템플릿

    func testTenTemplates() {
        let all = ShortsTemplateLibrary.all
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(Set(all.map(\.id)).count, 10, "키 중복 없음")
        for t in all {
            XCTAssertFalse(t.slots.isEmpty, t.id)
            XCTAssertEqual(t.slots.map(\.index), Array(0..<t.slots.count), "\(t.id) 칸 번호 연속")
            XCTAssertTrue(t.slots.allSatisfy { $0.seconds > 0 && !$0.instruction.isEmpty }, t.id)
            XCTAssertGreaterThan(t.totalSeconds, 5, t.id)
            XCTAssertLessThan(t.totalSeconds, 40, t.id)
            // 첫 칸은 앞 장면 겹쳐 보기가 없다(앞 칸이 없으므로).
            XCTAssertFalse(t.slots[0].guide.ghostPrevious, t.id)
        }
        XCTAssertEqual(ShortsTemplateLibrary.template(for: "walkTeleport")?.slots.count, 5)
        XCTAssertNil(ShortsTemplateLibrary.template(for: "없음"))
    }

    // MARK: 타임라인

    func testTimelineCutHasNoOverlap() {
        let items = ShortsTimeline.plan(sources: [(0, 10, 3), (1, 10, 4), (0, 2, 3)], transition: 0)
        XCTAssertEqual(items.map(\.start), [0, 3, 7])
        XCTAssertEqual(items.map(\.duration), [3, 4, 2], "짧은 영상은 가진 만큼만")
        XCTAssertEqual(items.map(\.track), [0, 1, 0])
        XCTAssertEqual(items[1].sourceStart, 1)
        XCTAssertEqual(ShortsTimeline.totalDuration(items), 9)
    }

    func testTimelineTransitionOverlaps() {
        let items = ShortsTimeline.plan(sources: [(0, 10, 3), (0, 10, 3), (0, 10, 3)], transition: 0.4)
        XCTAssertEqual(items[1].start, 2.6, accuracy: 1e-9)
        XCTAssertEqual(items[2].start, 5.2, accuracy: 1e-9)
        XCTAssertEqual(ShortsTimeline.totalDuration(items), 8.2, accuracy: 1e-9)
        // 전환이 칸의 절반보다 길면 줄인다.
        let short = ShortsTimeline.plan(sources: [(0, 10, 0.4), (0, 10, 0.4)], transition: 0.4)
        XCTAssertEqual(short[1].start, 0.2, accuracy: 1e-9)
    }

    func testTemplateTotalMatchesTimeline() {
        for t in ShortsTemplateLibrary.all {
            let items = ShortsTimeline.plan(sources: t.slots.map { (0, 100, $0.seconds) }, transition: t.transition.duration)
            XCTAssertEqual(ShortsTimeline.totalDuration(items), t.totalSeconds, accuracy: 1e-6, t.id)
        }
    }

    // MARK: 칸 구간

    func testClipRange() {
        XCTAssertEqual(ClipRange.initial(assetDuration: 10, slotSeconds: 3), 0...3)
        XCTAssertEqual(ClipRange.initial(assetDuration: 2, slotSeconds: 3), 0...2)
        XCTAssertEqual(ClipRange.initial(assetDuration: 4.5, slotSeconds: 3.5, skipLead: 0.3), 0.3...3.8)
        XCTAssertEqual(ClipRange.initial(assetDuration: 3.6, slotSeconds: 3.5, skipLead: 0.3), 0...3.5, "여유가 없으면 앞을 건너뛰지 않는다")
    }

    // MARK: 가이드

    func testSilhouetteRect() {
        let guide = SlotGuide(silhouette: .standing, silhouetteX: 0.5, silhouetteFootY: 0.9, silhouetteHeight: 0.5)
        let r = SlotGuideGeometry.silhouetteRect(guide: guide, in: CGSize(width: 400, height: 800))
        XCTAssertEqual(r.maxY, 720, accuracy: 1e-9, "발끝")
        XCTAssertEqual(r.height, 400, accuracy: 1e-9)
        XCTAssertEqual(r.midX, 200, accuracy: 1e-9)
        XCTAssertEqual(r.width, 168, accuracy: 1e-9)
        XCTAssertEqual(SlotCaptureView.recordSeconds(for: SlotSpec(index: 0, title: "", instruction: "", seconds: 3, guide: SlotGuide())),
                       3 + SlotCaptureTiming.leadIn + SlotCaptureTiming.tail, accuracy: 1e-9)
    }

    // MARK: 조립

    /// 단색 영상 파일(1초) 만들기.
    private func makeClip(_ color: CIColor, seconds: Double = 1.2) async throws -> URL {
        let url = VideoRecorder.temporaryURL()
        let recorder = try VideoRecorder(url: url, unmirror: false, withAudio: false)
        let frames = Int(seconds * 30)
        for i in 0..<frames {
            recorder.appendVideo(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 540, height: 960)),
                                 time: CMTime(value: CMTimeValue(i), timescale: 30))
            try await Task.sleep(for: .milliseconds(34))
        }
        let out = await recorder.finish()
        return try XCTUnwrap(out)
    }

    func testAssembleAndExportWithDissolve() async throws {
        let urls = [try await makeClip(.red), try await makeClip(.green), try await makeClip(.blue)]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let template = ShortsTemplate(
            id: "test", name: "테스트", summary: "", symbol: "film",
            slots: (0..<3).map { SlotSpec(index: $0, title: "\($0)", instruction: "x", seconds: 0.8, guide: SlotGuide()) },
            transition: .dissolve, beatsPerMinute: nil)
        var sources: [AssemblySource] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let d = try await asset.load(.duration).seconds
            sources.append(AssemblySource(asset: asset, start: 0, end: min(d, 0.8)))
        }
        let (composition, videoComposition, audioMix) = try await ShortsAssembler.build(template: template, sources: sources,
                                                                                         keepOriginalAudio: false)
        XCTAssertEqual(videoComposition.renderSize, CGSize(width: 1080, height: 1920))
        // 칸 단독 3 + 전환 2 = 지시 5개, 시간 순서대로 빈틈없이.
        XCTAssertEqual(videoComposition.instructions.count, 5)
        var cursor = CMTime.zero
        for ins in videoComposition.instructions {
            XCTAssertEqual(CMTimeGetSeconds(ins.timeRange.start), CMTimeGetSeconds(cursor), accuracy: 0.01)
            cursor = ins.timeRange.end
        }
        let out = try await ShortsAssembler.export(composition: composition, videoComposition: videoComposition,
                                                   audioMix: audioMix) { _ in }
        defer { try? FileManager.default.removeItem(at: out) }
        let result = AVURLAsset(url: out)
        let duration = try await result.load(.duration).seconds
        XCTAssertEqual(duration, ShortsTimeline.totalDuration(ShortsTimeline.plan(
            sources: sources.map { ($0.start, $0.end - $0.start, 0.8) }, transition: 0.4)), accuracy: 0.15)
        let tracks = try await result.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
    }

    /// 세로 촬영 영상의 흔한 preferredTransform(90° 시계 방향): 원본(가로)의 윗부분이 화면 오른쪽으로 가야 한다.
    func testFillRotationOrientation() {
        let ctx = CIContext()
        // 원본 1920×1080: 위쪽 절반 빨강, 아래쪽 절반 파랑(Core Image 좌표에서 위 = y 큰 쪽).
        let top = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 540, width: 1920, height: 540))
        let bottom = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 540))
        let natural = top.composited(over: bottom)
        let rotateCW = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let filled = ShortsCompositor.fill(natural, transform: rotateCW)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(filled, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return px
        }
        let right = pixel(1000, 960), left = pixel(80, 960)
        XCTAssertGreaterThan(right[0], 200, "오른쪽 = 원본 윗부분(빨강) \(right)")
        XCTAssertGreaterThan(left[2], 200, "왼쪽 = 원본 아랫부분(파랑) \(left)")
    }

    func testFillLandscapeToPortrait() {
        // 가로 영상(1920×1080, 변환 없음)도 9:16을 가득 채운다.
        let landscape = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let filled = ShortsCompositor.fill(landscape, transform: .identity)
        XCTAssertEqual(filled.extent, CGRect(x: 0, y: 0, width: 1080, height: 1920))
        // 90° 회전 변환(세로로 찍은 영상의 흔한 preferredTransform)도 같은 크기로.
        let rotated = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        XCTAssertEqual(ShortsCompositor.fill(landscape, transform: rotated).extent, CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }
}
