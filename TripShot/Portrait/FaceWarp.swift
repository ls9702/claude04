// 얼굴 윤곽(턱선·광대 축소)·눈 확대 워프: 랜드마크 → 변위 계획(순수) → Core Image 워프 커널(역방향 변위) 적용.
import CoreGraphics
import CoreImage
import Foundation

// MARK: - 얼굴 축

/// 얼굴 중심축. 머리가 기울어져도(roll) 랜드마크로 계산하므로 좌우 대칭이 유지된다.
struct FaceAxis: Equatable {
    /// 축 위의 한 점(두 눈 중점).
    var origin: CGPoint
    /// 단위 벡터: 두 눈 중점 → 입 중점(얼굴 아래쪽).
    var down: CGVector
    /// 단위 벡터: `down`에 수직. 똑바로 선 얼굴이면 이미지 오른쪽(+x).
    var right: CGVector

    init(origin: CGPoint, down: CGVector) {
        self.origin = origin
        let len = (down.dx * down.dx + down.dy * down.dy).squareRoot()
        let d = len > 0 ? CGVector(dx: down.dx / len, dy: down.dy / len) : CGVector(dx: 0, dy: -1)
        self.down = d
        // down = (0, −1)(똑바로 선 얼굴, CIImage 좌표는 y 위쪽) → right = (1, 0).
        self.right = CGVector(dx: -d.dy, dy: d.dx)
    }

    /// 점의 `right` 방향 좌표(축에서 오른쪽이 +).
    func side(_ p: CGPoint) -> CGFloat {
        (p.x - origin.x) * right.dx + (p.y - origin.y) * right.dy
    }

    /// 점의 `down` 방향 좌표(아래쪽이 +).
    func depth(_ p: CGPoint) -> CGFloat {
        (p.x - origin.x) * down.dx + (p.y - origin.y) * down.dy
    }

    /// 랜드마크로 축을 만든다. 두 눈과 입술이 있으면 눈 중점 → 입 중점, 없으면 똑바로 선 얼굴로 가정.
    static func make(for face: DetectedFace) -> FaceAxis {
        let lm = face.landmarks
        let lips = lm.outerLips.isEmpty ? lm.innerLips : lm.outerLips
        if let le = centroid(lm.leftEye), let re = centroid(lm.rightEye), let mouth = centroid(lips) {
            let eyes = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
            let v = CGVector(dx: mouth.x - eyes.x, dy: mouth.y - eyes.y)
            if v.dx * v.dx + v.dy * v.dy > 1e-6 {
                return FaceAxis(origin: eyes, down: v)
            }
        }
        // 폴백: 랜드마크가 부족하면 기울기 없음으로 본다.
        return FaceAxis(origin: face.center, down: CGVector(dx: 0, dy: -1))
    }

    static func centroid(_ pts: [CGPoint]) -> CGPoint? {
        guard !pts.isEmpty else { return nil }
        let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
    }
}

// MARK: - 워프 계획(순수)

/// 얼굴 하나의 워프 계획. 좌표는 이미지 픽셀(CIImage 규약, 원점 좌하단).
///
/// 역방향 변위 Δ(p) = (입력 좌표 − 출력 좌표):
/// - 원형 밀기: Δ = −d·k·w, w = (1 − (dist/r)²)² (dist < r), 아니면 0 → 내용이 d 방향으로 k만큼(중심에서) 밀린다.
/// - 원형 확대: Δ = −(p − c)·s·w → 중심부가 확대된다.
/// 여러 개가 겹치면 변위를 합한다.
struct WarpPlan: Equatable {
    struct Push: Equatable {
        var center: CGPoint
        var radius: CGFloat
        /// 픽셀. 중심에서의 이동량.
        var strength: CGFloat
        /// 단위 벡터. 내용이 움직이는 방향.
        var direction: CGVector
    }

    struct Bulge: Equatable {
        var center: CGPoint
        var radius: CGFloat
        /// 0~0.3. 중심 확대율.
        var scale: CGFloat
    }

    var pushes: [Push]
    var bulges: [Bulge]
    /// 다인 겹침 판단용 얼굴 중심(얼굴 boundingBox 중심).
    var center: CGPoint
    /// 다인 겹침 판단용 영향 반경(중심 ~ 가장 먼 밀기·확대 원의 바깥).
    var radius: CGFloat

