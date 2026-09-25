// 피부 마스크(0~1 그레이 CIImage) 생성: 얼굴 영역 폴리곤(눈·입 안쪽 제외, 가장자리 페더) × 피부색 가능도. 순수 함수.
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 피부 마스크 생성. 모든 함수는 부작용 없는 순수 함수다.
///
/// 비용 설계: 마스크는 **얼굴 주변 영역(region)만** 원본 해상도로 그린다(벡터 폴리곤 → 작은 CGImage).
/// 블러(페더)도 그 영역 안에서만 계산하고, 전체 크기 마스크가 필요할 때만 검정 배경 위에 합성한다.
enum SkinMask {
    /// 페더 반경 = 얼굴 너비 × 이 값.
    static let featherFraction: CGFloat = 0.04
    /// 치아 마스크 페더 = 얼굴 너비 × 이 값.
    static let teethFeatherFraction: CGFloat = 0.01
    /// 눈 폴리곤을 중심 기준으로 이만큼 키워서 뺀다(속눈썹·눈가 포함).
    static let eyeScale: CGFloat = 1.6
    static let maxFaces = 5

    // MARK: 공개 API

    /// 여러 얼굴의 피부 마스크를 합친 전체 크기 마스크(extent = imageExtent). 얼굴이 없으면 nil.
    /// - Parameters:
    ///   - source: 피부색 판정에 쓸 이미지. nil이거나 `kernels`가 nil이면 얼굴 영역 마스크만 쓴다(폴백).
    static func make(faces: [DetectedFace], imageExtent: CGRect,
                     source: CIImage? = nil, kernels: PortraitKernels?) -> CIImage? {
        let masks = faces.prefix(maxFaces).compactMap {
            faceSkinMask(for: $0, imageExtent: imageExtent, source: source, kernels: kernels)
        }
        return combine(masks, imageExtent: imageExtent)
    }

    /// 얼굴 하나의 피부 마스크. extent는 그 얼굴의 영역(`region(for:imageExtent:)`)이다.
    static func faceSkinMask(for face: DetectedFace, imageExtent: CGRect,
                             source: CIImage?, kernels: PortraitKernels?) -> CIImage? {
        guard let area = faceAreaMask(for: face, imageExtent: imageExtent) else { return nil }
        guard let source, let kernels,
              let skin = skinColorMask(source: source, region: area.extent, faceWidth: face.boundingBox.width, kernels: kernels)
        else { return area }
        // 얼굴 영역 × 피부색. 둘 다 그레이·알파 1이므로 곱 합성 결과도 그레이·알파 1.
        let f = CIFilter.multiplyCompositing()
        f.inputImage = skin
        f.backgroundImage = area
        return f.outputImage?.cropped(to: area.extent) ?? area
    }

    /// 얼굴 영역 마스크(피부색 판정 없음). 윤곽 폴리곤 + 이마 타원을 흰색으로, 눈(확대)·입 안쪽을 검정으로 그린 뒤 페더.
    static func faceAreaMask(for face: DetectedFace, imageExtent: CGRect) -> CIImage? {
        let w = face.boundingBox.width
        guard w > 0, !imageExtent.isInfinite else { return nil }
        let feather = max(0.5, w * featherFraction)
        let shapes = faceShapes(for: face)
        guard let region = region(bounds: shapes.bounds.union(face.boundingBox), margin: feather * 3 + 2,
                                   imageExtent: imageExtent) else { return nil }
        guard let hard = drawMask(region: region, polygons: shapes.fill, ellipses: shapes.ellipses,
                                  cutouts: shapes.cut) else { return nil }
        return feathered(hard, radius: feather, region: region)
    }

    /// 치아 미백 마스크: 입술 안쪽 폴리곤, 작은 페더. 점이 3개 미만이면 nil.
    static func teethMask(for face: DetectedFace, imageExtent: CGRect) -> CIImage? {
        let lips = face.landmarks.innerLips
        guard lips.count >= 3, face.boundingBox.width > 0 else { return nil }
        let feather = max(0.5, face.boundingBox.width * teethFeatherFraction)
        guard let region = region(bounds: boundingRect(lips), margin: feather * 3 + 2, imageExtent: imageExtent),
              let hard = drawMask(region: region, polygons: [lips], ellipses: [], cutouts: [])
        else { return nil }
        return feathered(hard, radius: feather, region: region)
    }

