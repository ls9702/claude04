// 3D 스티커 모델(R2-S2): SceneKit 기본 도형·압출 도형 + 물리 기반 재질(금속·유광·털·유리·새틴)로 만든다. 외부 모델 파일 없음.
// 단위 = 두 눈 사이 거리(IOD). 좌표: 원점 = 부품의 기준 랜드마크(눈 중점·코끝·입 중심), +x 화면 오른쪽, +y 위, +z 카메라 쪽.
import SceneKit
import UIKit

/// 스티커 부품 하나(따로 렌더해 2D로 얹는 단위).
struct StickerPart {
    enum Anchor { case eyes, nose, mouth, free }

    /// 캐시 키.
    let id: String
    let anchor: Anchor
    /// 렌더 영역 중심(부품 좌표)과 반폭(정사각형). 모델이 이 안에 들어와야 한다.
    let viewCenter: SIMD2<Float>
    let viewHalf: Float
    /// 머리 가림(보이지 않는 머리 모형)을 넣을지. 공중에 뜬 부품(하트·나비)은 false.
    let occluded: Bool
    /// 발광 번짐(천사링).
    let glow: Bool
    let build: () -> SCNNode
}

/// 표준 얼굴 비율(IOD 단위): 눈 중점 기준 코끝·입 위치, 머리 모형(타원체) 중심·반지름.
enum HeadGeometry {
    static let noseOffset = SIMD3<Float>(0, -0.62, 0.35)
    static let mouthOffset = SIMD3<Float>(0, -1.2, 0.2)
    /// 머리 타원체(눈 중점 기준). 폭 2.4, 높이 3.7, 깊이 3.0 IOD(성인 평균 근사).
    static let headCenter = SIMD3<Float>(0, -0.05, -1.45)
    static let headRadii = SIMD3<Float>(1.2, 1.85, 1.5)

    static func offset(of anchor: StickerPart.Anchor) -> SIMD3<Float> {
        switch anchor {
        case .eyes, .free: return .zero
        case .nose: return noseOffset
        case .mouth: return mouthOffset
        }
    }
}

// MARK: - 재질

enum StickerMaterials {
    static func pbr(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5, clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if clearCoat > 0 {
            m.clearCoat.contents = clearCoat
            m.clearCoatRoughness.contents = 0.05
        }
        return m
    }

    static var gold: SCNMaterial { pbr(UIColor(red: 1.0, green: 0.78, blue: 0.36, alpha: 1), metal: 1, rough: 0.22) }
    static var silver: SCNMaterial { pbr(UIColor(white: 0.92, alpha: 1), metal: 1, rough: 0.18) }
    static var glossyBlack: SCNMaterial { pbr(UIColor(white: 0.03, alpha: 1), rough: 0.2, clearCoat: 1) }

    static func gem(_ color: UIColor) -> SCNMaterial {
        let m = pbr(color, metal: 0.1, rough: 0.04, clearCoat: 1)
        m.emission.contents = color.withAlphaComponent(1)
        m.emission.intensity = 0.15
        return m
    }

    static func satin(_ color: UIColor) -> SCNMaterial { pbr(color, metal: 0.05, rough: 0.35, clearCoat: 0.3) }
    static func felt(_ color: UIColor) -> SCNMaterial { pbr(color, rough: 0.9) }
    static func glossy(_ color: UIColor) -> SCNMaterial { pbr(color, rough: 0.25, clearCoat: 1) }

    /// 털: 짧은 결 무늬 텍스처(밝고 어두운 가닥) + 거친 표면.
    static func fur(_ color: UIColor) -> SCNMaterial {
        let m = pbr(color, rough: 0.95)
        m.diffuse.contents = furTexture(color)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
        return m
    }

    static func glass(_ tint: UIColor, opacity: CGFloat) -> SCNMaterial {
        let m = pbr(tint, metal: 0.4, rough: 0.03, clearCoat: 1)
        m.transparency = opacity
        m.transparencyMode = .dualLayer
        m.isDoubleSided = true
        return m
    }

    /// 머리 가림용: 색은 쓰지 않고 깊이만 쓴다.
    static var occluder: SCNMaterial {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        return m
    }