    // MARK: 상수 (TODO(실기기): 셀피로 튜닝)

    /// 밀기 반경 = 얼굴 너비 × 이 값. 작게 유지해 배경 왜곡을 줄인다(반경 밖은 w = 0).
    static let pushRadiusFraction: CGFloat = 0.28
    /// 밀기 강도(픽셀) = 얼굴 너비 × 이 값 × (faceSlim / 100).
    static let pushStrengthFraction: CGFloat = 0.035
    /// 밀기 중심을 턱선 점에서 축 쪽(얼굴 안쪽)으로 이만큼(얼굴 너비 비율) 옮긴다.
    /// 턱선 바깥 배경에 걸리는 반경을 줄여 배경 왜곡을 감쇠한다.
    static let pushInsetFraction: CGFloat = 0.06
    /// 눈 확대 반경 = 눈 너비 × 이 값.
    static let eyeRadiusFactor: CGFloat = 1.4
    /// 눈 확대율 = 이 값 × (eyeEnlarge / 100).
    static let eyeMaxScale: CGFloat = 0.25
    /// 턱선 점 선택에 필요한 최소 점 개수.
    static let minContourPoints = 5

    // MARK: 생성

    /// 얼굴 하나의 계획. faceSlim·eyeEnlarge가 모두 0이거나 쓸 수 있는 랜드마크가 없으면 nil.
    /// 라이브(`.live`)는 밀기 점을 좌우 각 2개(광대 제외, 총 4개)로 줄인다.
    static func make(face: DetectedFace, params: PortraitParams, quality: PortraitQuality) -> WarpPlan? {
        let slim = CGFloat(Mapping.clampUnsigned(params.faceSlim) / 100)
        let eye = CGFloat(Mapping.clampUnsigned(params.eyeEnlarge) / 100)
        let faceWidth = face.boundingBox.width
        guard slim > 0 || eye > 0, faceWidth > 0 else { return nil }

        let axis = FaceAxis.make(for: face)
        var pushes: [Push] = []
        var bulges: [Bulge] = []

        if slim > 0 {
            let jaw = jawPoints(contour: face.landmarks.faceContour, axis: axis)
            // 순서: [광대 아래, 턱 중간, 턱 끝 근처]. 라이브는 광대(첫 점)를 뺀다.
            let left = quality == .live ? Array(jaw.left.dropFirst()) : jaw.left
            let right = quality == .live ? Array(jaw.right.dropFirst()) : jaw.right
            let r = faceWidth * pushRadiusFraction
            let k = faceWidth * pushStrengthFraction * slim   // 좌우 같은 k(대칭)
            let inset = faceWidth * pushInsetFraction
            // 왼쪽 점은 +right(축 쪽)로, 오른쪽 점은 −right로 민다.
            let toRight = axis.right
            let toLeft = CGVector(dx: -axis.right.dx, dy: -axis.right.dy)
            for p in left {
                pushes.append(Push(center: CGPoint(x: p.x + toRight.dx * inset, y: p.y + toRight.dy * inset),
                                   radius: r, strength: k, direction: toRight))
            }
            for p in right {
                pushes.append(Push(center: CGPoint(x: p.x + toLeft.dx * inset, y: p.y + toLeft.dy * inset),
                                   radius: r, strength: k, direction: toLeft))
            }
        }

        if eye > 0 {
            let s = eyeMaxScale * eye
            for poly in [face.landmarks.leftEye, face.landmarks.rightEye] {
                guard poly.count >= 2, let c = FaceAxis.centroid(poly) else { continue }
                // 눈 너비는 얼굴 축의 right 방향 폭(기울어진 얼굴에서도 같은 값).
                let sides = poly.map { axis.side($0) }
                let width = (sides.max() ?? 0) - (sides.min() ?? 0)
                guard width > 0 else { continue }
                bulges.append(Bulge(center: c, radius: width * eyeRadiusFactor, scale: s))
            }
        }

        guard !pushes.isEmpty || !bulges.isEmpty else { return nil }
        let center = face.center
        var radius: CGFloat = 0
        for p in pushes { radius = max(radius, distance(center, p.center) + p.radius) }
        for b in bulges { radius = max(radius, distance(center, b.center) + b.radius) }
        return WarpPlan(pushes: pushes, bulges: bulges, center: center, radius: radius)
    }