    /// 얼굴별 마스크(각자 작은 extent)를 최대값으로 합쳐 전체 크기(검정 배경) 마스크로. 비었으면 nil.
    static func combine(_ masks: [CIImage], imageExtent: CGRect) -> CIImage? {
        guard var merged = masks.first else { return nil }
        for mask in masks.dropFirst() {
            // 영역 밖은 투명(0)이므로 최대값 합성이 곧 합집합이다.
            merged = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: merged])
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: imageExtent)
        return merged.composited(over: black).cropped(to: imageExtent)
    }

    // MARK: 도형

    struct Shapes {
        var fill: [[CGPoint]] = []
        var ellipses: [EllipseShape] = []
        var cut: [[CGPoint]] = []
        var bounds: CGRect = .null
    }

    /// 중심·반지름·회전(라디안)으로 정의한 타원.
    struct EllipseShape {
        var center: CGPoint
        var radiusX: CGFloat
        var radiusY: CGFloat
        var angle: CGFloat

        var bounds: CGRect {
            let r = max(radiusX, radiusY)
            return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        }
    }

    /// 얼굴 하나에서 그릴 도형.
    /// - 윤곽(faceContour)은 턱선만 있고 이마가 없으므로, 두 눈이 있으면 이마를 덮는 타원을 더한다(머리카락은 피부색 마스크가 뺀다).
    /// - 윤곽이 없으면 boundingBox를 위로 20% 늘린 타원.
    static func faceShapes(for face: DetectedFace) -> Shapes {
        let lm = face.landmarks
        let box = face.boundingBox
        var shapes = Shapes()

        if lm.faceContour.count >= 3 {
            shapes.fill.append(lm.faceContour)
            shapes.bounds = boundingRect(lm.faceContour)
        } else {
            let ellipse = EllipseShape(center: CGPoint(x: box.midX, y: box.midY + box.height * 0.1),
                                       radiusX: box.width / 2, radiusY: box.height * 0.6, angle: 0)
            shapes.ellipses.append(ellipse)
            shapes.bounds = ellipse.bounds
        }

        if !lm.leftEye.isEmpty, !lm.rightEye.isEmpty {
            let le = centroid(lm.leftEye), re = centroid(lm.rightEye)
            let eyesMid = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
            let eyeDist = hypot(re.x - le.x, re.y - le.y)
            // 얼굴 위쪽 방향: 입 → 두 눈 중점. 입이 없으면 이미지 위쪽(+y).
            var up = CGVector(dx: 0, dy: 1)
            if !lm.outerLips.isEmpty {
                let mouth = centroid(lm.outerLips)
                let v = CGVector(dx: eyesMid.x - mouth.x, dy: eyesMid.y - mouth.y)
                let len = hypot(v.dx, v.dy)
                if len > 0 { up = CGVector(dx: v.dx / len, dy: v.dy / len) }
            }
            if eyeDist > 0 {
                let forehead = EllipseShape(
                    center: CGPoint(x: eyesMid.x + up.dx * eyeDist * 0.55, y: eyesMid.y + up.dy * eyeDist * 0.55),
                    radiusX: eyeDist * 1.05, radiusY: eyeDist * 0.75,
                    angle: atan2(up.dy, up.dx) - .pi / 2)
                shapes.ellipses.append(forehead)
                shapes.bounds = shapes.bounds.union(forehead.bounds)
            }
        }

        for eye in [lm.leftEye, lm.rightEye] where eye.count >= 3 {
            shapes.cut.append(scaled(eye, by: eyeScale))
        }
        if lm.innerLips.count >= 3 {
            shapes.cut.append(lm.innerLips)
        }
        return shapes
    }

    // MARK: 그리기

    /// `region`(정수 픽셀 사각형) 크기의 선형 그레이 CGImage에 도형을 그려 CIImage로. extent = region.
    /// Core Graphics 비트맵 컨텍스트는 원점이 좌하단(y 위쪽)이라 CIImage 좌표와 같다 → y 뒤집기 없음.
    static func drawMask(region: CGRect, polygons: [[CGPoint]], ellipses: [EllipseShape], cutouts: [[CGPoint]]) -> CIImage? {
        let width = Int(region.width), height = Int(region.height)
        // TODO(검증): 8비트 선형 그레이(알파 없음) 비트맵 컨텍스트가 만들어지는지. nil이면 DeviceGray로 바꾼다
        //             (값이 0/1 위주라 감마 차이는 페더 경계에만 약간 영향).
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: -region.minX, y: -region.minY)

        ctx.setFillColor(gray: 1, alpha: 1)
        for polygon in polygons where polygon.count >= 3 {
            ctx.addLines(between: polygon)
            ctx.closePath()
            ctx.fillPath()
        }
        for e in ellipses {
            ctx.saveGState()
            ctx.translateBy(x: e.center.x, y: e.center.y)
            ctx.rotate(by: e.angle)
            ctx.addEllipse(in: CGRect(x: -e.radiusX, y: -e.radiusY, width: 2 * e.radiusX, height: 2 * e.radiusY))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.setFillColor(gray: 0, alpha: 1)
        for polygon in cutouts where polygon.count >= 3 {
            ctx.addLines(between: polygon)
            ctx.closePath()
            ctx.fillPath()
        }

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
    }

    /// 영역 안에서만 가우시안 블러(페더). 영역 가장자리는 검정 여백이라 clamp해도 새는 값이 없다.
    static func feathered(_ mask: CIImage, radius: CGFloat, region: CGRect) -> CIImage {
        guard radius > 0 else { return mask }
        let f = CIFilter.gaussianBlur()
        f.inputImage = mask.clampedToExtent()
        f.radius = Float(radius)
        return f.outputImage?.cropped(to: region) ?? mask
    }

    /// 피부색 가능도 마스크(영역 한정). 가능도의 픽셀 잡음이 마스크 경계를 거칠게 만들지 않도록 살짝 블러.
    static func skinColorMask(source: CIImage, region: CGRect, faceWidth: CGFloat, kernels: PortraitKernels) -> CIImage? {
        guard let raw = kernels.skinMask(for: source, in: region) else { return nil }
        let radius = max(1, faceWidth * 0.006)
        let f = CIFilter.gaussianBlur()
        f.inputImage = raw.clampedToExtent()
        f.radius = Float(radius)
        return f.outputImage?.cropped(to: region) ?? raw
    }

    // MARK: 기하 보조

    /// bounds를 margin만큼 넓히고 정수 픽셀로 맞춘 뒤 이미지 안으로 자른다. 비면 nil.
    static func region(bounds: CGRect, margin: CGFloat, imageExtent: CGRect) -> CGRect? {
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        let r = bounds.insetBy(dx: -margin, dy: -margin).integral.intersection(imageExtent.integral)
        return r.isNull || r.isEmpty ? nil : r
    }

    static func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// 무게중심 기준 확대.
    static func scaled(_ points: [CGPoint], by factor: CGFloat) -> [CGPoint] {
        let c = centroid(points)
        return points.map { CGPoint(x: c.x + ($0.x - c.x) * factor, y: c.y + ($0.y - c.y) * factor) }
    }
}
