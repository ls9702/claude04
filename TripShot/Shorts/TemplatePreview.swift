// 템플릿 예시 영상(R3-S5a): 실제 여행 영상 대신, 칸마다 다른 "장소" 그림 위에서 사람 그림이 템플릿 동작(걸어 들어오기·손 가리기·점프·
// 휙 패닝 등)을 하는 짧은 클립을 앱이 직접 만들고, 실제 조립기(같은 전환)로 이어 붙여 반복 재생한다. 만든 클립은 캐시에 둔다.
import AVFoundation
import AVKit
import CoreImage
import SwiftUI
import UIKit

// MARK: - 프레임 그리기

/// 예시 한 프레임에 필요한 값(템플릿 동작에서 계산, 테스트 대상).
struct PreviewFrameSpec: Equatable {
    enum Pose: Equatable { case stand, walk, armsUp, back, snap, hidden }
    /// 장면(배경+사람) 이동·확대·회전(카메라 움직임 흉내). 이동은 화면 크기 비율.
    var sceneOffset = CGPoint.zero
    var sceneScale: CGFloat = 1
    var sceneRotation: CGFloat = 0
    var figureX: CGFloat = 0.5
    /// 발 위치에서 위로 뜬 정도(화면 높이 비율, 점프).
    var figureLift: CGFloat = 0
    var figureScale: CGFloat = 1
    var pose: Pose = .stand
    /// 손바닥 가림(0 = 없음, 1 = 화면 전체).
    var handCover: CGFloat = 0
    /// 벽 가림: 화면을 덮는 어두운 기둥의 가운데 x(화면 비율). nil이면 없음.
    var wallX: CGFloat?
    /// 흰 번쩍임(스냅).
    var flash: CGFloat = 0
    /// 가운데 목표물(줌 인·음식).
    var showTarget = false
}

enum TemplatePreviewMotion {
    /// 템플릿·칸·칸 안 진행률(0~1) → 프레임 값.
    static func spec(template id: String, slot: Int, count: Int, t: CGFloat) -> PreviewFrameSpec {
        var f = PreviewFrameSpec()
        let first = slot == 0, last = slot == count - 1
        func ramp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max((t - a) / (b - a), 0), 1) }
        switch id {
        case "walkTeleport":
            f.pose = .walk
            f.figureX = first ? 0.15 + 0.35 * ramp(0, 0.7) : 0.5
            f.figureScale = 0.9 + 0.2 * t
        case "handCover":
            f.pose = .stand
            if !first { f.handCover = 1 - ramp(0, 0.18) }
            if !last { f.handCover = max(f.handCover, ramp(0.8, 1)) }
        case "whipPan":
            f.pose = .hidden
            if !last { f.sceneOffset.x -= 1.4 * ramp(0.8, 1) * ramp(0.8, 1) }
            if !first { f.sceneOffset.x += 1.4 * pow(1 - ramp(0, 0.2), 2) }
        case "zoomJump":
            f.pose = .hidden
            f.showTarget = true
            if !last { f.sceneScale = 1 + 2.2 * pow(ramp(0.65, 1), 2) } else { f.sceneScale = 1.6 - 0.6 * ramp(0, 1) }
        case "outOfFrame":
            f.pose = .walk
            let enter = first ? 0.5 : 1.2 - 0.7 * ramp(0, 0.4)
            f.figureX = last ? enter : (t < 0.6 ? enter : 0.5 - 0.75 * ramp(0.6, 1))
        case "samePose":
            f.pose = .armsUp
            f.figureLift = 0.01 * sin(t * .pi)
        case "skyTilt":
            f.pose = .stand
            if !last { f.sceneOffset.y += 0.85 * pow(ramp(0.7, 1), 2) }
            if !first { f.sceneOffset.y += 0.85 * pow(1 - ramp(0, 0.3), 2) }
        case "lookBack":
            f.pose = t < 0.6 ? .back : .stand
        case "beatCut":
            f.pose = slot % 2 == 0 ? .hidden : .armsUp
            f.sceneScale = 1 + 0.08 * sin(t * .pi)
        case "basicStory":
            switch slot {
            case 0: f.pose = .hidden; f.sceneScale = 1.1 - 0.1 * t
            case 1: f.pose = .stand
            case 2, 3: f.pose = .hidden; f.showTarget = true; f.sceneScale = 1.4
            default: f.pose = .back
            }
        case "jumpTeleport":
            f.pose = .stand
            if !last { f.figureLift = 0.3 * pow(ramp(0.72, 1), 1.5) }
            if !first { f.figureLift = max(f.figureLift, 0.3 * pow(1 - ramp(0, 0.25), 1.5)) }
        case "cameraSpin":
            f.pose = .stand
            if !last { f.sceneRotation -= .pi / 2 * pow(ramp(0.8, 1), 2) }
            if !first { f.sceneRotation += .pi / 2 * pow(1 - ramp(0, 0.2), 2) }
        case "wallWipe":
            f.pose = .walk
            f.figureX = 0.5
            if !last, t > 0.8 { f.wallX = 1.3 - 0.8 * ramp(0.8, 1) }
            if !first, t < 0.2 { f.wallX = 0.5 - 0.8 * ramp(0, 0.2) }
        case "fingerSnap":
            f.pose = t > 0.8 && !last ? .snap : .stand
            if !last { f.flash = max(0, 1 - abs(t - 0.93) / 0.07) }
        case "panoramaFlow":
            f.pose = .hidden
            f.sceneOffset.x = -0.5 * t
        default:
            f.pose = .stand
        }
        return f
    }
}

