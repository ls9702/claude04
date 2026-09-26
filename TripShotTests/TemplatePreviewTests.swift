// 템플릿 예시 영상(R3-S5a): 동작 값, 클립 생성·조립, 개발용 장면 시트(EFFECT_PREVIEW_DIR 있을 때만).
import AVFoundation
import UIKit
import XCTest
@testable import TripShot

final class TemplatePreviewTests: XCTestCase {
    func testMotionSpecs() {
        // 손 가리기: 가운데 칸은 시작에 가려져 있고 끝에 다시 가린다.
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "handCover", slot: 1, count: 4, t: 0).handCover, 1)
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "handCover", slot: 1, count: 4, t: 0.5).handCover, 0)
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "handCover", slot: 1, count: 4, t: 1).handCover, 1)
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "handCover", slot: 0, count: 4, t: 0).handCover, 0, "첫 칸은 가린 채 시작하지 않음")
        // 점프: 끝에 떠오르고 마지막 칸은 끝에 뛰지 않음.
        XCTAssertGreaterThan(TemplatePreviewMotion.spec(template: "jumpTeleport", slot: 0, count: 5, t: 1).figureLift, 0.2)
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "jumpTeleport", slot: 4, count: 5, t: 1).figureLift, 0)
        // 뒤돌아보기: 앞은 뒷모습, 뒤는 정면.
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "lookBack", slot: 0, count: 4, t: 0.2).pose, .back)
        XCTAssertEqual(TemplatePreviewMotion.spec(template: "lookBack", slot: 0, count: 4, t: 0.9).pose, .stand)
        // 모든 템플릿이 값을 낸다(알 수 없는 키도 기본값).
        for t in ShortsTemplateLibrary.all {
            _ = TemplatePreviewMotion.spec(template: t.id, slot: 0, count: t.slots.count, t: 0.5)
        }
    }

    func testGenerateAndBuildPreview() async throws {
        let template = ShortsTemplateLibrary.handCover
        try? FileManager.default.removeItem(at: TemplatePreviewGenerator.cacheDirectory(for: template))
        let item = try await TemplatePreviewGenerator.playerItem(for: template)
        let duration = try await item.asset.load(.duration).seconds
        XCTAssertEqual(duration, template.totalSeconds, accuracy: 0.3)
        XCTAssertNotNil(item.videoComposition)
        // 두 번째는 캐시에서.
        let start = Date()
        _ = try await TemplatePreviewGenerator.clips(for: template)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    /// 개발용: 템플릿마다 한 칸의 세 순간(시작·가운데·끝)을 한 장에.
    func testRenderSceneSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["EFFECT_PREVIEW_DIR"] else { throw XCTSkip("EFFECT_PREVIEW_DIR 없음") }
        let cell = CGSize(width: 135, height: 240)
        let templates = ShortsTemplateLibrary.all
        let times: [CGFloat] = [0.05, 0.5, 0.96]
        let sheet = CGSize(width: cell.width * CGFloat(times.count * 3), height: cell.height * CGFloat((templates.count + 2) / 3) + 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: sheet, format: format).image { ctx in
            for (i, t) in templates.enumerated() {
                let slot = t.slots[min(1, t.slots.count - 1)]
                for (j, time) in times.enumerated() {
                    let frame = UIGraphicsImageRenderer(size: TemplatePreviewRenderer.size, format: format).image { c in
                        let spec = TemplatePreviewMotion.spec(template: t.id, slot: slot.index, count: t.slots.count, t: time)
                        TemplatePreviewRenderer.draw(c.cgContext, spec: spec, place: slot.index, caption: t.name,
                                                     cue: time < 0.2 ? slot.guide.startCue : (time > 0.78 ? slot.guide.endCue : nil))
                    }
                    let x = CGFloat((i % 3) * times.count + j) * cell.width, y = CGFloat(i / 3) * cell.height
                    frame.draw(in: CGRect(x: x, y: y, width: cell.width - 2, height: cell.height - 2))
                }
            }
            _ = ctx
        }
        try image.pngData()!.write(to: URL(fileURLWithPath: dir + "/template_scenes.png"))
    }
}