    private static func furTexture(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(color.cgColor)
            g.fill(CGRect(origin: .zero, size: size))
            var rng = SplitMix(seed: 7)
            g.setLineCap(.round)
            for _ in 0..<1400 {
                let x = CGFloat(rng.next()) * 256, y = CGFloat(rng.next()) * 256
                let len = 4 + CGFloat(rng.next()) * 8
                let angle = -CGFloat.pi / 2 + (CGFloat(rng.next()) - 0.5) * 0.6
                let shade = CGFloat(rng.next()) * 0.35 - 0.17
                g.setStrokeColor(color.adjusted(brightness: shade).cgColor)
                g.setLineWidth(0.8 + CGFloat(rng.next()) * 0.8)
                g.move(to: CGPoint(x: x, y: y))
                g.addLine(to: CGPoint(x: x + cos(angle) * len, y: y + sin(angle) * len))
                g.strokePath()
            }
        }
    }

    /// 나비 날개: 주황 그라데이션 + 검은 테두리·점.
    static var butterflyWing: SCNMaterial {
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            let colors = [UIColor(red: 1, green: 0.62, blue: 0.1, alpha: 1).cgColor,
                          UIColor(red: 0.85, green: 0.25, blue: 0.05, alpha: 1).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                g.drawRadialGradient(grad, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                     endCenter: CGPoint(x: 128, y: 128), endRadius: 150, options: [.drawsAfterEndLocation])
            }
            g.setStrokeColor(UIColor(white: 0.05, alpha: 1).cgColor)
            g.setLineWidth(26)
            g.stroke(CGRect(x: 0, y: 0, width: 256, height: 256).insetBy(dx: 6, dy: 6))
            g.setFillColor(UIColor.white.cgColor)
            for (x, y) in [(30, 40), (60, 22), (226, 40), (196, 22), (22, 200), (234, 200)] as [(CGFloat, CGFloat)] {
                g.fillEllipse(in: CGRect(x: x - 7, y: y - 7, width: 14, height: 14))
            }
            g.setStrokeColor(UIColor(white: 0.05, alpha: 0.8).cgColor)
            g.setLineWidth(4)
            for k in 0..<5 {
                g.move(to: CGPoint(x: 128, y: 128))
                let a = CGFloat(k) * .pi / 4 - .pi / 2
                g.addLine(to: CGPoint(x: 128 + cos(a) * 140, y: 128 + sin(a) * 140))
            }
            g.strokePath()
        }
        let m = pbr(.white, rough: 0.45, clearCoat: 0.4)
        m.diffuse.contents = image
        m.isDoubleSided = true
        return m
    }
}

/// 결정적 의사 난수(텍스처가 매번 같게).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
}

private extension UIColor {
    func adjusted(brightness delta: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: min(max(b + delta, 0), 1), alpha: a)
    }
}

// MARK: - 도형 도우미

enum StickerShapes {
    static func node(_ geometry: SCNGeometry, _ material: SCNMaterial, at p: SCNVector3 = SCNVector3Zero,
                     euler: SCNVector3 = SCNVector3Zero, scale: SCNVector3 = SCNVector3(1, 1, 1)) -> SCNNode {
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.position = p
        n.eulerAngles = euler
        // 압출 도형은 경로를 `shapeScale`배로 키워 만들었으므로 노드에서 되돌린다.
        let k: Float = geometry is SCNShape ? 1 / Float(shapeScale) : 1
        n.scale = SCNVector3(scale.x * k, scale.y * k, scale.z * k)
        return n
    }

    /// SCNShape는 IOD 단위(1 안팎)의 작은 둥근 사각형 경로를 빈 도형으로 만드는 경우가 있어(선글라스에서 확인)
    /// 경로를 100배 키워 압출하고 `node(...)`에서 1/100로 줄인다.
    static let shapeScale: CGFloat = 100

    static func extruded(_ path: UIBezierPath, depth: CGFloat, chamfer: CGFloat) -> SCNShape {
        let big = path.copy() as! UIBezierPath
        big.apply(CGAffineTransform(scaleX: shapeScale, y: shapeScale))
        big.flatness = 0.2
        let s = SCNShape(path: big, extrusionDepth: depth * shapeScale)
        s.chamferRadius = chamfer * shapeScale
        s.chamferMode = .both
        return s
    }

