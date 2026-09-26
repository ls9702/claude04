// 라이브 보정 프리뷰 화면: 보정된 CIImage를 MTKView에 aspect-fill로 그린다. 탭 포커스 좌표 변환 포함.
import CoreImage
import Metal
import MetalKit
import SwiftUI
import UIKit

/// `MTKView` 기반 프리뷰. 렌더러(`Coordinator`)는 `CaptureViewModel`이 소유하고 여기로 넘긴다
/// (카메라 프레임 콜백이 뷰 생명주기와 무관하게 같은 렌더러에 제출할 수 있도록).
///
/// 그리기 흐름(요청 시 그리기):
/// 비디오 큐 `beginFrame()`(백프레셔 게이트) → `LivePipeline.process` → `submit(_:)` → 메인에서 `view.draw()`
/// → `draw(in:)`에서 CIContext가 드로어블 텍스처에 렌더 → GPU 완료 핸들러에서 게이트 해제.
/// 게이트 한도가 1이라 "프레임 도착 ~ GPU 완료" 구간에 프레임은 최대 1장만 있고, 그 사이 도착한 프레임은 버려진다.
struct MetalPreviewView: UIViewRepresentable {
    let coordinator: Coordinator
    /// 탭 포커스: (카메라 장치 좌표 0~1, 뷰 좌표). 메인에서 호출된다.
    var onTap: ((_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator { coordinator }

    func makeUIView(context: Context) -> MTKView {
        let c = context.coordinator
        // 시그니처: MTKView.init(frame: CGRect, device: MTLDevice?)
        let view = MTKView(frame: .zero, device: c.device)
        view.isPaused = true                 // 자체 타이머로 그리지 않는다
        view.enableSetNeedsDisplay = false   // setNeedsDisplay가 아니라 draw() 수동 호출로만 그린다
        view.framebufferOnly = false         // Core Image가 드로어블 텍스처에 직접 쓰므로 필요
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isOpaque = true
        c.attach(view)   // 뷰 delegate 연결 포함
        c.onTap = onTap

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onTap = onTap
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach(uiView)
    }

    // MARK: - 순수 함수 (테스트 대상)

    enum FitMode { case fill, fit }

    /// `image` 크기의 사각형을 `drawable` 안에 비율을 유지해 배치한 사각형(중심 정렬).
    /// `.fill`은 드로어블을 빈틈없이 덮도록(넘치는 쪽은 잘림), `.fit`은 전체가 보이도록(남는 쪽은 여백).
    /// 좌표계 방향과 무관하다(중심 대칭이므로 y-up·y-down 어느 쪽에도 그대로 쓸 수 있다).
    static func fitRect(image: CGRect, drawable: CGSize, mode: FitMode) -> CGRect {
        guard image.width > 0, image.height > 0, drawable.width > 0, drawable.height > 0 else {
            return CGRect(origin: .zero, size: drawable)
        }
        let sx = drawable.width / image.width
        let sy = drawable.height / image.height
        let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
        let w = image.width * scale
        let h = image.height * scale
        return CGRect(x: (drawable.width - w) / 2, y: (drawable.height - h) / 2, width: w, height: h)
    }

    /// 뷰의 탭 위치 → `AVCaptureDevice.focusPointOfInterest` 좌표.
    ///
    /// 가정: 앱 세로 고정, 후면 카메라(미러 없음 — 전면은 `mirrored`), 비디오 연결 `videoRotationAngle = 90`(프레임이 세로로 선 상태),
    /// 프리뷰는 `imageSize` 비율의 프레임을 뷰에 aspect-fill로 그림.
    ///
    /// 유도:
    /// 1. aspect-fill로 잘린 부분을 보정해, 뷰 좌표를 "세로 프레임 기준 정규화 좌표" (u, v)로 바꾼다.
    ///    r = fitRect(imageSize, viewSize, .fill), u = (x − r.minX) / r.width, v = (y − r.minY) / r.height
    ///    (u: 왼→오 0→1, v: 위→아래 0→1).
    /// 2. 장치 좌표계는 회전하지 않은 센서 프레임(가로, 홈 버튼이 오른쪽인 landscapeRight) 기준으로
    ///    (0,0) = 좌상단, (1,1) = 우하단이다.
    /// 3. 세로 프레임은 센서 프레임을 시계 방향으로 90° 돌린 것이다. 센서 좌표 (sx, sy)가 세로 좌표로
    ///    (u, v) = (1 − sy, sx)로 간다(센서의 왼쪽 열 → 세로 프레임의 윗줄, 센서 좌상단 (0,0) → 세로 우상단 (1,0)).
    /// 4. 역변환: sx = v, sy = 1 − u. 즉 devicePoint = (v, 1 − u).
    ///    잘림이 없을 때 이는 널리 쓰이는 `(tapY / height, 1 − tapX / width)`와 같다.
    ///    예: 화면 중앙 → (0.5, 0.5), 좌상단 → (0, 1), 우상단 → (0, 0), 좌하단 → (1, 1).
    /// 5. 미러(전면 카메라, 프리뷰만 좌우 반전): 화면의 가로축(u)이 뒤집혀 보이므로 u → 1 − u 후 같은 식을 쓴다.
    ///    devicePoint = (v, u). 예: 좌상단 → (0, 0). 세로축(v)은 미러와 무관하다.
    ///    TODO(검증): 전면 센서 좌표계가 후면과 같은 규약(landscapeRight 기준)인지 실기기에서 확인. 대부분 전면은
    ///               포커스 POI를 지원하지 않아 노출 POI만 적용된다(`isExposurePointOfInterestSupported`).
    /// 결과는 0~1로 자른다.
    static func devicePoint(fromViewPoint point: CGPoint,
                            viewSize: CGSize,
                            imageSize: CGSize = CGSize(width: 3, height: 4),
                            mirrored: Bool = false) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let r = fitRect(image: CGRect(origin: .zero, size: imageSize), drawable: viewSize, mode: .fill)
        var u = (point.x - r.minX) / r.width
        if mirrored { u = 1 - u }
        let v = (point.y - r.minY) / r.height
        func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
        return CGPoint(x: clamp(v), y: clamp(1 - u))
    }

    // MARK: - 렌더러

    /// 프리뷰 렌더러.
    ///
    /// 스레드 규칙:
    /// - `beginFrame()`·`cancelFrame()`·`submit(_:)`·`setActive(_:)`·`takeStats()`: 아무 스레드(주로 비디오 큐). 잠금으로 보호.
    /// - `@MainActor` 표시 멤버(그리기·탭·뷰 연결): 메인.
    /// - CIContext는 **프리뷰 전용**으로 하나 만든다. `EnhanceRenderer`(저장·앨범)의 잠금과 경쟁하지 않는다.
    ///
    /// `MTKViewDelegate`는 이 클래스가 아니라 별도 `ViewDelegate`가 채택한다. SDK에서 이 프로토콜이 `@MainActor`면
    /// 주 선언에서 채택한 클래스 전체가 메인 액터로 추론되어, 비디오 큐에서 부르는 `submit` 등이 격리 위반이 되기 때문이다.
    final class Coordinator: NSObject, @unchecked Sendable {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext?
        /// 드로어블(.bgra8Unorm)에 쓸 출력 색공간.
        /// TODO(검증): 화면은 P3지만 CAMetalLayer의 색공간 태그를 지정하지 않으면 .bgra8Unorm 값은 sRGB로 해석된다고 보고
        ///            sRGB로 렌더한다. 실기기에서 채도가 원본(사진 앱)과 비교해 차이가 크면
        ///            `(view.layer as? CAMetalLayer)?.colorspace = displayP3` 지정 + 여기를 `EnhanceRenderer.previewColorSpace`로 바꾼다.
        private let outputColorSpace: CGColorSpace = EnhanceRenderer.sRGB

        /// 백프레셔 게이트(프레임 도착 ~ GPU 완료).
        let gate = LockedFrameGate(limit: 1)

        // 잠금 보호 상태
        private let lock = NSLock()
        private var pending: CIImage?
        private var drawScheduled = false
        private var active = true
        private var renderedCount = 0
        private var droppedCount = 0

        // 메인 전용 상태
        @MainActor private weak var view: MTKView?
        @MainActor private var viewDelegate: ViewDelegate?
        @MainActor private var imageToDraw: CIImage?
        /// 마지막으로 그린 프레임 크기(탭 좌표 변환용). 기본은 .photo 프리셋의 세로 3:4.
        @MainActor private var lastImageSize = CGSize(width: 3, height: 4)
        @MainActor var onTap: ((CGPoint, CGPoint) -> Void)?
        /// 프리뷰가 좌우 반전돼 그려지는지(전면 카메라). 탭 좌표 변환에 쓴다. CaptureViewModel이 설정한다.
        @MainActor var isMirrored = false

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            if let device {
                // 시그니처: CIContext.init(mtlDevice: MTLDevice, options: [CIContextOption: Any]?)
                ciContext = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: EnhanceRenderer.workingColorSpace,
                    .cacheIntermediates: false,
                ])
            } else {
                ciContext = nil
            }
            super.init()
        }

        // MARK: 뷰 연결 (메인)

        @MainActor func attach(_ view: MTKView) {
            self.view = view
            let delegate = ViewDelegate(owner: self)
            viewDelegate = delegate      // MTKView.delegate는 weak이므로 여기서 붙잡는다
            view.delegate = delegate
        }

        @MainActor func detach(_ view: MTKView) {
            guard self.view === view else { return }
            view.delegate = nil
            self.view = nil
            viewDelegate = nil
            if imageToDraw != nil {
                imageToDraw = nil
                gate.leave()
            }
        }

        // MARK: 프레임 제출 (아무 스레드)

        /// 새 프레임을 받을 수 있으면 true(게이트 진입). false면 호출 측은 그 프레임을 버린다.
        /// true를 받은 호출 측은 반드시 `submit(_:)` 또는 `cancelFrame()` 중 하나를 호출한다.
        func beginFrame() -> Bool {
            if gate.tryEnter() { return true }
            lock.withLock { droppedCount += 1 }
            return false
        }

        /// `beginFrame()` 후 이미지를 만들지 못했을 때 게이트를 돌려준다.
        func cancelFrame() {
            gate.leave()
        }

        /// 보정된 프레임을 제출한다. 메인에 그리기를 한 번만 예약한다(이미 예약돼 있으면 이미지만 교체).
        func submit(_ image: CIImage) {
            var releaseReplaced = false
            var dropThis = false
            var schedule = false
            lock.withLock {
                if !active {
                    dropThis = true
                    return
                }
                if pending != nil {
                    // 게이트 한도 1에서는 생기지 않지만, 교체되는 프레임 몫의 게이트는 돌려준다.
                    releaseReplaced = true
                    droppedCount += 1
                }
                pending = image
                if !drawScheduled {
                    drawScheduled = true
                    schedule = true
                }
            }
            if releaseReplaced { gate.leave() }
            if dropThis { gate.leave(); return }
            if schedule {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.drawPending() }
                }
            }
        }

        /// false면 새 프레임을 받지 않고, 대기 중인 프레임과 예약된 그리기를 버린다(백그라운드·다른 탭).
        func setActive(_ isActive: Bool) {
            let dropped: CIImage? = lock.withLock {
                active = isActive
                guard !isActive else { return nil }
                let p = pending
                pending = nil
                return p
            }
            if dropped != nil { gate.leave() }
        }

        /// 지난 호출 이후 그린 프레임 수와 버린 프레임 수(측정용). 호출하면 0으로 되돌린다.
        func takeStats() -> (rendered: Int, dropped: Int) {
            lock.withLock {
                defer { renderedCount = 0; droppedCount = 0 }
                return (renderedCount, droppedCount)
            }
        }

        // MARK: 그리기 (메인)

        @MainActor private func drawPending() {
            let image: CIImage? = lock.withLock {
                drawScheduled = false
                let p = pending
                pending = nil
                return p
            }
            guard let image else { return }   // setActive(false)로 취소됨
            guard let view else { gate.leave(); return }
            imageToDraw = image
            // MTKView.draw()는 delegate의 draw(in:)을 동기적으로 호출한다(isPaused=true, enableSetNeedsDisplay=false일 때의 수동 그리기).
            // TODO(검증): 뷰가 창에 붙지 않았거나 크기가 0이면 draw(in:)이 호출되지 않을 수 있다 → 아래에서 게이트를 돌려준다.
            view.draw()
            if imageToDraw != nil {
                imageToDraw = nil
                gate.leave()
            }
        }

        /// `ViewDelegate.draw(in:)`에서 불린다.
        @MainActor fileprivate func render(in view: MTKView) {
            guard let image = imageToDraw else { return }
            imageToDraw = nil

            let size = view.drawableSize
            guard size.width > 0, size.height > 0,
                  let ciContext, let commandQueue,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                gate.leave()
                return
            }

            let extent = image.extent
            guard !extent.isInfinite, extent.width > 0, extent.height > 0 else {
                gate.leave()
                return
            }
            lastImageSize = extent.size

            // aspect-fill 배치: 원점 이동 → 확대 → 목표 사각형으로 이동.
            let dest = MetalPreviewView.fitRect(image: extent, drawable: size, mode: .fill)
            let scale = dest.width / extent.width
            let transform = CGAffineTransform(translationX: dest.minX, y: dest.minY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -extent.minX, y: -extent.minY)
            let bounds = CGRect(origin: .zero, size: size)
            let placed = image.transformed(by: transform)
                .composited(over: CIImage(color: .black).cropped(to: bounds))

            // Metal 텍스처는 원점이 좌상단이고 Core Image는 좌하단이라, `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)`로
            // 바로 그리면 위아래가 뒤집혀 보인다(알려진 동작). `CIRenderDestination.isFlipped = true`로 목적지 원점을 좌상단으로 맞춘다.
            // 시그니처: CIRenderDestination.init(mtlTexture: MTLTexture, commandBuffer: MTLCommandBuffer?)
            //          var isFlipped: Bool, var colorSpace: CGColorSpace?
            //          CIContext.startTask(toRender image: CIImage, to destination: CIRenderDestination) throws -> CIRenderTask
            // TODO(검증): 실기기에서 프리뷰가 뒤집혀 보이면 isFlipped를 false로(리뷰에서 판단한 방향이 반대인 경우).
            let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
            destination.isFlipped = true
            destination.colorSpace = outputColorSpace
            do {
                _ = try ciContext.startTask(toRender: placed, to: destination)
            } catch {
                gate.leave()
                return
            }
            commandBuffer.present(drawable)
            let gate = self.gate
            commandBuffer.addCompletedHandler { _ in gate.leave() }
            commandBuffer.commit()
            lock.withLock { renderedCount += 1 }
        }

        // MARK: 탭 (메인)

        @MainActor @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let v = recognizer.view else { return }
            let p = recognizer.location(in: v)
            let dp = MetalPreviewView.devicePoint(fromViewPoint: p, viewSize: v.bounds.size,
                                                  imageSize: lastImageSize, mirrored: isMirrored)
            onTap?(dp, p)
        }
    }

    /// `MTKViewDelegate` 전달자. 그리기는 메인에서만 일어난다(`draw()`를 메인에서 수동 호출).
    final class ViewDelegate: NSObject, MTKViewDelegate {
        private weak var owner: Coordinator?

        init(owner: Coordinator) {
            self.owner = owner
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // 프로토콜의 격리 표시 여부와 무관하게 컴파일되도록 명시적으로 메인 격리를 가정한다(실제로 항상 메인).
            MainActor.assumeIsolated { owner?.render(in: view) }
        }
    }
}
