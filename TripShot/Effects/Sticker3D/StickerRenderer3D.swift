// 3D 스티커 부품을 SceneKit으로 오프스크린 렌더해 CIImage로 캐시한다(R2-S2).
// 라이브는 캐시에 없으면 백그라운드에서 렌더를 시작하고 이번 프레임은 건너뛴다. 저장은 그 자리에서 고화질로 렌더한다.
import CoreImage
import Metal
import SceneKit
import UIKit

/// 렌더된 부품 한 장.
struct RenderedPart {
    let image: CIImage
    /// 부품 기준 랜드마크가 놓일 픽셀(CIImage 좌표, 원점 좌하단).
    let anchor: CGPoint
    /// 1 IOD당 픽셀.
    let pixelsPerUnit: CGFloat
}

final class StickerRenderer3D: @unchecked Sendable {
    static let shared = StickerRenderer3D()

    /// 고개 좌우 각도 단계(도). Vision yaw를 가장 가까운 단계로 맞춘다.
    static let yawSteps: [Int] = [-30, -15, 0, 15, 30]
    /// 라이브·저장 렌더 크기(정사각형 한 변).
    static let liveSize = 512
    static let fullSize = 1400
    /// 캐시 최대 장수(라이브 크기 1장 ≈ 1MB). 저장용 큰 렌더(장당 약 8MB)는 캐시하지 않는다.
    static let cacheLimit = 30