    /// 둥근 사각형(원호로 직접). `UIBezierPath(roundedRect:cornerRadius:)`는 반경이 짧은 변의 1/3 이상이면
    /// 다른 곡선으로 경로를 만드는데, SCNShape가 그 경로를 빈 도형으로 만든다(선글라스에서 확인).
    static func roundedRect(_ r: CGRect, radius: CGFloat) -> UIBezierPath {
        let c = min(radius, min(r.width, r.height) / 2)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addArc(withCenter: CGPoint(x: r.maxX - c, y: r.minY + c), radius: c, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addArc(withCenter: CGPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addArc(withCenter: CGPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addArc(withCenter: CGPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        p.close()
        return p
    }

    /// 물방울(위가 뾰족, 아래가 둥근) — 늘어진 강아지 귀.
    static func teardrop(width w: CGFloat, height h: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 0, y: h / 2))
        p.addCurve(to: CGPoint(x: -w / 2, y: -h * 0.25), controlPoint1: CGPoint(x: -w * 0.35, y: h * 0.45),
                   controlPoint2: CGPoint(x: -w * 0.6, y: h * 0.05))
        p.addQuadCurve(to: CGPoint(x: w / 2, y: -h * 0.25), controlPoint: CGPoint(x: 0, y: -h * 0.75))
        p.addCurve(to: CGPoint(x: 0, y: h / 2), controlPoint1: CGPoint(x: w * 0.6, y: h * 0.05),
                   controlPoint2: CGPoint(x: w * 0.35, y: h * 0.45))
        p.close()
        return p
    }

    /// 모서리가 둥근 삼각형(위 꼭짓점) — 고양이 귀.
    static func roundedTriangle(width w: CGFloat, height h: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: -w / 2, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0, y: h), controlPoint: CGPoint(x: -w * 0.28, y: h * 0.75))
        p.addQuadCurve(to: CGPoint(x: w / 2, y: 0), controlPoint: CGPoint(x: w * 0.28, y: h * 0.75))
        p.addQuadCurve(to: CGPoint(x: -w / 2, y: 0), controlPoint: CGPoint(x: 0, y: -h * 0.08))
        p.close()
        return p
    }

    /// 하트(매개변수 곡선).
    static func heart(size: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        let n = 80
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            let pt = CGPoint(x: x / 34 * size, y: y / 34 * size)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.close()
        return p
    }

    /// 리본 날개 하나(가운데에서 바깥으로 퍼지는 둥근 삼각형).
    static func bowLobe(length l: CGFloat, height h: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: .zero)
        p.addCurve(to: CGPoint(x: l, y: h / 2), controlPoint1: CGPoint(x: l * 0.3, y: h * 0.1),
                   controlPoint2: CGPoint(x: l * 0.8, y: h * 0.75))
        p.addQuadCurve(to: CGPoint(x: l, y: -h / 2), controlPoint: CGPoint(x: l * 1.18, y: 0))
        p.addCurve(to: .zero, controlPoint1: CGPoint(x: l * 0.8, y: -h * 0.75), controlPoint2: CGPoint(x: l * 0.3, y: -h * 0.1))
        p.close()
        return p
    }

    /// 나비 날개(위 큰 날개 + 아래 작은 날개, 한쪽).
    static func wing(upper: Bool) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: .zero)
        if upper {
            p.addCurve(to: CGPoint(x: 0.9, y: 0.75), controlPoint1: CGPoint(x: 0.2, y: 0.6), controlPoint2: CGPoint(x: 0.6, y: 0.95))
            p.addCurve(to: CGPoint(x: 0.05, y: 0.02), controlPoint1: CGPoint(x: 1.15, y: 0.4), controlPoint2: CGPoint(x: 0.6, y: 0.05))
        } else {
            p.addCurve(to: CGPoint(x: 0.6, y: -0.65), controlPoint1: CGPoint(x: 0.3, y: -0.15), controlPoint2: CGPoint(x: 0.75, y: -0.3))
            p.addCurve(to: CGPoint(x: 0.03, y: -0.03), controlPoint1: CGPoint(x: 0.4, y: -0.8), controlPoint2: CGPoint(x: 0.1, y: -0.45))
        }
        p.close()
        return p
    }
}

// MARK: - 모델

enum StickerModels {
    typealias S = StickerShapes
    typealias M = StickerMaterials

    /// 효과별 부품. 스티커가 아니면 빈 배열.
    static func parts(for kind: EffectKind) -> [StickerPart] {
        switch kind {
        case .puppyFace: return [puppyEars, animalNose(id: "puppyNose", dark: true), puppyTongue]
        case .catFace: return [catEars, whiskers(id: "catWhiskers", nose: UIColor(red: 1, green: 0.55, blue: 0.62, alpha: 1))]
        case .bunnyEars: return [bunnyEars, whiskers(id: "bunnyWhiskers", nose: UIColor(red: 1, green: 0.5, blue: 0.6, alpha: 1))]
        case .bearEars: return [bearEars, bearMuzzle]
        case .mouseEars: return [mouseEars, whiskers(id: "mouseWhiskers", nose: UIColor(red: 1, green: 0.45, blue: 0.55, alpha: 1))]
        case .flowerCrown: return [flowerCrown]
        case .crown: return [crown]
        case .heartHalo: return [heart]
        case .sunglasses: return [glasses(id: "sunglasses", sun: true)]
        case .nerdGlasses: return [glasses(id: "nerdGlasses", sun: false)]
        case .ribbon: return [ribbon]
        case .topHat: return [topHat]
        case .gradCap: return [gradCap]
        case .butterflies: return [butterfly]
        case .angelHalo: return [halo]
        case .devilHorns: return [horns]
        default: return []
        }
    }