/// 장소 그림(색·풍경 모양) — 칸마다 다른 장소처럼 보이게.
private struct Place {
    let skyTop: UIColor, skyBottom: UIColor, ground: UIColor, landmark: Int, name: String

    static let all: [Place] = [
        Place(skyTop: UIColor(red: 0.35, green: 0.65, blue: 0.95, alpha: 1), skyBottom: UIColor(red: 0.75, green: 0.9, blue: 1, alpha: 1),
              ground: UIColor(red: 0.1, green: 0.45, blue: 0.75, alpha: 1), landmark: 0, name: "바다"),
        Place(skyTop: UIColor(red: 0.45, green: 0.25, blue: 0.55, alpha: 1), skyBottom: UIColor(red: 1, green: 0.6, blue: 0.45, alpha: 1),
              ground: UIColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1), landmark: 1, name: "도시"),
        Place(skyTop: UIColor(red: 0.5, green: 0.75, blue: 0.95, alpha: 1), skyBottom: UIColor(red: 0.85, green: 0.95, blue: 1, alpha: 1),
              ground: UIColor(red: 0.3, green: 0.55, blue: 0.3, alpha: 1), landmark: 2, name: "산"),
        Place(skyTop: UIColor(red: 0.95, green: 0.7, blue: 0.4, alpha: 1), skyBottom: UIColor(red: 1, green: 0.88, blue: 0.6, alpha: 1),
              ground: UIColor(red: 0.85, green: 0.65, blue: 0.4, alpha: 1), landmark: 3, name: "사막"),
        Place(skyTop: UIColor(red: 0.05, green: 0.07, blue: 0.2, alpha: 1), skyBottom: UIColor(red: 0.15, green: 0.2, blue: 0.4, alpha: 1),
              ground: UIColor(red: 0.08, green: 0.1, blue: 0.15, alpha: 1), landmark: 4, name: "밤"),
        Place(skyTop: UIColor(red: 0.55, green: 0.8, blue: 0.7, alpha: 1), skyBottom: UIColor(red: 0.85, green: 0.95, blue: 0.85, alpha: 1),
              ground: UIColor(red: 0.15, green: 0.4, blue: 0.2, alpha: 1), landmark: 5, name: "숲"),
        Place(skyTop: UIColor(red: 0.6, green: 0.7, blue: 0.9, alpha: 1), skyBottom: UIColor(red: 0.95, green: 0.9, blue: 0.9, alpha: 1),
              ground: UIColor(red: 0.45, green: 0.45, blue: 0.5, alpha: 1), landmark: 6, name: "탑"),
        Place(skyTop: UIColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1), skyBottom: UIColor(white: 0.97, alpha: 1),
              ground: UIColor(white: 0.93, alpha: 1), landmark: 7, name: "설경"),
    ]
}

