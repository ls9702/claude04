// PortraitKernels.metal(default.metallib)에서 Core Image 커널을 읽어 두는 묶음. 로드 실패 시 nil → 호출 측 폴백.
import CoreImage
import Foundation

/// 인물 보정 커스텀 커널. 앱에 하나만 로드해 공유한다(`AppServices.portraitKernels`).
/// CIKernel 객체는 불변이라 여러 스레드에서 동시에 `apply`해도 된다.
final class PortraitKernels: @unchecked Sendable {
    /// 입력 1장 → 피부색 가능도 그레이(0~1).
    let skinLikelihood: CIColorKernel
    /// (input, low, mid) → low + (input − mid).
    let frequencyCombine: CIColorKernel
    /// 얼굴 윤곽·눈 워프(R1-S6). 이것만 로드에 실패하면 nil → 워프만 건너뛰고 피부 보정은 그대로 동작한다.
    let faceWarp: CIWarpKernel?

    init(skinLikelihood: CIColorKernel, frequencyCombine: CIColorKernel, faceWarp: CIWarpKernel? = nil) {
        self.skinLikelihood = skinLikelihood
        self.frequencyCombine = frequencyCombine
        self.faceWarp = faceWarp
    }

    /// 번들의 default.metallib에서 로드. 파일이 없거나 커널이 없으면 nil(피부색 마스크·주파수 분리 없이 폴백).
    /// .metal 파일은 XcodeGen 폴더 소스로 들어가 Xcode가 default.metallib로 컴파일한다.
    static func load(bundle: Bundle = .main) -> PortraitKernels? {
        guard let url = bundle.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            // CIColorKernel은 CIKernel의 하위 클래스라 같은 이니셜라이저를 쓴다.
            let skin = try CIColorKernel(functionName: "skinLikelihood", fromMetalLibraryData: data)
            let combine = try CIColorKernel(functionName: "frequencyCombine", fromMetalLibraryData: data)
            // 워프 커널은 따로 시도한다(실패해도 기존 두 커널은 살린다).
            let warp = try? CIWarpKernel(functionName: "faceWarp", fromMetalLibraryData: data)
            return PortraitKernels(skinLikelihood: skin, frequencyCombine: combine, faceWarp: warp)
        } catch {
            return nil
        }
    }

    /// 피부색 마스크. `rect` 영역만 계산한다.
    func skinMask(for image: CIImage, in rect: CGRect) -> CIImage? {
        skinLikelihood.apply(extent: rect, arguments: [image])
    }

    /// low + (input − mid). 세 이미지가 모두 `rect`를 덮어야 한다.
    func combine(input: CIImage, low: CIImage, mid: CIImage, in rect: CGRect) -> CIImage? {
        frequencyCombine.apply(extent: rect, arguments: [input, low, mid])
    }
}
