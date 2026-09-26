// 전신 보정: Vision 몸 자세(어깨·엉덩이·발목)로 몸 슬림(가로 좁히기)·다리 길게(엉덩이 아래 세로 늘리기)를 한 번의 워프로 적용한다.
// 저장·앨범 전용(라이브 미적용 — 프레임마다 자세 검출은 발열 부담).
//
// 방식(보정 앱들의 흔한 방법을 단순화):
// - 다리 길게: 엉덩이선 아래(다리·발·바닥)를 세로로 (1 + s)배 늘리고, 엉덩이 위는 그만큼 위로 평행 이동한다.
//   출력 크기는 그대로라 맨 위 하늘이 조금 잘린다. 머리가 잘리지 않게 s를 제한한다. 엉덩이 근처는 선형 램프로 부드럽게 잇는다.
//   세로로만 늘리므로 세로선은 휘지 않는다. 얼굴은 엉덩이 위라 비율이 변하지 않는다.
// - 몸 슬림: 몸 중심선 반경 R 안을 중심 쪽으로 모은다(역방향: 입력 x = x + a·(x − cx)·(1 − |x − cx|/R)²).
//   중심 배율 1/(1 + a), R 밖은 그대로. a < 3이면 단조라 접힘이 없다. 머리는 어깨~머리 꼭대기 사이에서 서서히 0으로(얼굴 윤곽은 별도).
//   배경 세로선이 몸 옆에서 약간 휜다 — 강도 상한을 낮게 둔다.
import CoreGraphics
import CoreImage
import Foundation
import Vision

// MARK: - 몸 배치 (순수 값)

/// 몸 관절(이 앱에서 쓰는 것만). Vision `JointName`과 분리해 테스트에서 직접 만든다.
enum BodyJoint: CaseIterable {
    case nose, neck, leftShoulder, rightShoulder, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// 워프 계획에 필요한 몸 배치(이미지 픽셀 좌표, 원점 좌하단 — Core Image와 같다).
struct BodyLayout: Equatable {
    /// 몸 중심선 x(어깨 중점·엉덩이 중점의 평균).
    var centerX: CGFloat
    /// 어깨 폭·엉덩이 폭 중 큰 쪽의 절반.
    var halfWidth: CGFloat
    var shoulderY: CGFloat
    var hipY: CGFloat
    /// 발목 높이. 발목이 없으면 무릎에서 추정, 둘 다 없으면 nil(다리 길게 안 함).
    var ankleY: CGFloat?
    /// 머리 꼭대기 추정 높이.
    var headTopY: CGFloat

    /// 어깨~엉덩이 길이.
    var torsoLength: CGFloat { shoulderY - hipY }

    /// 신뢰도 기준을 통과한 관절 좌표(이미지 좌표) → 배치. 어깨·엉덩이가 하나씩은 있어야 하고, 서 있는 자세(어깨가 엉덩이 위)여야 한다.
    static func make(joints: [BodyJoint: CGPoint]) -> BodyLayout? {
        let shoulders = [joints[.leftShoulder], joints[.rightShoulder]].compactMap { $0 }
        let hips = [joints[.leftHip], joints[.rightHip]].compactMap { $0 }
        guard !shoulders.isEmpty, !hips.isEmpty else { return nil }
        let shoulderMid = mean(shoulders)
        let hipMid = mean(hips)
        let torso = shoulderMid.y - hipMid.y
        // 누운 자세·거꾸로 든 사진·검출 오류는 건너뛴다(각도가 45°보다 크게 기울면 세로 워프가 맞지 않는다).
        guard torso > 0, torso > abs(shoulderMid.x - hipMid.x) else { return nil }

        let shoulderWidth = shoulders.count == 2 ? abs(shoulders[0].x - shoulders[1].x) : 0
        let hipWidth = hips.count == 2 ? abs(hips[0].x - hips[1].x) : 0
        // 옆모습 등으로 폭이 작게 잡히면 몸통 길이로 하한을 둔다.
        let halfWidth = max(max(shoulderWidth, hipWidth) / 2, torso * 0.2)

        var ankleY: CGFloat?
        let ankles = [joints[.leftAnkle], joints[.rightAnkle]].compactMap { $0 }
        let knees = [joints[.leftKnee], joints[.rightKnee]].compactMap { $0 }
        if let low = ankles.map(\.y).min(), low < hipMid.y {
            ankleY = low
        } else if let knee = knees.map(\.y).min(), knee < hipMid.y {
            // 엉덩이~무릎 ≈ 무릎~발목.
            ankleY = knee - (hipMid.y - knee)
        }

        // 머리 꼭대기: 코가 있으면 코 위로 (코 − 어깨)의 0.8배, 없으면 어깨 위로 몸통의 0.6배.
        let headTopY: CGFloat
        if let nose = joints[.nose], nose.y > shoulderMid.y {
            headTopY = nose.y + (nose.y - shoulderMid.y) * 0.8
        } else {
            headTopY = shoulderMid.y + torso * 0.6
        }

        return BodyLayout(centerX: (shoulderMid.x + hipMid.x) / 2, halfWidth: halfWidth,
                          shoulderY: shoulderMid.y, hipY: hipMid.y, ankleY: ankleY, headTopY: headTopY)
    }