enum TemplatePreviewRenderer {
    static let size = CGSize(width: 540, height: 960)

    /// 한 프레임 그리기(UIKit 좌표, 원점 좌상단).
    static func draw(_ g: CGContext, spec f: PreviewFrameSpec, place index: Int, caption: String, cue: String?) {
        let W = size.width, H = size.height
        let place = Place.all[index % Place.all.count]
        g.saveGState()
        // 카메라 움직임: 가운데 기준 회전·확대 후 이동.
        g.translateBy(x: W / 2 + f.sceneOffset.x * W, y: H / 2 + f.sceneOffset.y * H)
        g.rotate(by: f.sceneRotation)
        g.scaleBy(x: f.sceneScale, y: f.sceneScale)
        g.translateBy(x: -W / 2, y: -H / 2)
        // 하늘(위로 넉넉히 — 틸트할 때 하늘이 보이게)·땅. 좌우로 3배 넓게(패닝).
        let horizon = H * 0.62
        let sky = [place.skyTop.cgColor, place.skyBottom.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky, locations: [0, 1]) {
            g.saveGState()
            g.clip(to: CGRect(x: -W * 2, y: -H * 2, width: W * 5, height: horizon + H * 2))
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: -H), end: CGPoint(x: 0, y: horizon), options: [.drawsBeforeStartLocation])
            g.restoreGState()
        }
        g.setFillColor(place.ground.cgColor)
        g.fill(CGRect(x: -W * 2, y: horizon, width: W * 5, height: H * 3))
        for dx in [-W, 0, W, 2 * W] { drawLandmark(g, kind: place.landmark, x0: dx, horizon: horizon) }
        if f.showTarget {
            g.setFillColor(UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: W / 2 - 70, y: H / 2 - 70, width: 140, height: 140))
            g.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: W / 2 - 30, y: H / 2 - 30, width: 60, height: 60))
        }
        if f.pose != .hidden {
            drawFigure(g, pose: f.pose, footX: f.figureX * W, footY: H * 0.88 - f.figureLift * H, height: H * 0.42 * f.figureScale)
        }
        g.restoreGState()

        if let x = f.wallX {
            g.setFillColor(UIColor(red: 0.22, green: 0.18, blue: 0.16, alpha: 1).cgColor)
            g.fill(CGRect(x: x * W - W * 0.55, y: 0, width: W * 1.1, height: H))
        }
        if f.handCover > 0 {
            let h = H * 1.2 * f.handCover
            g.setFillColor(UIColor(red: 0.93, green: 0.74, blue: 0.62, alpha: 1).cgColor)
            g.addPath(UIBezierPath(roundedRect: CGRect(x: -W * 0.1, y: H - h, width: W * 1.2, height: h + 40), cornerRadius: W * 0.35).cgPath)
            g.fillPath()
        }
        if f.flash > 0 {
            g.setFillColor(UIColor(white: 1, alpha: f.flash * 0.85).cgColor)
            g.fill(CGRect(origin: .zero, size: size))
        }
        // 칸 이름(왼쪽 위)과 지시(아래 노란 캡슐).
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white]
        let text = "\(caption) · \(place.name)" as NSString
        g.setFillColor(UIColor(white: 0, alpha: 0.35).cgColor)
        let ts = text.size(withAttributes: captionAttrs)
        g.addPath(UIBezierPath(roundedRect: CGRect(x: 24, y: 40, width: ts.width + 28, height: ts.height + 12), cornerRadius: 20).cgPath)
        g.fillPath()
        text.draw(at: CGPoint(x: 38, y: 46), withAttributes: captionAttrs)
        if let cue {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.black]
            let s = (cue as NSString).size(withAttributes: attrs)
            let r = CGRect(x: (W - s.width) / 2 - 20, y: H * 0.72, width: s.width + 40, height: s.height + 16)
            g.setFillColor(UIColor.systemYellow.cgColor)
            g.addPath(UIBezierPath(roundedRect: r, cornerRadius: r.height / 2).cgPath)
            g.fillPath()
            (cue as NSString).draw(at: CGPoint(x: r.minX + 20, y: r.minY + 8), withAttributes: attrs)
        }
    }

    private static func drawLandmark(_ g: CGContext, kind: Int, x0: CGFloat, horizon: CGFloat) {
        let W = size.width
        switch kind {
        case 0: // 해 + 파도
            g.setFillColor(UIColor(red: 1, green: 0.9, blue: 0.4, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: x0 + W * 0.65, y: horizon - 260, width: 110, height: 110))
            g.setFillColor(UIColor(white: 1, alpha: 0.6).cgColor)
            for k in 0..<5 { g.fill(CGRect(x: x0 + CGFloat(k) * 120, y: horizon + 40 + CGFloat(k % 2) * 30, width: 70, height: 6)) }
        case 1: // 빌딩
            for k in 0..<6 {
                let h = CGFloat([220, 320, 180, 400, 260, 300][k])
                g.setFillColor(UIColor(red: 0.15, green: 0.12, blue: 0.25, alpha: 1).cgColor)
                g.fill(CGRect(x: x0 + CGFloat(k) * 92, y: horizon - h, width: 80, height: h))
                g.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.8).cgColor)
                for w in stride(from: horizon - h + 20, to: horizon - 20, by: 40) {
                    g.fill(CGRect(x: x0 + CGFloat(k) * 92 + 14, y: w, width: 14, height: 18))
                    g.fill(CGRect(x: x0 + CGFloat(k) * 92 + 48, y: w, width: 14, height: 18))
                }
            }
        case 2, 7: // 산(설경은 흰 봉우리)
            g.setFillColor((kind == 2 ? UIColor(red: 0.3, green: 0.45, blue: 0.4, alpha: 1) : UIColor(red: 0.7, green: 0.78, blue: 0.88, alpha: 1)).cgColor)
            g.move(to: CGPoint(x: x0 - 40, y: horizon)); g.addLine(to: CGPoint(x: x0 + 180, y: horizon - 330)); g.addLine(to: CGPoint(x: x0 + 400, y: horizon))
            g.move(to: CGPoint(x: x0 + 250, y: horizon)); g.addLine(to: CGPoint(x: x0 + 450, y: horizon - 240)); g.addLine(to: CGPoint(x: x0 + 620, y: horizon))
            g.fillPath()
            g.setFillColor(UIColor.white.cgColor)
            g.move(to: CGPoint(x: x0 + 140, y: horizon - 270)); g.addLine(to: CGPoint(x: x0 + 180, y: horizon - 330)); g.addLine(to: CGPoint(x: x0 + 220, y: horizon - 270))
            g.fillPath()
        case 3: // 피라미드
            g.setFillColor(UIColor(red: 0.8, green: 0.55, blue: 0.3, alpha: 1).cgColor)
            g.move(to: CGPoint(x: x0 + 80, y: horizon)); g.addLine(to: CGPoint(x: x0 + 260, y: horizon - 230)); g.addLine(to: CGPoint(x: x0 + 440, y: horizon))
            g.fillPath()
        case 4: // 달·별
            g.setFillColor(UIColor(red: 1, green: 0.97, blue: 0.8, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: x0 + W * 0.2, y: horizon - 420, width: 90, height: 90))
            for k in 0..<14 {
                let x = x0 + CGFloat((k * 97) % 540), y = horizon - 150 - CGFloat((k * 53) % 300)
                g.fillEllipse(in: CGRect(x: x, y: y, width: 5, height: 5))
            }
        case 5: // 나무
            for k in 0..<5 {
                let x = x0 + CGFloat(k) * 115 + 20
                g.setFillColor(UIColor(red: 0.4, green: 0.25, blue: 0.15, alpha: 1).cgColor)
                g.fill(CGRect(x: x + 30, y: horizon - 70, width: 16, height: 70))
                g.setFillColor(UIColor(red: 0.15, green: 0.5, blue: 0.25, alpha: 1).cgColor)
                g.fillEllipse(in: CGRect(x: x, y: horizon - 180, width: 76, height: 130))
            }
        default: // 탑
            g.setFillColor(UIColor(red: 0.85, green: 0.3, blue: 0.2, alpha: 1).cgColor)
            g.move(to: CGPoint(x: x0 + 230, y: horizon)); g.addLine(to: CGPoint(x: x0 + 270, y: horizon - 420)); g.addLine(to: CGPoint(x: x0 + 310, y: horizon))
            g.fillPath()
            g.fill(CGRect(x: x0 + 250, y: horizon - 300, width: 40, height: 10))
            g.fill(CGRect(x: x0 + 240, y: horizon - 180, width: 60, height: 10))
        }
    }

    private static func drawFigure(_ g: CGContext, pose: PreviewFrameSpec.Pose, footX: CGFloat, footY: CGFloat, height h: CGFloat) {
        let w = h * 0.42
        let top = footY - h
        let skin = UIColor(red: 0.96, green: 0.8, blue: 0.68, alpha: 1)
        let shirt = UIColor(red: 0.95, green: 0.35, blue: 0.4, alpha: 1)
        let pants = UIColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1)
        let hair = UIColor(red: 0.2, green: 0.13, blue: 0.1, alpha: 1)
        // 다리
        g.setFillColor(pants.cgColor)
        g.fill(CGRect(x: footX - w * 0.22, y: top + h * 0.52, width: w * 0.18, height: h * 0.48))
        g.fill(CGRect(x: footX + w * 0.04, y: top + h * 0.52, width: w * 0.18, height: h * 0.48))
        // 몸통
        g.setFillColor(shirt.cgColor)
        g.addPath(UIBezierPath(roundedRect: CGRect(x: footX - w * 0.28, y: top + h * 0.15, width: w * 0.56, height: h * 0.4), cornerRadius: w * 0.12).cgPath)
        g.fillPath()
        // 팔
        g.setStrokeColor(skin.cgColor)
        g.setLineWidth(w * 0.13)
        g.setLineCap(.round)
        let shoulderY = top + h * 0.2
        switch pose {
        case .armsUp:
            g.move(to: CGPoint(x: footX - w * 0.25, y: shoulderY)); g.addLine(to: CGPoint(x: footX - w * 0.55, y: top - h * 0.08))
            g.move(to: CGPoint(x: footX + w * 0.25, y: shoulderY)); g.addLine(to: CGPoint(x: footX + w * 0.55, y: top - h * 0.08))
        case .snap:
            g.move(to: CGPoint(x: footX - w * 0.3, y: shoulderY)); g.addLine(to: CGPoint(x: footX - w * 0.35, y: top + h * 0.5))
            g.move(to: CGPoint(x: footX + w * 0.28, y: shoulderY)); g.addLine(to: CGPoint(x: footX + w * 0.6, y: top + h * 0.02))
        default:
            g.move(to: CGPoint(x: footX - w * 0.3, y: shoulderY)); g.addLine(to: CGPoint(x: footX - w * 0.36, y: top + h * 0.5))
            g.move(to: CGPoint(x: footX + w * 0.3, y: shoulderY)); g.addLine(to: CGPoint(x: footX + w * 0.36, y: top + h * 0.5))
        }
        g.strokePath()
        // 머리
        let head = CGRect(x: footX - w * 0.16, y: top, width: w * 0.32, height: h * 0.14)
        g.setFillColor(skin.cgColor)
        g.fillEllipse(in: head)
        g.setFillColor(hair.cgColor)
        if pose == .back {
            g.fillEllipse(in: head)   // 뒷모습: 머리카락만
        } else {
            g.fillEllipse(in: CGRect(x: head.minX, y: head.minY, width: head.width, height: head.height * 0.45))
            g.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: head.midX - head.width * 0.22, y: head.midY, width: 5, height: 5))
            g.fillEllipse(in: CGRect(x: head.midX + head.width * 0.15, y: head.midY, width: 5, height: 5))
        }
    }
}

