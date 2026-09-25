// (사용 안 함 · 폴백용) AVCaptureVideoPreviewLayer 기반 카메라 프리뷰.
import AVFoundation
import SwiftUI

/// R1-S0: AVCaptureVideoPreviewLayer 기반 프리뷰.
/// R1-S4부터 촬영 탭은 `MetalPreviewView`(라이브 보정 프리뷰)를 쓰며 이 뷰는 **사용하지 않는다**.
/// Metal 프리뷰에 문제가 생겼을 때 보정 없는 프리뷰로 되돌리기 위한 폴백으로 남겨 둔다.
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