    /// 턱선(faceContour)에서 좌·우 각 3점을 고른다. 각 배열은 [광대 아래(귀 쪽 1/3), 턱 중간(2/3), 턱 끝 근처(턱 끝에서 1점 안쪽)] 순서.
    ///
    /// - 턱선은 한쪽 귀 → 턱 끝 → 다른 쪽 귀 순서(어느 방향이든)라고 가정한다.
    /// - 양 끝점의 `right` 투영값으로 어느 끝이 왼쪽인지 정하고, 턱 끝은 `down` 투영이 가장 큰 점이다.
    /// - 점이 부족하거나 한쪽 절반이 3스텝 미만이면 양쪽 모두 빈 배열(한쪽만 워프하면 비대칭이 되므로).
    static func jawPoints(contour: [CGPoint], axis: FaceAxis) -> (left: [CGPoint], right: [CGPoint]) {
        guard contour.count >= minContourPoints else { return ([], []) }
        // 턱 끝: 얼굴 아래쪽으로 가장 깊은 점. 양 끝점은 제외하고 찾는다.
        var chin = 1
        for i in 1..<(contour.count - 1) where axis.depth(contour[i]) > axis.depth(contour[chin]) {
            chin = i
        }
        // 귀 → 턱 끝 순서의 두 절반.
        let firstHalf = Array(contour[0...chin])
        let secondHalf = Array(contour[chin...].reversed())
        let firstIsLeft = axis.side(contour[0]) <= axis.side(contour[contour.count - 1])
        let leftHalf = firstIsLeft ? firstHalf : secondHalf
        let rightHalf = firstIsLeft ? secondHalf : firstHalf

        func pick(_ half: [CGPoint]) -> [CGPoint]? {
            let m = half.count - 1   // 귀(0) → 턱 끝(m) 스텝 수
            guard m >= 3 else { return nil }
            let a = Int((CGFloat(m) / 3).rounded())
            let b = Int((CGFloat(2 * m) / 3).rounded())
            let c = m - 1
            return [half[a], half[min(b, c)], half[c]]
        }
        guard let l = pick(leftHalf), let r = pick(rightHalf) else { return ([], []) }
        return (l, r)
    }

    // MARK: 다인 겹침

    /// 뒤 얼굴의 영향 원이 앞 얼굴들과 겹치면(중심 거리 < r1 + r2) 겹침 비율(1 − 거리/(r1 + r2))만큼
    /// 밀기 k와 눈 확대 s를 줄인다. 앞 얼굴 여럿과 겹치면 감쇠를 곱한다. 첫 얼굴은 그대로.
    static func attenuateOverlaps(_ plans: [WarpPlan]) -> [WarpPlan] {
        var result = plans
        guard plans.count > 1 else { return result }
        for i in 1..<plans.count {
            var factor: CGFloat = 1
            for j in 0..<i {
                let reach = plans[i].radius + plans[j].radius
                guard reach > 0 else { continue }
                let d = distance(plans[i].center, plans[j].center)
                if d < reach {
                    factor *= d / reach   // = 1 − 겹침 비율
                }
            }
            guard factor < 1 else { continue }
            for p in result[i].pushes.indices { result[i].pushes[p].strength *= factor }
            for b in result[i].bulges.indices { result[i].bulges[b].scale *= factor }
        }
        return result
    }

    // MARK: 변위

    /// 역방향 변위 Δ(p) = 입력 좌표 − 출력 좌표(커널과 같은 식).
    func backwardDisplacement(at p: CGPoint) -> CGVector {
        var dx: CGFloat = 0, dy: CGFloat = 0
        for push in pushes {
            let w = Self.falloff(dx: p.x - push.center.x, dy: p.y - push.center.y, radius: push.radius)
            dx -= push.direction.dx * push.strength * w
            dy -= push.direction.dy * push.strength * w
        }
        for b in bulges {
            let vx = p.x - b.center.x, vy = p.y - b.center.y
            let w = Self.falloff(dx: vx, dy: vy, radius: b.radius)
            dx -= vx * b.scale * w
            dy -= vy * b.scale * w
        }
        return CGVector(dx: dx, dy: dy)
    }