// MARK: - 생성·캐시

enum TemplatePreviewGenerator {
    /// 생성 규칙이 바뀌면 올려서 캐시를 버린다.
    static let version = 1
    static let fps = 30

    static func cacheDirectory(for template: ShortsTemplate) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TemplatePreviews/\(template.id)-v\(version)", isDirectory: true)
    }

    /// 칸별 예시 클립(캐시에 있으면 그대로). 백그라운드에서 부른다.
    static func clips(for template: ShortsTemplate) async throws -> [URL] {
        let dir = cacheDirectory(for: template)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for slot in template.slots {
            let url = dir.appendingPathComponent("slot-\(slot.index).mov")
            if !FileManager.default.fileExists(atPath: url.path) {
                try await render(template: template, slot: slot, to: url)
            }
            urls.append(url)
        }
        return urls
    }

    private static func render(template: ShortsTemplate, slot: SlotSpec, to url: URL) async throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
        let recorder = try VideoRecorder(url: temp, unmirror: false, withAudio: false,
                                         size: TemplatePreviewRenderer.size, realTime: false)
        // 전환이 겹치는 만큼 조금 더 길게.
        let seconds = slot.seconds + template.transition.duration
        let frames = max(Int(seconds * Double(fps)), 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: TemplatePreviewRenderer.size, format: format)
        for i in 0..<frames {
            let t = CGFloat(i) / CGFloat(frames - 1)
            let spec = TemplatePreviewMotion.spec(template: template.id, slot: slot.index, count: template.slots.count, t: t)
            let cue: String? = t < 0.2 ? slot.guide.startCue : (t > 0.78 ? slot.guide.endCue : nil)
            let image = renderer.image { ctx in
                TemplatePreviewRenderer.draw(ctx.cgContext, spec: spec, place: slot.index, caption: slot.title, cue: cue)
            }
            guard let cg = image.cgImage else { continue }
            autoreleasepool {
                recorder.appendVideo(CIImage(cgImage: cg), time: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            }
        }
        guard let out = await recorder.finish() else { throw ShortsAssemblyError.exportFailed("예시 생성") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: out, to: url)
    }

    /// 예시 재생용 플레이어 아이템(실제 조립기와 같은 전환).
    static func playerItem(for template: ShortsTemplate) async throws -> AVPlayerItem {
        let urls = try await clips(for: template)
        var sources: [AssemblySource] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let d = try await asset.load(.duration).seconds
            sources.append(AssemblySource(asset: asset, start: 0, end: d))
        }
        let (composition, videoComposition, audioMix) = try await ShortsAssembler.build(template: template, sources: sources,
                                                                                         keepOriginalAudio: false)
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