    private static func mean(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }
}

// MARK: - 워프 계획 (순수 값)

/// 전신 워프 한 번의 인자. 좌표는 이미지 픽셀(원점 좌하단).
struct BodyWarpPlan: Equatable {
    /// 슬림 중심선 x, 영향 반경, 중심 강도 a(0이면 슬림 없음).
    var centerX: CGFloat
    var slimRadius: CGFloat
    var slimAmount: CGFloat
    /// 이 높이 아래는 슬림 100%, `slimZeroY` 위는 0%(사이는 smoothstep). 입력(원본) y 기준.
    var slimFullY: CGFloat
    var slimZeroY: CGFloat
    /// 세로 늘림 기준 바닥(extent.minY), 램프 시작(바닥 기준 출력 높이), 램프 폭, 늘림 배율 s(0이면 없음).
    var baseY: CGFloat
    var rampStart: CGFloat
    var rampWidth: CGFloat
    var stretch: CGFloat

    /// 강도 100일 때 상한. 몸 슬림: 중심부 약 11% 좁게(a = 0.12). 다리 길게: 엉덩이 아래 10% 늘림.
    static let maxSlimAmount: CGFloat = 0.12
    static let maxStretch: CGFloat = 0.10
    /// 슬림 영향 반경 = 몸 반폭 × 이 값(팔·옷까지 포함).
    static let slimRadiusFactor: CGFloat = 3.0
    /// 다리 길게는 다리(엉덩이~발목)가 이미지 높이의 이 비율 이상일 때만(상반신·먼 인물 제외).
    static let minLegFraction: CGFloat = 0.15

    var isIdentity: Bool { slimAmount <= 0 && stretch <= 0 }

    /// 세로 이동의 최대값(엉덩이 위 내용이 올라가는 양). ROI 계산용.
    var maxVerticalShift: CGFloat {
        guard stretch > 0 else { return 0 }
        let r = 1 / (1 + stretch)
        let end = rampStart + rampWidth
        return end - (rampStart * r + (r + 1) * rampWidth / 2)
    }

    /// 가로 이동의 최대값: a·d·(1 − d/R)²의 최대(d = R/3) = a·R·4/27.
    var maxHorizontalShift: CGFloat { slimAmount * slimRadius * 4 / 27 }

    /// 강도(0~100)와 배치로 계획을 만든다. 효과가 없으면 nil.
    static func make(layout: BodyLayout, extent: CGRect, bodySlim: Double, legLengthen: Double) -> BodyWarpPlan? {
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        let slimStrength = CGFloat(min(max(bodySlim, 0), 100) / 100)
        let legStrength = CGFloat(min(max(legLengthen, 0), 100) / 100)

        // 슬림
        let slimAmount = maxSlimAmount * slimStrength
        let slimRadius = layout.halfWidth * slimRadiusFactor

        // 다리 길게
        var stretch: CGFloat = 0
        let hipFromBase = layout.hipY - extent.minY
        if legStrength > 0, let ankle = layout.ankleY,
           layout.hipY - ankle >= extent.height * minLegFraction, hipFromBase > 0 {
            stretch = maxStretch * legStrength
            // 엉덩이 위가 대략 s·(엉덩이 높이)만큼 올라간다 → 머리 꼭대기가 위 가장자리(여유 1%) 밖으로 나가지 않게 제한.
            let headroom = extent.maxY - extent.height * 0.01 - layout.headTopY
            stretch = min(stretch, max(headroom, 0) / hipFromBase)
            if stretch < 0.005 { stretch = 0 }
        }

        // 엉덩이 근처 램프: 몸통 길이의 1/4, 출력 좌표에서 늘어난 엉덩이 위치를 가운데로.
        let rampWidth = max(layout.torsoLength * 0.25, 1)
        let rampStart = max(hipFromBase * (1 + stretch) - rampWidth / 2, 0)

        let plan = BodyWarpPlan(centerX: layout.centerX, slimRadius: slimRadius, slimAmount: slimAmount,
                                slimFullY: layout.shoulderY, slimZeroY: max(layout.headTopY, layout.shoulderY + 1),
                                baseY: extent.minY, rampStart: rampStart, rampWidth: rampWidth, stretch: stretch)
        return plan.isIdentity ? nil : plan
    }

    // MARK: 좌표 사상 (Metal 커널 `bodyReshape`와 같은 식 — 테스트·검증용)

    /// 출력 좌표 → 입력 좌표.
    func sourcePoint(for p: CGPoint) -> CGPoint {
        let sy = baseY + sourceHeight(forOutputHeight: p.y - baseY)
        var sx = p.x
        let d = p.x - centerX
        let u = abs(d) / max(slimRadius, 1e-4)
        if slimAmount > 0, u < 1 {
            sx = p.x + slimAmount * slimWeight(atSourceY: sy) * d * (1 - u) * (1 - u)
        }
        return CGPoint(x: sx, y: sy)
    }

