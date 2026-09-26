// 영상 녹화(R3-S1): 보정된 CIImage 프레임을 1080×1920 HEVC 파일로 쓰는지, 길이·방향(세로)·비율 맞춤.
import AVFoundation
import CoreImage
import XCTest
@testable import TripShot

final class VideoRecorderTests: XCTestCase {
    func testWritesPortraitHEVCFile() async throws {
        let url = VideoRecorder.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try VideoRecorder(url: url, unmirror: false, withAudio: false)
        // 16:9 세로 프레임(1080×1920 → 프리뷰 해상도 540×960) 30장 = 1초.
        for i in 0..<30 {
            let color = CIColor(red: CGFloat(i) / 30, green: 0.4, blue: 0.6)
            let frame = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 540, height: 960))
            recorder.appendVideo(frame, time: CMTime(value: CMTimeValue(i), timescale: 30))
            // 실시간 입력이라 인코더가 준비되지 않은 프레임은 버린다 → 카메라처럼 1/30초 간격으로 넣는다.
            try await Task.sleep(for: .milliseconds(34))
        }
        // 시뮬레이터는 HEVC를 소프트웨어로 인코딩해 느리다(실기기는 하드웨어) → 일부 버림을 허용한다.
        XCTAssertGreaterThanOrEqual(recorder.framesWritten, 10)
        let out = await recorder.finish()
        XCTAssertEqual(out, url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.4)
        XCTAssertLessThan(duration, 1.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1920)
    }

    func testNoFramesGivesNil() async throws {
        let recorder = try VideoRecorder(url: VideoRecorder.temporaryURL(), unmirror: false, withAudio: false)
        let out = await recorder.finish()
        XCTAssertNil(out)
    }

    func testFittedFillsNineBySixteen() {
        // 4:3(1440×1920)으로 폴백된 프레임도 9:16을 가득 채우게 가운데를 자른다.
        let frame = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1440, height: 1920))
        let fitted = VideoRecorder.fitted(frame, unmirror: false)
        XCTAssertEqual(fitted.extent, CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }

    func testTimeLabel() {
        XCTAssertEqual(CaptureView.timeLabel(0), "00:00")
        XCTAssertEqual(CaptureView.timeLabel(75.4), "01:15")
    }
}
