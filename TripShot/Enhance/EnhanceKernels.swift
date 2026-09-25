// EnhanceKernels.metal(default.metallib)에서 보정 파이프라인용 Core Image 커널을 읽어 두는 묶음. 로드 실패 시 nil → 호출 측 폴백.
import CoreImage
import Foundation

/// 보정 파이프라인 커스텀 커널. `PortraitKernels`와 같은 default.metallib를 읽지만 함수만 다르다.
/// CIKernel 객체는 불변이라 여러 스레드에서 동시에 `apply`해도 된다.
final class EnhanceKernels: @unchecked Sendable {
    /// (x, a, iterations, strength) → Zero-DCE++ LE 곡선 적용 결과(5단계 저조도).
    let zeroDCECurve: CIColorKernel

    init(zeroDCECurve: CIColorKernel) {
        self.zeroDCECurve = zeroDCECurve
    }

    /// 번들의 default.metallib에서 로드. 파일이나 커널이 없으면 nil.
    static func load(bundle: Bundle = .main) -> EnhanceKernels? {
        guard let url = bundle.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let curve = try? CIColorKernel(functionName: "zeroDCECurve", fromMetalLibraryData: data)
        else { return nil }
        return EnhanceKernels(zeroDCECurve: curve)
    }
}