    /// 원본 좌표의 점이 워프 후 어디로 가는지(1차 근사): q' ≈ q − Δ(q).
    /// 밀기 변위가 반경보다 훨씬 작아(k/r ≈ 0.125) 1차 근사로 마스크 위치를 맞추기에 충분하다.
    func forwardMap(_ point: CGPoint) -> CGPoint {
        let d = backwardDisplacement(at: point)
        return CGPoint(x: point.x - d.dx, y: point.y - d.dy)
    }

    /// 얼굴의 랜드마크·boundingBox를 워프 후 좌표로 옮긴다(피부 마스크를 워프된 얼굴에 맞추기 위해).
    func mapFace(_ face: DetectedFace) -> DetectedFace {
        func m(_ pts: [CGPoint]) -> [CGPoint] { pts.map(forwardMap) }
        let lm = face.landmarks
        let landmarks = FaceLandmarks(faceContour: m(lm.faceContour), leftEye: m(lm.leftEye), rightEye: m(lm.rightEye),
                                      outerLips: m(lm.outerLips), innerLips: m(lm.innerLips), nose: m(lm.nose),
                                      leftEyebrow: m(lm.leftEyebrow), rightEyebrow: m(lm.rightEyebrow))
        let bb = face.boundingBox
        let corners = m([CGPoint(x: bb.minX, y: bb.minY), CGPoint(x: bb.maxX, y: bb.minY),
                         CGPoint(x: bb.minX, y: bb.maxY), CGPoint(x: bb.maxX, y: bb.maxY)])
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return DetectedFace(boundingBox: box, landmarks: landmarks, roll: face.roll, yaw: face.yaw)
    }

    /// 변위 크기의 상한(ROI 확장량). 밀기는 k, 확대는 |p − c|·s·w ≤ r·s.
    var maxDisplacement: CGFloat {
        pushes.reduce(0) { $0 + abs($1.strength) } + bulges.reduce(0) { $0 + $1.radius * abs($1.scale) }
    }

    /// 변위가 0이 아닌 영역(모든 원의 합집합 경계 사각형). 이 밖은 출력 = 입력.
    var influenceRect: CGRect {
        var rect = CGRect.null
        for p in pushes where p.strength != 0 {
            rect = rect.union(CGRect(x: p.center.x - p.radius, y: p.center.y - p.radius, width: 2 * p.radius, height: 2 * p.radius))
        }
        for b in bulges where b.scale != 0 {
            rect = rect.union(CGRect(x: b.center.x - b.radius, y: b.center.y - b.radius, width: 2 * b.radius, height: 2 * b.radius))
        }
        return rect
    }

    /// 요청된 출력 영역에 필요한 입력 영역: 최대 변위 + 보간 여유 1픽셀만큼 확장.
    static func roi(for rect: CGRect, maxDisplacement: CGFloat) -> CGRect {
        let m = max(0, maxDisplacement) + 1
        return rect.insetBy(dx: -m, dy: -m)
    }

    // MARK: 보조

