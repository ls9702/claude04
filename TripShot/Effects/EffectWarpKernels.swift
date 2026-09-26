// EffectKernels.metal(default.metallib)의 렌즈 워프 커널 묶음. 로드 실패한 커널은 nil → 그 효과는 입력 그대로.
import CoreImage
import Foundation

final class EffectWarpKernels: @unchecked Sendable {
    let ripple: CIWarpKernel?
    let wave: CIWarpKernel?
    let crystalBall: CIWarpKernel?
    let cylinder: CIWarpKernel?

    /// 앱 전체에서 한 번만 읽는다(CIKernel은 불변이라 여러 스레드에서 동시에 써도 된다).
    static let shared = EffectWarpKernels(bundle: .main)

    init(bundle: Bundle) {
        let data = bundle.url(forResource: "default", withExtension: "metallib").flatMap { try? Data(contentsOf: $0) }
        func load(_ name: String) -> CIWarpKernel? {
            guard let data else { return nil }
            return try? CIWarpKernel(functionName: name, fromMetalLibraryData: data)
        }
        ripple = load("effectRipple")
        wave = load("effectWave")
        crystalBall = load("effectCrystalBall")
        cylinder = load("effectCylinder")
    }

    /// 워프 적용. `maxShift`는 출력 한 점이 읽는 입력 위치의 최대 이동량(ROI 확장용).
    static func warp(_ kernel: CIWarpKernel?, _ image: CIImage, maxShift: CGFloat, arguments: [Any]) -> CIImage {
        guard let kernel else { return image }
        let e = image.extent
        let out = kernel.apply(extent: e,
                               roiCallback: { _, rect in rect.insetBy(dx: -maxShift - 2, dy: -maxShift - 2) },
                               image: image.clampedToExtent(),
                               arguments: arguments)
        return out?.cropped(to: e) ?? image
    }
}
