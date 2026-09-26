// 개발용: 3D 스티커 16종을 만화 얼굴에 얹은 미리보기 PNG를 만든다(위치·크기 눈 확인용). 환경변수 EFFECT_PREVIEW_DIR이 있을 때만 실행.
import CoreImage
import UIKit
import XCTest
@testable import TripShot

final class EffectPreviewTests: XCTestCase {
    func testRenderStickerPreviewSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["EFFECT_PREVIEW_DIR"] else {
            throw XCTSkip("EFFECT_PREVIEW_DIR 없음")
        }
        let cell = CGSize(width: 300, height: 400), cols = 4
        let kinds = EffectKind.allCases.filter { $0.category == .sticker }
        let rows = (kinds.count + cols - 1) / cols
        let sheet = CGRect(x: 0, y: 0, width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))
        let ctx = CIContext()
        var composite = CIImage(color: CIColor(red: 0.85, green: 0.9, blue: 0.95)).cropped(to: sheet)
        for (i, kind) in kinds.enumerated() {
            let ox = CGFloat(i % cols) * cell.width, oy = sheet.height - CGFloat(i / cols + 1) * cell.height
            let iod: CGFloat = 60
            let eyeMid = CGPoint(x: ox + 150, y: oy + 200)
            // 만화 얼굴: 피부 타원(머리 꼭대기 눈 위 1.8 IOD, 턱 눈 아래 1.9 IOD, 폭 2.4 IOD) + 눈·코·입.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let face = UIGraphicsImageRenderer(size: cell, format: format).image { c in
                let g = c.cgContext
                let ey = cell.height - 200
                g.setFillColor(UIColor(red: 0.3, green: 0.2, blue: 0.15, alpha: 1).cgColor)
                g.fillEllipse(in: CGRect(x: 150 - 1.3 * iod, y: ey - 1.9 * iod, width: 2.6 * iod, height: 2.2 * iod))
                g.setFillColor(UIColor(red: 0.98, green: 0.82, blue: 0.7, alpha: 1).cgColor)
                g.fillEllipse(in: CGRect(x: 150 - 1.2 * iod, y: ey - 1.6 * iod, width: 2.4 * iod, height: 3.5 * iod))
                g.setFillColor(UIColor.black.cgColor)
                g.fillEllipse(in: CGRect(x: 150 - 0.5 * iod - 6, y: ey - 6, width: 12, height: 12))
                g.fillEllipse(in: CGRect(x: 150 + 0.5 * iod - 6, y: ey - 6, width: 12, height: 12))
                g.setFillColor(UIColor(red: 0.8, green: 0.3, blue: 0.3, alpha: 1).cgColor)
                g.fillEllipse(in: CGRect(x: 150 - 0.35 * iod, y: ey + 1.05 * iod, width: 0.7 * iod, height: 0.3 * iod))
                g.setFillColor(UIColor(red: 0.85, green: 0.6, blue: 0.5, alpha: 1).cgColor)
                g.fillEllipse(in: CGRect(x: 150 - 6, y: ey + 0.55 * iod, width: 12, height: 10))
                (kind.title as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
            }
            let faceImage = CIImage(cgImage: face.cgImage!).transformed(by: CGAffineTransform(translationX: ox, y: oy))
            var cellImage = faceImage.composited(over: CIImage(color: .white).cropped(to: CGRect(x: ox, y: oy, width: cell.width, height: cell.height)))
            let anchors = FaceAnchors(eyeLeft: CGPoint(x: eyeMid.x - iod / 2, y: eyeMid.y), eyeRight: CGPoint(x: eyeMid.x + iod / 2, y: eyeMid.y),
                                      noseTip: CGPoint(x: eyeMid.x, y: eyeMid.y - 0.6 * iod), mouthCenter: CGPoint(x: eyeMid.x, y: eyeMid.y - 1.2 * iod),
                                      mouthOpen: 0.3, faceCenter: CGPoint(x: eyeMid.x, y: eyeMid.y - 0.4 * iod), faceSize: CGSize(width: 2.4 * iod, height: 3.0 * iod))
            for layer in EffectRenderer.stickerLayers(kind, face: anchors, time: 0.6, highQuality: true) { cellImage = layer.composited(over: cellImage) }
            composite = cellImage.cropped(to: CGRect(x: ox, y: oy, width: cell.width, height: cell.height)).composited(over: composite)
        }
        let cg = try XCTUnwrap(ctx.createCGImage(composite, from: sheet))
        try UIImage(cgImage: cg).pngData()!.write(to: URL(fileURLWithPath: dir + "/sticker_preview.png"))
    }
}
