// 효과 스티커 그림: Core Graphics 도형·이모지로 한 번만 그려 CIImage로 캐시한다(프레임마다 다시 그리지 않음, 외부 이미지 파일 없음).
import CoreImage
import UIKit

/// 캐시된 스티커 한 장. `anchor`는 이 그림에서 얼굴 기준점에 맞출 점(CIImage 좌표, 원점 좌하단).
struct StickerArt {
    let image: CIImage
    let anchor: CGPoint

    var width: CGFloat { image.extent.width }

    /// UIKit 좌표(원점 좌상단)로 그린다. `anchor`도 UIKit 좌표로 받는다.
    static func draw(size: CGSize, anchor: CGPoint, _ body: (CGContext) -> Void) -> StickerArt {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let ui = UIGraphicsImageRenderer(size: size, format: format).image { ctx in body(ctx.cgContext) }
        let image = ui.cgImage.map { CIImage(cgImage: $0) } ?? CIImage.empty()
        return StickerArt(image: image, anchor: CGPoint(x: anchor.x, y: size.height - anchor.y))
    }

    /// 이모지 한 글자를 `size` 정사각형 가운데에 그린다.
    static func drawEmoji(_ emoji: String, in rect: CGRect) {
        let font = UIFont.systemFont(ofSize: rect.height * 0.8)
        let text = emoji as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let s = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2), withAttributes: attrs)
    }

    /// 얼굴 기준점 `target`에 폭 `width`(픽셀)로, `angle`(라디안)만큼 돌려 놓은 이미지.
    func placed(at target: CGPoint, width targetWidth: CGFloat, angle: CGFloat) -> CIImage {
        let s = targetWidth / max(width, 1)
        let t = CGAffineTransform(translationX: target.x, y: target.y)
            .rotated(by: angle)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -anchor.x, y: -anchor.y)
        return image.transformed(by: t)
    }
}

/// 스티커 그림 모음. 정적 상수라 처음 쓸 때 한 번만 그린다(Swift 정적 초기화는 스레드 안전).
enum StickerLibrary {
    // MARK: 강아지

    static let puppyEars: StickerArt = StickerArt.draw(size: CGSize(width: 600, height: 320), anchor: CGPoint(x: 300, y: 200)) { c in
        let brown = UIColor(red: 0.55, green: 0.36, blue: 0.2, alpha: 1)
        let inner = UIColor(red: 0.95, green: 0.7, blue: 0.7, alpha: 1)
        for (x, angle) in [(CGFloat(110), CGFloat(0.35)), (490, -0.35)] {
            c.saveGState()
            c.translateBy(x: x, y: 150)
            c.rotate(by: angle)
            c.setFillColor(brown.cgColor)
            c.fillEllipse(in: CGRect(x: -80, y: -130, width: 160, height: 280))
            c.setFillColor(inner.cgColor)
            c.fillEllipse(in: CGRect(x: -45, y: -80, width: 90, height: 190))
            c.restoreGState()
        }
    }

    static let puppyNose: StickerArt = StickerArt.draw(size: CGSize(width: 200, height: 140), anchor: CGPoint(x: 100, y: 70)) { c in
        c.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
        c.addPath(UIBezierPath(roundedRect: CGRect(x: 10, y: 15, width: 180, height: 110), cornerRadius: 55).cgPath)
        c.fillPath()
        c.setFillColor(UIColor(white: 1, alpha: 0.6).cgColor)
        c.fillEllipse(in: CGRect(x: 50, y: 30, width: 45, height: 22))
    }