// MARK: - 화면

/// 템플릿 예시 시트: 반복 재생 + 칸 설명.
struct TemplatePreviewSheet: View {
    let template: ShortsTemplate
    var onUse: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(Color.black)
                        if let player {
                            VideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 16))
                        } else if failed {
                            Text("예시를 만들지 못했습니다").foregroundStyle(.white)
                        } else {
                            ProgressView("예시 만드는 중…").tint(.white).foregroundStyle(.white)
                        }
                    }
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxHeight: 440)

                    Text(template.summary).font(.subheadline)
                    Text("\(template.slots.count)칸 · \(Int(template.totalSeconds.rounded()))초 · 전환 \(template.transition.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(template.slots) { slot in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(slot.index + 1)").font(.caption.weight(.bold)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(slot.title) · \(String(format: "%.1f초", slot.seconds))").font(.caption.weight(.semibold))
                                    Text(slot.instruction).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    Text("예시 영상은 동작과 전환을 보여 주는 그림입니다.").font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                if let onUse {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("이 템플릿 사용") { onUse(); dismiss() }
                    }
                }
            }
        }
        .task {
            do {
                let item = try await TemplatePreviewGenerator.playerItem(for: template)
                let queue = AVQueuePlayer()
                queue.isMuted = true
                looper = AVPlayerLooper(player: queue, templateItem: item)
                player = queue
                queue.play()
            } catch {
                failed = true
            }
        }
        .onDisappear { player?.pause() }
    }
}