    private let queue = DispatchQueue(label: "tripshot.sticker3d", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [String: RenderedPart] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var renderer: SCNRenderer = {
        let r = SCNRenderer(device: device, options: nil)
        r.autoenablesDefaultLighting = false
        return r
    }()
    private lazy var environment: UIImage = Self.makeEnvironment()

    /// Vision yaw(라디안) → 가장 가까운 각도 단계.
    static func yawStep(for yaw: CGFloat) -> Int {
        // TODO(검증): Vision yaw 부호가 화면 기준과 반대면 여기서 부호를 뒤집는다(실기기에서 고개를 돌려 확인).
        let degrees = Double(yaw) * 180 / .pi
        return yawSteps.min { abs(Double($0) - degrees) < abs(Double($1) - degrees) } ?? 0
    }

    private static func key(_ part: StickerPart, yaw: Int, size: Int) -> String { "\(part.id)|\(yaw)|\(size)" }

    /// 라이브용: 캐시에 있으면 바로, 없으면 렌더를 예약하고 같은 부품의 다른 각도(있으면)를 대신 준다.
    func cachedOrSchedule(_ part: StickerPart, yaw: Int, size: Int = StickerRenderer3D.liveSize) -> RenderedPart? {
        let k = Self.key(part, yaw: yaw, size: size)
        let (hit, fallback, shouldSchedule): (RenderedPart?, RenderedPart?, Bool) = lock.withLock {
            if let hit = cache[k] { return (hit, nil, false) }
            let fb = Self.yawSteps.sorted { abs($0 - yaw) < abs($1 - yaw) }
                .lazy.compactMap { self.cache[Self.key(part, yaw: $0, size: size)] }.first
            let schedule = !pending.contains(k)
            if schedule { pending.insert(k) }
            return (nil, fb, schedule)
        }
        if let hit { return hit }
        if shouldSchedule {
            queue.async { [self] in
                let rendered = renderNow(part, yaw: yaw, size: size)
                lock.withLock {
                    pending.remove(k)
                    if let rendered { store(k, rendered) }
                }
            }
        }
        return fallback
    }

    /// 저장용: 그 자리에서 렌더(캐시 사용). 호출 스레드를 막는다.
    func renderSync(_ part: StickerPart, yaw: Int, size: Int = StickerRenderer3D.fullSize) -> RenderedPart? {
        let k = Self.key(part, yaw: yaw, size: size)
        if let hit = lock.withLock({ cache[k] }) { return hit }
        let rendered = queue.sync { renderNow(part, yaw: yaw, size: size) }
        if let rendered, size <= Self.liveSize { lock.withLock { store(k, rendered) } }
        return rendered
    }

    /// 효과를 고르자마자 라이브 크기로 모든 각도를 미리 렌더한다.
    func prewarm(_ kind: EffectKind) {
        for part in StickerModels.parts(for: kind) {
            let yaws = part.anchor == .free ? [0] : Self.yawSteps
            for yaw in yaws { _ = cachedOrSchedule(part, yaw: yaw) }
        }
    }

    /// 선택 화면 타일용 작은 그림(정면).
    func thumbnail(_ kind: EffectKind, size: Int = 160) -> UIImage? {
        guard let part = StickerModels.parts(for: kind).first,
              let rendered = renderSync(part, yaw: 0, size: size) else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(rendered.image, from: rendered.image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func store(_ key: String, _ part: RenderedPart) {
        cache[key] = part
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    // MARK: 렌더 (queue 전용)

    private func renderNow(_ part: StickerPart, yaw: Int, size: Int) -> RenderedPart? {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 1.3

        // 부품 좌표계: 원점 = 기준 랜드마크. 머리 중심은 눈 중점 기준 값에서 랜드마크 오프셋을 뺀 곳.
        let offset = HeadGeometry.offset(of: part.anchor)
        let pivot = HeadGeometry.headCenter - offset
        let yawRad = Float(yaw) * .pi / 180

        let container = SCNNode()
        container.simdPosition = part.anchor == .free ? .zero : pivot
        container.eulerAngles.y = part.anchor == .free ? 0 : yawRad
        let inner = SCNNode()
        inner.simdPosition = part.anchor == .free ? .zero : -pivot
        container.addChildNode(inner)
        scene.rootNode.addChildNode(container)

        inner.addChildNode(part.build())
        if part.occluded {
            let head = SCNNode(geometry: SCNSphere(radius: 1))
            head.geometry?.materials = [StickerMaterials.occluder]
            head.simdPosition = pivot
            head.simdScale = HeadGeometry.headRadii
            head.renderingOrder = -10
            inner.addChildNode(head)
        }

        // 조명: 위·왼쪽 앞에서 비추는 주광 + 약한 보조광(주변광 반사는 환경 이미지).
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.7, -0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 180
        scene.rootNode.addChildNode(fill)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = Double(part.viewHalf)
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 100
        camera.simdPosition = SIMD3(part.viewCenter.x, part.viewCenter.y, 30)
        scene.rootNode.addChildNode(camera)

        renderer.scene = scene
        renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let scale = ci.extent.width / CGFloat(size)          // 스냅샷이 화면 배율로 나올 수 있다
        let ppu = CGFloat(size) * scale / CGFloat(2 * part.viewHalf)

        // 기준 랜드마크(부품 원점)가 고개 회전 뒤 놓이는 위치.
        var origin = SIMD3<Float>(0, 0, 0)
        if part.anchor != .free {
            let local = -pivot
            let c = cos(yawRad), s = sin(yawRad)
            origin = pivot + SIMD3(local.x * c + local.z * s, local.y, -local.x * s + local.z * c)
        }
        let half = CGFloat(size) * scale / 2
        let anchor = CGPoint(x: half + CGFloat(origin.x - part.viewCenter.x) * ppu,
                             y: half + CGFloat(origin.y - part.viewCenter.y) * ppu)
        return RenderedPart(image: ci, anchor: anchor, pixelsPerUnit: ppu)
    }

    /// 주변광 반사용 환경 이미지(등장방형): 밝은 하늘 → 따뜻한 바닥 그라데이션 + 소프트박스 두 개.
    private static func makeEnvironment() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            let colors = [UIColor(red: 0.95, green: 0.97, blue: 1, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 1).cgColor,
                          UIColor(red: 0.35, green: 0.3, blue: 0.27, alpha: 1).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            g.setFillColor(UIColor.white.cgColor)
            g.fillEllipse(in: CGRect(x: 90, y: 40, width: 110, height: 60))
            g.setFillColor(UIColor(white: 1, alpha: 0.7).cgColor)
            g.fillEllipse(in: CGRect(x: 330, y: 55, width: 80, height: 45))
        }
    }
}