    // 동물 귀

    static let puppyEars = StickerPart(id: "puppyEars", anchor: .eyes, viewCenter: [0, 0.6], viewHalf: 2.4, occluded: true, glow: false) {
        let root = SCNNode()
        let brown = UIColor(red: 0.5, green: 0.32, blue: 0.18, alpha: 1)
        for side: Float in [-1, 1] {
            let ear = SCNNode()
            ear.addChildNode(S.node(S.extruded(S.teardrop(width: 0.95, height: 1.6), depth: 0.16, chamfer: 0.07), M.fur(brown)))
            ear.addChildNode(S.node(S.extruded(S.teardrop(width: 0.6, height: 1.1), depth: 0.04, chamfer: 0.02),
                                    M.fur(UIColor(red: 0.72, green: 0.5, blue: 0.4, alpha: 1)), at: SCNVector3(0, -0.12, 0.1)))
            ear.position = SCNVector3(side * 1.12, 0.75, -0.75)
            ear.eulerAngles = SCNVector3(0.1, side * 0.55, side * 0.32)
            root.addChildNode(ear)
        }
        return root
    }

    static let catEars = StickerPart(id: "catEars", anchor: .eyes, viewCenter: [0, 1.2], viewHalf: 1.8, occluded: true, glow: false) {
        let root = SCNNode()
        let fur = UIColor(red: 0.95, green: 0.62, blue: 0.3, alpha: 1)
        for side: Float in [-1, 1] {
            let ear = SCNNode()
            ear.addChildNode(S.node(S.extruded(S.roundedTriangle(width: 0.85, height: 1.0), depth: 0.14, chamfer: 0.05), M.fur(fur)))
            ear.addChildNode(S.node(S.extruded(S.roundedTriangle(width: 0.5, height: 0.65), depth: 0.03, chamfer: 0.015),
                                    M.fur(UIColor(red: 1, green: 0.72, blue: 0.75, alpha: 1)), at: SCNVector3(0, 0.1, 0.09)))
            ear.position = SCNVector3(side * 0.72, 1.35, -0.75)
            ear.eulerAngles = SCNVector3(-0.15, side * 0.25, -side * 0.28)
            root.addChildNode(ear)
        }
        return root
    }

    static let bunnyEars = StickerPart(id: "bunnyEars", anchor: .eyes, viewCenter: [0, 2.0], viewHalf: 2.1, occluded: true, glow: false) {
        let root = SCNNode()
        for side: Float in [-1, 1] {
            let ear = SCNNode()
            ear.addChildNode(S.node(SCNCapsule(capRadius: 0.24, height: 2.0), M.fur(UIColor(white: 0.97, alpha: 1)),
                                    scale: SCNVector3(1, 1, 0.42)))
            ear.addChildNode(S.node(SCNCapsule(capRadius: 0.13, height: 1.55), M.fur(UIColor(red: 1, green: 0.74, blue: 0.8, alpha: 1)),
                                    at: SCNVector3(0, -0.05, 0.08), scale: SCNVector3(1, 1, 0.3)))
            ear.position = SCNVector3(side * 0.42, 2.45, -0.95)
            ear.eulerAngles = SCNVector3(-0.1, 0, -side * 0.16)
            root.addChildNode(ear)
        }
        // 머리띠: 머리 위를 지나는 고리(아래 반은 머리에 가려진다).
        let band = S.node(SCNTorus(ringRadius: 1.28, pipeRadius: 0.07), M.satin(UIColor(red: 1, green: 0.55, blue: 0.72, alpha: 1)),
                          at: SCNVector3(0, 0.25, -1.05), euler: SCNVector3(Float.pi / 2, 0, 0))
        root.addChildNode(band)
        return root
    }