    static let tongue: StickerArt = StickerArt.draw(size: CGSize(width: 160, height: 220), anchor: CGPoint(x: 80, y: 10)) { c in
        c.setFillColor(UIColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1).cgColor)
        c.addPath(UIBezierPath(roundedRect: CGRect(x: 10, y: 0, width: 140, height: 210), cornerRadius: 70).cgPath)
        c.fillPath()
        c.setStrokeColor(UIColor(red: 0.75, green: 0.2, blue: 0.3, alpha: 1).cgColor)
        c.setLineWidth(6)
        c.move(to: CGPoint(x: 80, y: 30)); c.addLine(to: CGPoint(x: 80, y: 150))
        c.strokePath()
    }

    // MARK: 고양이

    static let catEars: StickerArt = StickerArt.draw(size: CGSize(width: 600, height: 300), anchor: CGPoint(x: 300, y: 270)) { c in
        let grey = UIColor(white: 0.35, alpha: 1)
        let pink = UIColor(red: 1, green: 0.72, blue: 0.78, alpha: 1)
        for (cx, lean) in [(CGFloat(140), CGFloat(-30)), (460, 30)] {
            c.setFillColor(grey.cgColor)
            c.move(to: CGPoint(x: cx - 110, y: 280)); c.addLine(to: CGPoint(x: cx + lean, y: 20)); c.addLine(to: CGPoint(x: cx + 110, y: 280))
            c.closePath(); c.fillPath()
            c.setFillColor(pink.cgColor)
            c.move(to: CGPoint(x: cx - 60, y: 260)); c.addLine(to: CGPoint(x: cx + lean * 0.8, y: 80)); c.addLine(to: CGPoint(x: cx + 60, y: 260))
            c.closePath(); c.fillPath()
        }
    }

    static let catWhiskers: StickerArt = StickerArt.draw(size: CGSize(width: 640, height: 220), anchor: CGPoint(x: 320, y: 70)) { c in
        c.setFillColor(UIColor(red: 1, green: 0.55, blue: 0.65, alpha: 1).cgColor)
        c.move(to: CGPoint(x: 280, y: 45)); c.addLine(to: CGPoint(x: 360, y: 45)); c.addLine(to: CGPoint(x: 320, y: 95))
        c.closePath(); c.fillPath()
        c.setStrokeColor(UIColor(white: 0.15, alpha: 0.9).cgColor)
        c.setLineWidth(6)
        c.setLineCap(.round)
        for dy in [CGFloat(-30), 0, 30] {
            c.move(to: CGPoint(x: 230, y: 110 + dy * 0.5)); c.addLine(to: CGPoint(x: 30, y: 110 + dy * 1.8))
            c.move(to: CGPoint(x: 410, y: 110 + dy * 0.5)); c.addLine(to: CGPoint(x: 610, y: 110 + dy * 1.8))
        }
        c.strokePath()
    }

    // MARK: 토끼·꽃·왕관

    static let bunnyEars: StickerArt = StickerArt.draw(size: CGSize(width: 520, height: 640), anchor: CGPoint(x: 260, y: 600)) { c in
        for (x, angle) in [(CGFloat(170), CGFloat(-0.18)), (350, 0.18)] {
            c.saveGState()
            c.translateBy(x: x, y: 600)
            c.rotate(by: angle)
            c.setFillColor(UIColor.white.cgColor)
            c.addPath(UIBezierPath(roundedRect: CGRect(x: -65, y: -560, width: 130, height: 560), cornerRadius: 65).cgPath)
            c.fillPath()
            c.setFillColor(UIColor(red: 1, green: 0.75, blue: 0.82, alpha: 1).cgColor)
            c.addPath(UIBezierPath(roundedRect: CGRect(x: -32, y: -500, width: 64, height: 440), cornerRadius: 32).cgPath)
            c.fillPath()
            c.restoreGState()
        }
        // 머리띠
        c.setStrokeColor(UIColor(red: 1, green: 0.6, blue: 0.75, alpha: 1).cgColor)
        c.setLineWidth(22)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: 40, y: 625)); c.addQuadCurve(to: CGPoint(x: 480, y: 625), control: CGPoint(x: 260, y: 560))
        c.strokePath()
    }

    static let flowerCrown: StickerArt = StickerArt.draw(size: CGSize(width: 900, height: 300), anchor: CGPoint(x: 450, y: 200)) { c in
        let flowers = ["🌸", "🌼", "🌷", "🌸", "🌺", "🌸", "🌷", "🌼", "🌸"]
        for (i, f) in flowers.enumerated() {
            let t = CGFloat(i) / CGFloat(flowers.count - 1)          // 0~1
            let x = 60 + t * 780
            let y = 170 - sin(t * .pi) * 90                            // 가운데가 높은 호
            let size: CGFloat = i % 2 == 0 ? 140 : 110
            StickerArt.drawEmoji(f, in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
        }
    }

    static let crown: StickerArt = StickerArt.draw(size: CGSize(width: 520, height: 340), anchor: CGPoint(x: 260, y: 320)) { c in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 30, y: 320))
        path.addLine(to: CGPoint(x: 20, y: 90)); path.addLine(to: CGPoint(x: 140, y: 190))
        path.addLine(to: CGPoint(x: 260, y: 30)); path.addLine(to: CGPoint(x: 380, y: 190))
        path.addLine(to: CGPoint(x: 500, y: 90)); path.addLine(to: CGPoint(x: 490, y: 320))
        path.close()
        c.saveGState()
        c.addPath(path.cgPath)
        c.clip()
        let colors = [UIColor(red: 1, green: 0.9, blue: 0.4, alpha: 1).cgColor,
                      UIColor(red: 0.85, green: 0.6, blue: 0.1, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: 30), end: CGPoint(x: 0, y: 320), options: [])
        }
        c.restoreGState()
        c.setStrokeColor(UIColor(red: 0.6, green: 0.4, blue: 0.05, alpha: 1).cgColor)
        c.setLineWidth(8)
        c.addPath(path.cgPath); c.strokePath()
        let jewels: [(CGFloat, UIColor)] = [(140, .systemRed), (260, .systemBlue), (380, .systemGreen)]
        for (x, color) in jewels {
            c.setFillColor(color.cgColor)
            c.fillEllipse(in: CGRect(x: x - 26, y: 240, width: 52, height: 52))
        }
    }

    static let heart: StickerArt = StickerArt.draw(size: CGSize(width: 140, height: 140), anchor: CGPoint(x: 70, y: 70)) { _ in
        StickerArt.drawEmoji("❤️", in: CGRect(x: 0, y: 0, width: 140, height: 140))
    }

    // MARK: 선글라스·볼터치

    static let sunglasses: StickerArt = StickerArt.draw(size: CGSize(width: 720, height: 260), anchor: CGPoint(x: 360, y: 120)) { c in
        let lenses = [CGRect(x: 30, y: 40, width: 280, height: 170), CGRect(x: 410, y: 40, width: 280, height: 170)]
        for r in lenses {
            let p = UIBezierPath(roundedRect: r, cornerRadius: 60)
            c.saveGState()
            c.addPath(p.cgPath); c.clip()
            let colors = [UIColor(white: 0.05, alpha: 0.95).cgColor, UIColor(white: 0.25, alpha: 0.85).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            }
            c.restoreGState()
            c.setStrokeColor(UIColor(white: 0.02, alpha: 1).cgColor)
            c.setLineWidth(14)
            c.addPath(p.cgPath); c.strokePath()
            // 반사광
            c.setStrokeColor(UIColor(white: 1, alpha: 0.5).cgColor)
            c.setLineWidth(10)
            c.setLineCap(.round)
            c.move(to: CGPoint(x: r.minX + 50, y: r.minY + 40)); c.addLine(to: CGPoint(x: r.minX + 110, y: r.minY + 30))
            c.strokePath()
        }
        c.setStrokeColor(UIColor(white: 0.02, alpha: 1).cgColor)
        c.setLineWidth(16)
        c.move(to: CGPoint(x: 310, y: 90)); c.addQuadCurve(to: CGPoint(x: 410, y: 90), control: CGPoint(x: 360, y: 60))
        c.strokePath()
    }

    static let blush: StickerArt = StickerArt.draw(size: CGSize(width: 720, height: 260), anchor: CGPoint(x: 360, y: 130)) { c in
        let colors = [UIColor(red: 1, green: 0.4, blue: 0.5, alpha: 0.45).cgColor,
                      UIColor(red: 1, green: 0.4, blue: 0.5, alpha: 0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        for x in [CGFloat(130), 590] {
            c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: 130), startRadius: 0,
                                 endCenter: CGPoint(x: x, y: 130), endRadius: 120, options: [])
            // 주근깨(고정 위치)
            c.setFillColor(UIColor(red: 0.55, green: 0.3, blue: 0.2, alpha: 0.7).cgColor)
            for (dx, dy) in [(-50, -40), (-15, -55), (25, -35), (-35, -5), (10, -10), (45, 5)] as [(CGFloat, CGFloat)] {
                c.fillEllipse(in: CGRect(x: x + dx - 6, y: 130 + dy - 6, width: 12, height: 12))
            }
        }
    }
}
