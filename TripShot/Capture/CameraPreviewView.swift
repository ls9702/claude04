import AVFoundation
import SwiftUI

/// P0: AVCaptureVideoPreviewLayer 기반 프리뷰. P5에서 MTKView(Metal) 프리뷰로 교체.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTap = onTap
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.onTap = onTap
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            onTap?(devicePoint)
        }
    }
}