    static let bearEars = StickerPart(id: "bearEars", anchor: .eyes, viewCenter: [0, 1.1], viewHalf: 1.9, occluded: true, glow: false) {
        let root = SCNNode()
        let brown = UIColor(red: 0.45, green: 0.28, blue: 0.16, alpha: 1)
        for side: Float in [-1, 1] {
            let ear = SCNNode()
            ear.addChildNode(S.node(SCNSphere(radius: 0.45), M.fur(brown), scale: SCNVector3(1, 1, 0.55)))
            ear.addChildNode(S.node(SCNSphere(radius: 0.27), M.fur(UIColor(red: 0.78, green: 0.58, blue: 0.42, alpha: 1)),
                                    at: SCNVector3(0, -0.02, 0.17), scale: SCNVector3(1, 1, 0.35)))
            ear.position = SCNVector3(side * 1.0, 1.45, -1.0)
            ear.eulerAngles = SCNVector3(0, side * 0.35, 0)
            root.addChildNode(ear)
        }
        return root
    }

    static let mouseEars = StickerPart(id: "mouseEars", anchor: .eyes, viewCenter: [0, 1.3], viewHalf: 2.0, occluded: true, glow: false) {
        let root = SCNNode()
        for side: Float in [-1, 1] {
            let ear = SCNNode()
            ear.addChildNode(S.node(SCNCylinder(radius: 0.62, height: 0.1), M.fur(UIColor(white: 0.68, alpha: 1)),
                                    euler: SCNVector3(Float.pi / 2, 0, 0)))
            ear.addChildNode(S.node(SCNCylinder(radius: 0.44, height: 0.04), M.satin(UIColor(red: 1, green: 0.66, blue: 0.72, alpha: 1)),
                                    at: SCNVector3(0, -0.03, 0.06), euler: SCNVector3(Float.pi / 2, 0, 0)))
            ear.position = SCNVector3(side * 1.05, 1.55, -0.95)
            ear.eulerAngles = SCNVector3(0, side * 0.3, side * -0.15)
            root.addChildNode(ear)
        }
        return root
    }

    // 코·입

    static func animalNose(id: String, dark: Bool) -> StickerPart {
        StickerPart(id: id, anchor: .nose, viewCenter: [0, 0], viewHalf: 0.5, occluded: false, glow: false) {
            S.node(SCNSphere(radius: 0.2), dark ? M.glossyBlack : M.glossy(.systemPink), scale: SCNVector3(1.35, 0.9, 0.8))
        }
    }

    static let puppyTongue = StickerPart(id: "puppyTongue", anchor: .mouth, viewCenter: [0, -0.35], viewHalf: 0.55, occluded: false, glow: false) {
        let root = SCNNode()
        root.addChildNode(S.node(SCNCapsule(capRadius: 0.2, height: 0.75), M.glossy(UIColor(red: 0.95, green: 0.38, blue: 0.48, alpha: 1)),
                                 at: SCNVector3(0, -0.3, 0.1), scale: SCNVector3(1, 1, 0.35)))
        return root
    }

    static func whiskers(id: String, nose: UIColor) -> StickerPart {
        StickerPart(id: id, anchor: .nose, viewCenter: [0, -0.1], viewHalf: 1.3, occluded: false, glow: false) {
            let root = SCNNode()
            root.addChildNode(S.node(S.extruded(S.heart(size: 0.32), depth: 0.1, chamfer: 0.04), M.glossy(nose),
                                     euler: SCNVector3(0, 0, Float.pi)))
            for side: Float in [-1, 1] {
                for k: Float in [-1, 0, 1] {
                    let w = S.node(SCNCylinder(radius: 0.012, height: 0.85), M.glossy(UIColor(white: 0.97, alpha: 1)))
                    w.position = SCNVector3(side * 0.62, -0.12 + k * 0.1, 0)
                    w.eulerAngles = SCNVector3(0, 0, Float.pi / 2 + side * k * 0.18)
                    root.addChildNode(w)
                }
            }
            return root
        }
    }

    static let bearMuzzle = StickerPart(id: "bearMuzzle", anchor: .nose, viewCenter: [0, -0.2], viewHalf: 0.7, occluded: false, glow: false) {
        let root = SCNNode()
        root.addChildNode(S.node(SCNSphere(radius: 0.5), M.fur(UIColor(red: 0.85, green: 0.68, blue: 0.5, alpha: 1)),
                                 at: SCNVector3(0, -0.25, -0.1), scale: SCNVector3(1.1, 0.75, 0.55)))
        root.addChildNode(S.node(SCNSphere(radius: 0.2), M.glossyBlack, at: SCNVector3(0, 0, 0.2), scale: SCNVector3(1.3, 0.85, 0.8)))
        return root
    }

    // 머리 장식