    /// 바닥 기준 출력 높이 → 바닥 기준 입력 높이(아래는 1/(1+s)배, 램프에서 1로, 위는 평행 이동).
    func sourceHeight(forOutputHeight y: CGFloat) -> CGFloat {
        guard stretch > 0 else { return y }
        let r = 1 / (1 + stretch)
        if y <= rampStart { return y * r }
        let t = y - rampStart
        if t < rampWidth { return rampStart * r + r * t + (1 - r) * t * t / (2 * rampWidth) }
        return rampStart * r + (r + 1) * rampWidth / 2 + (t - rampWidth)
    }

    func slimWeight(atSourceY y: CGFloat) -> CGFloat {
        let t = min(max((y - slimFullY) / max(slimZeroY - slimFullY, 1e-4), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// 출력 사각형을 그리는 데 필요한 입력 영역.
    func roi(for rect: CGRect) -> CGRect {
        rect.insetBy(dx: -(maxHorizontalShift + 2), dy: -(maxVerticalShift + 2))
    }
}

// MARK: - 자세 검출

/// Vision 몸 자세 검출. 인스턴스 하나를 여러 스레드에서 써도 된다(요청은 호출마다 새로 만든다).
final class BodyPoseDetector: @unchecked Sendable {
    /// 검출용 다운샘플 긴 변. 관절 좌표는 정규화라 원본 extent로 환산한다.
    static let detectionMaxDimension: CGFloat = 1024
    /// 관절 신뢰도 하한.
    static let minConfidence: Float = 0.3

    private let ciContext: CIContext

    init(ciContext: CIContext? = nil) {
        self.ciContext = ciContext ?? CIContext(options: [.cacheIntermediates: false])
    }

    /// 가장 크게 찍힌 사람(몸통 길이 기준)의 배치. 없으면 nil. 입력은 방향이 반영된(세운) 이미지.
    func detect(in image: CIImage) -> BodyLayout? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        var small = EnhanceRenderer.downsample(image, maxDimension: Self.detectionMaxDimension)
        if small.extent.origin != .zero {
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [.ciContext: ciContext])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }
        let layouts = observations.compactMap { Self.layout(from: $0, extent: extent) }
        return layouts.max { $0.torsoLength < $1.torsoLength }
    }

    private static let jointNames: [BodyJoint: VNHumanBodyPoseObservation.JointName] = [
        .nose: .nose, .neck: .neck,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    private static func layout(from observation: VNHumanBodyPoseObservation, extent: CGRect) -> BodyLayout? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [BodyJoint: CGPoint] = [:]
        for (joint, name) in jointNames {
            guard let p = points[name], p.confidence >= minConfidence else { continue }
            // 정규화 좌표(원점 좌하단) → 이미지 픽셀 좌표.
            joints[joint] = CGPoint(x: extent.minX + p.location.x * extent.width,
                                    y: extent.minY + p.location.y * extent.height)
        }
        return BodyLayout.make(joints: joints)
    }
}

// MARK: - 적용

enum BodyShape {
    /// 몸 슬림·다리 길게가 하나라도 켜져 있는지.
    static func isActive(_ params: PortraitParams) -> Bool {
        params.bodySlim > 0 || params.legLengthen > 0
    }

    /// 자세 검출 → 계획 → 워프. 사람이 없거나 커널이 없거나 효과가 없으면 입력 그대로(같은 객체).
    static func apply(_ image: CIImage, params: PortraitParams, detector: BodyPoseDetector,
                      kernel: CIWarpKernel?) -> CIImage {
        guard isActive(params), let kernel, let layout = detector.detect(in: image),
              let plan = BodyWarpPlan.make(layout: layout, extent: image.extent,
                                           bodySlim: params.bodySlim, legLengthen: params.legLengthen) else {
            return image
        }
        return warp(image, plan: plan, kernel: kernel)
    }

    static func warp(_ image: CIImage, plan: BodyWarpPlan, kernel: CIWarpKernel) -> CIImage {
        let extent = image.extent
        // 가장자리 밖을 읽어도 투명이 되지 않게 확장한다(바닥을 늘릴 때 아래 가장자리).
        let source = image.clampedToExtent()
        let warped = kernel.apply(extent: extent,
                                  roiCallback: { _, rect in plan.roi(for: rect) },
                                  image: source,
                                  arguments: arguments(for: plan))
        return warped?.cropped(to: extent) ?? image
    }

    /// 커널 인자: slim(cx, R, a, 0), slimY(fullY, zeroY, 0, 0), legs(baseY, rampStart, rampWidth, r = 1/(1+s)).
    static func arguments(for plan: BodyWarpPlan) -> [Any] {
        [
            CIVector(x: plan.centerX, y: plan.slimRadius, z: plan.slimAmount, w: 0),
            CIVector(x: plan.slimFullY, y: plan.slimZeroY, z: 0, w: 0),
            CIVector(x: plan.baseY, y: plan.rampStart, z: plan.rampWidth, w: 1 / (1 + plan.stretch)),
        ]
    }
}