    /// w = (1 − (dist/r)²)², dist ≥ r이면 0. 커널의 `warpFalloff`와 같다.
    static func falloff(dx: CGFloat, dy: CGFloat, radius: CGFloat) -> CGFloat {
        let r = max(radius, 1e-4)
        let t2 = (dx * dx + dy * dy) / (r * r)
        guard t2 < 1 else { return 0 }
        let u = 1 - t2
        return u * u
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - 적용

/// 얼굴 윤곽·눈 워프 적용. 네임스페이스로만 쓰며 상태가 없다.
enum FaceWarp {
    /// 커널 1회에 넘길 수 있는 밀기·확대 개수(`faceWarp` Metal 커널 시그니처와 같다).
    static let pushesPerPass = 6
    static let bulgesPerPass = 2

    /// 워프된 이미지만 필요할 때.
    /// faces가 비었거나, 워프 커널이 없거나, faceSlim·eyeEnlarge가 모두 0이면 입력 그대로(같은 객체).
    static func apply(_ input: CIImage, faces: [DetectedFace], params: PortraitParams,
                      quality: PortraitQuality, kernels: PortraitKernels?) -> CIImage {
        process(input, faces: faces, params: params, quality: quality, kernels: kernels).image
    }

    /// 워프 결과 + 워프 후 좌표로 옮긴 얼굴(다음 피부 보정의 마스크용).
    /// 워프하지 않으면 입력 이미지(같은 객체)와 원래 얼굴을 그대로 돌려준다.
    static func process(_ input: CIImage, faces: [DetectedFace], params: PortraitParams,
                        quality: PortraitQuality, kernels: PortraitKernels?) -> (image: CIImage, faces: [DetectedFace]) {
        let extent = input.extent
        guard !faces.isEmpty, let kernel = kernels?.faceWarp,
              params.faceSlim > 0 || params.eyeEnlarge > 0,
              !extent.isInfinite, !extent.isEmpty else {
            return (input, faces)
        }

        let limited = Array(faces.prefix(SkinMask.maxFaces))
        // 얼굴별 계획(없으면 nil 자리 유지) → 다인 겹침 감쇠.
        let raw = limited.map { WarpPlan.make(face: $0, params: params, quality: quality) }
        let valid = raw.compactMap { $0 }
        guard !valid.isEmpty else { return (input, faces) }
        var attenuated = WarpPlan.attenuateOverlaps(valid)[...]
        let plans: [WarpPlan?] = raw.map { $0 == nil ? nil : attenuated.popFirst() }

        // 얼굴별로 순차 적용.
        var image = input
        for plan in plans.compactMap({ $0 }) {
            image = warp(image, plan: plan, kernel: kernel, extent: extent)
        }

        // 랜드마크를 워프 후 좌표로: 모든 계획을 적용 순서대로 통과시킨다.
        let applied = plans.compactMap { $0 }
        let mapped = limited.map { face in applied.reduce(face) { $1.mapFace($0) } }
        return (image, mapped + faces.dropFirst(limited.count))
    }

    /// 계획 하나를 적용한다. 변위가 있는 영역만 커널로 계산하고 나머지는 원본 위에 합성한다.
    static func warp(_ image: CIImage, plan: WarpPlan, kernel: CIWarpKernel, extent: CGRect) -> CIImage {
        var result = image
        var pushes = plan.pushes[...]
        var bulges = plan.bulges[...]
        // 보통 얼굴당 1회(밀기 ≤ 6, 확대 ≤ 2). 더 많으면 나눠서 적용.
        while !pushes.isEmpty || !bulges.isEmpty {
            let chunk = WarpPlan(pushes: Array(pushes.prefix(pushesPerPass)), bulges: Array(bulges.prefix(bulgesPerPass)),
                                 center: plan.center, radius: plan.radius)
            pushes = pushes.dropFirst(pushesPerPass)
            bulges = bulges.dropFirst(bulgesPerPass)

            let area = chunk.influenceRect.insetBy(dx: -1, dy: -1).integral.intersection(extent)
            guard !area.isNull, !area.isEmpty else { continue }
            let maxDisp = chunk.maxDisplacement
            // 경계 근처에서 입력 밖을 읽어도 투명이 되지 않게 가장자리 확장.
            let source = result.clampedToExtent()
            let warped = kernel.apply(extent: area,
                                      roiCallback: { _, rect in WarpPlan.roi(for: rect, maxDisplacement: maxDisp) },
                                      image: source,
                                      arguments: arguments(for: chunk))
            guard let warped else { continue }
            result = warped.composited(over: result).cropped(to: extent)
        }
        return result
    }

    /// 커널 인자: push0~5(float4: cx, cy, r, k), dir0~5(float2), eyeL·eyeR(float4: cx, cy, r, s). 빈 자리는 강도 0.
    static func arguments(for plan: WarpPlan) -> [Any] {
        var pushArgs: [CIVector] = []
        var dirArgs: [CIVector] = []
        for i in 0..<pushesPerPass {
            if i < plan.pushes.count {
                let p = plan.pushes[i]
                pushArgs.append(CIVector(x: p.center.x, y: p.center.y, z: p.radius, w: p.strength))
                dirArgs.append(CIVector(x: p.direction.dx, y: p.direction.dy))
            } else {
                pushArgs.append(CIVector(x: 0, y: 0, z: 1, w: 0))
                dirArgs.append(CIVector(x: 0, y: 0))
            }
        }
        var eyeArgs: [CIVector] = []
        for i in 0..<bulgesPerPass {
            if i < plan.bulges.count {
                let b = plan.bulges[i]
                eyeArgs.append(CIVector(x: b.center.x, y: b.center.y, z: b.radius, w: b.scale))
            } else {
                eyeArgs.append(CIVector(x: 0, y: 0, z: 1, w: 0))
            }
        }
        return pushArgs + dirArgs + eyeArgs
    }
}