    static let flowerCrown = StickerPart(id: "flowerCrown", anchor: .eyes, viewCenter: [0, 1.4], viewHalf: 1.8, occluded: true, glow: false) {
        let root = SCNNode()
        let ring = SCNNode()
        ring.position = SCNVector3(0, 1.35, -1.35)
        ring.eulerAngles = SCNVector3(0.3, 0, 0)
        root.addChildNode(ring)
        ring.addChildNode(S.node(SCNTorus(ringRadius: 1.3, pipeRadius: 0.045), M.satin(UIColor(red: 0.25, green: 0.55, blue: 0.25, alpha: 1))))
        let colors: [UIColor] = [UIColor(red: 1, green: 0.62, blue: 0.75, alpha: 1), UIColor(red: 1, green: 0.95, blue: 0.97, alpha: 1),
                                 UIColor(red: 1, green: 0.78, blue: 0.4, alpha: 1), UIColor(red: 0.85, green: 0.6, blue: 1, alpha: 1)]
        let count = 16
        for i in 0..<count {
            let a = Float(i) / Float(count) * 2 * .pi
            let flower = SCNNode()
            let size: Float = i % 2 == 0 ? 1 : 0.75
            for k in 0..<5 {
                let pa = Float(k) / 5 * 2 * .pi
                flower.addChildNode(S.node(SCNSphere(radius: 0.13), M.satin(colors[i % colors.count]),
                                           at: SCNVector3(cos(pa) * 0.13, sin(pa) * 0.13, 0), euler: SCNVector3(0, 0, pa),
                                           scale: SCNVector3(1, 0.62, 0.25)))
            }
            flower.addChildNode(S.node(SCNSphere(radius: 0.06), M.satin(UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)),
                                       at: SCNVector3(0, 0, 0.03)))
            flower.scale = SCNVector3(size, size, size)
            // 고리 둘레에 바깥을 보게.
            flower.position = SCNVector3(sin(a) * 1.3, 0.05, cos(a) * 1.3)
            flower.eulerAngles = SCNVector3(0, a, 0)
            ring.addChildNode(flower)
        }
        return root
    }

    static let crown = StickerPart(id: "crown", anchor: .eyes, viewCenter: [0, 1.95], viewHalf: 1.2, occluded: true, glow: false) {
        let root = SCNNode()
        let body = SCNNode()
        body.position = SCNVector3(0, 1.72, -1.25)
        body.eulerAngles = SCNVector3(0.22, 0, 0)
        root.addChildNode(body)
        body.addChildNode(S.node(SCNTube(innerRadius: 0.8, outerRadius: 0.86, height: 0.34), M.gold))
        let spikes = 10
        for i in 0..<spikes {
            let a = Float(i) / Float(spikes) * 2 * .pi
            let spike = S.node(SCNCone(topRadius: 0.0, bottomRadius: 0.16, height: 0.5), M.gold,
                               at: SCNVector3(sin(a) * 0.83, 0.42, cos(a) * 0.83))
            body.addChildNode(spike)
            body.addChildNode(S.node(SCNSphere(radius: 0.065), M.pbr(UIColor(white: 0.96, alpha: 1), rough: 0.15, clearCoat: 1),
                                     at: SCNVector3(sin(a) * 0.83, 0.7, cos(a) * 0.83)))
            let gemColor: UIColor = i % 2 == 0 ? UIColor(red: 0.85, green: 0.05, blue: 0.15, alpha: 1)
                : UIColor(red: 0.1, green: 0.3, blue: 0.95, alpha: 1)
            body.addChildNode(S.node(SCNSphere(radius: 0.085), M.gem(gemColor), at: SCNVector3(sin(a) * 0.87, 0, cos(a) * 0.87),
                                     scale: SCNVector3(1, 1, 0.6)))
        }
        return root
    }

    static let heart = StickerPart(id: "heart", anchor: .free, viewCenter: [0, 0], viewHalf: 0.62, occluded: false, glow: false) {
        S.node(S.extruded(S.heart(size: 1.0), depth: 0.3, chamfer: 0.14), M.glossy(UIColor(red: 0.95, green: 0.1, blue: 0.3, alpha: 1)),
               euler: SCNVector3(-0.15, 0.25, 0))
    }

    static func glasses(id: String, sun: Bool) -> StickerPart {
        StickerPart(id: id, anchor: .eyes, viewCenter: [0, 0], viewHalf: 1.5, occluded: true, glow: false) {
            let root = SCNNode()
            let frameMat = sun ? M.glossyBlack : M.pbr(UIColor(red: 0.35, green: 0.2, blue: 0.1, alpha: 1), rough: 0.3, clearCoat: 1)
            let lensW: CGFloat = sun ? 0.9 : 0.86, lensH: CGFloat = sun ? 0.64 : 0.7
            let rim: CGFloat = sun ? 0.09 : 0.05
            for side: CGFloat in [-1, 1] {
                let cx = side * 0.56
                let outer = S.roundedRect(CGRect(x: cx - lensW / 2 - rim, y: -lensH / 2 - rim, width: lensW + 2 * rim, height: lensH + 2 * rim),
                                         radius: sun ? 0.28 : 0.35)
                let inner = S.roundedRect(CGRect(x: cx - lensW / 2, y: -lensH / 2, width: lensW, height: lensH),
                                         radius: sun ? 0.22 : 0.3)
                // 테 = 바깥 둥근 사각형에서 안쪽을 뚫은 모양(짝홀 규칙). 방향 뒤집기 방식은 SCNShape가 도형을 버리는 경우가 있었다.
                let frame = UIBezierPath(cgPath: outer.cgPath)
                frame.append(inner)
                frame.usesEvenOddFillRule = true
                root.addChildNode(S.node(S.extruded(frame, depth: 0.07, chamfer: 0.02), frameMat, at: SCNVector3(0, 0, 0.2)))
                let lensMat = sun ? M.glass(UIColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1), opacity: 0.88)
                    : M.glass(UIColor(white: 0.95, alpha: 1), opacity: 0.18)
                root.addChildNode(S.node(S.extruded(inner, depth: 0.02, chamfer: 0.008), lensMat, at: SCNVector3(0, 0, 0.2)))
                // 다리: 뒤로 뻗어 머리에 가려진다.
                root.addChildNode(S.node(SCNBox(width: 0.05, height: 0.07, length: 1.9, chamferRadius: 0.02), frameMat,
                                         at: SCNVector3(Float(side * (0.56 + lensW / 2 + rim)), 0.1, -0.75)))
            }
            // 코다리
            root.addChildNode(S.node(SCNTorus(ringRadius: 0.1, pipeRadius: 0.025), frameMat, at: SCNVector3(0, 0.12, 0.2),
                                     euler: SCNVector3(Float.pi / 2, 0, 0), scale: SCNVector3(1, 1, 0.6)))
            return root
        }
    }

    static let ribbon = StickerPart(id: "ribbon", anchor: .eyes, viewCenter: [0.75, 1.7], viewHalf: 0.8, occluded: true, glow: false) {
        let root = SCNNode()
        let bow = SCNNode()
        bow.position = SCNVector3(0.75, 1.62, -0.35)
        bow.eulerAngles = SCNVector3(-0.2, 0.3, -0.35)
        root.addChildNode(bow)
        let red = M.satin(UIColor(red: 0.85, green: 0.05, blue: 0.2, alpha: 1))
        for side: Float in [-1, 1] {
            let lobe = S.node(S.extruded(S.bowLobe(length: 0.6, height: 0.5), depth: 0.14, chamfer: 0.06), red)
            lobe.eulerAngles = SCNVector3(0, side < 0 ? Float.pi : 0, 0)
            bow.addChildNode(lobe)
            let tail = S.node(SCNBox(width: 0.14, height: 0.5, length: 0.04, chamferRadius: 0.02), red,
                              at: SCNVector3(side * 0.12, -0.3, 0), euler: SCNVector3(0, 0, side * 0.35))
            bow.addChildNode(tail)
        }
        bow.addChildNode(S.node(SCNSphere(radius: 0.12), red, at: SCNVector3(0, 0, 0.05), scale: SCNVector3(1, 1.1, 0.8)))
        return root
    }

    static let topHat = StickerPart(id: "topHat", anchor: .eyes, viewCenter: [0, 2.2], viewHalf: 1.45, occluded: true, glow: false) {
        let root = SCNNode()
        let hat = SCNNode()
        hat.position = SCNVector3(0, 1.68, -1.3)
        hat.eulerAngles = SCNVector3(0.12, 0, 0.06)
        root.addChildNode(hat)
        let felt = M.felt(UIColor(white: 0.08, alpha: 1))
        hat.addChildNode(S.node(SCNCylinder(radius: 1.3, height: 0.06), felt))
        hat.addChildNode(S.node(SCNCylinder(radius: 0.78, height: 1.25), felt, at: SCNVector3(0, 0.63, 0)))
        hat.addChildNode(S.node(SCNCylinder(radius: 0.795, height: 0.22), M.satin(UIColor(red: 0.75, green: 0.05, blue: 0.15, alpha: 1)),
                                at: SCNVector3(0, 0.15, 0)))
        return root
    }

    static let gradCap = StickerPart(id: "gradCap", anchor: .eyes, viewCenter: [0, 1.95], viewHalf: 1.6, occluded: true, glow: false) {
        let root = SCNNode()
        let cap = SCNNode()
        cap.position = SCNVector3(0, 1.62, -1.3)
        cap.eulerAngles = SCNVector3(0.3, 0, 0)
        root.addChildNode(cap)
        let black = M.pbr(UIColor(white: 0.06, alpha: 1), rough: 0.6)
        cap.addChildNode(S.node(SCNCylinder(radius: 0.98, height: 0.45), black))
        cap.addChildNode(S.node(SCNBox(width: 2.2, height: 0.06, length: 2.2, chamferRadius: 0.02), black, at: SCNVector3(0, 0.26, 0),
                                euler: SCNVector3(0, Float.pi / 4, 0)))
        cap.addChildNode(S.node(SCNSphere(radius: 0.08), M.gold, at: SCNVector3(0, 0.32, 0)))
        cap.addChildNode(S.node(SCNCylinder(radius: 0.02, height: 1.0), M.gold, at: SCNVector3(0.5, 0.3, 0.5),
                                euler: SCNVector3(Float.pi / 2, Float.pi / 4, 0)))
        cap.addChildNode(S.node(SCNCylinder(radius: 0.02, height: 0.55), M.gold, at: SCNVector3(0.99, 0.02, 0.99)))
        cap.addChildNode(S.node(SCNCone(topRadius: 0.03, bottomRadius: 0.1, height: 0.35), M.gold, at: SCNVector3(0.99, -0.35, 0.99)))
        return root
    }

    static let butterfly = StickerPart(id: "butterfly", anchor: .free, viewCenter: [0, 0], viewHalf: 1.05, occluded: false, glow: false) {
        let root = SCNNode()
        let wing = M.butterflyWing
        for side: Float in [-1, 1] {
            for upper in [true, false] {
                let w = S.node(S.extruded(S.wing(upper: upper), depth: 0.02, chamfer: 0.005), wing)
                w.eulerAngles = SCNVector3(0, side < 0 ? Float.pi - 0.45 : 0.45, 0)
                root.addChildNode(w)
            }
        }
        root.addChildNode(S.node(SCNCapsule(capRadius: 0.05, height: 0.8), M.pbr(UIColor(white: 0.1, alpha: 1), rough: 0.4), at: SCNVector3(0, 0, 0.02)))
        root.eulerAngles = SCNVector3(-0.35, 0, 0.15)
        return root
    }

    static let halo = StickerPart(id: "halo", anchor: .eyes, viewCenter: [0, 2.35], viewHalf: 1.1, occluded: false, glow: true) {
        let m = M.gold
        m.emission.contents = UIColor(red: 1, green: 0.85, blue: 0.45, alpha: 1)
        m.emission.intensity = 0.6
        return S.node(SCNTorus(ringRadius: 0.82, pipeRadius: 0.075), m, at: SCNVector3(0, 2.3, -1.2), euler: SCNVector3(1.25, 0, 0))
    }

    static let horns = StickerPart(id: "horns", anchor: .eyes, viewCenter: [0, 1.75], viewHalf: 1.3, occluded: true, glow: false) {
        let root = SCNNode()
        let red = M.glossy(UIColor(red: 0.7, green: 0.03, blue: 0.08, alpha: 1))
        for side: Float in [-1, 1] {
            // 가늘어지는 원뿔대 5마디를 조금씩 바깥으로 휘게 이어 붙인다.
            var parent = SCNNode()
            parent.position = SCNVector3(side * 0.62, 1.45, -0.55)
            parent.eulerAngles = SCNVector3(-0.15, 0, -side * 0.35)
            root.addChildNode(parent)
            let segments = 5
            for k in 0..<segments {
                let r0 = CGFloat(0.17) * CGFloat(segments - k) / CGFloat(segments)
                let r1 = CGFloat(0.17) * CGFloat(segments - k - 1) / CGFloat(segments) + 0.01
                let h: CGFloat = 0.17
                let seg = S.node(SCNCone(topRadius: r1, bottomRadius: r0, height: h), red, at: SCNVector3(0, Float(h / 2), 0))
                let joint = SCNNode()
                joint.addChildNode(seg)
                parent.addChildNode(joint)
                let next = SCNNode()
                next.position = SCNVector3(0, Float(h), 0)
                next.eulerAngles = SCNVector3(0, 0, side * 0.28)
                joint.addChildNode(next)
                parent = next
            }
        }
        return root
    }
}
