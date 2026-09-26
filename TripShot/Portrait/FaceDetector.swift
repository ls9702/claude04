// Vision 얼굴 랜드마크 검출 래퍼(저장·앨범용 단발 검출)와 라이브용 시간축 평활 트래커.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

// MARK: - 결과 타입

/// 얼굴 랜드마크. 모든 점은 **이미지 픽셀 좌표**(CIImage 규약: 원점 좌하단, 이미지 extent 기준)다.
/// 검출되지 않은 부위는 빈 배열.
struct FaceLandmarks: Equatable {
    var faceContour: [CGPoint] = []
    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []
    var outerLips: [CGPoint] = []
    var innerLips: [CGPoint] = []
    var nose: [CGPoint] = []
    var leftEyebrow: [CGPoint] = []
    var rightEyebrow: [CGPoint] = []

    /// Vision 랜드마크 영역 → 이미지 픽셀 좌표(원점 = 이미지 좌하단 (0,0) 기준).
    /// - Parameters:
    ///   - boundingBox: `VNFaceObservation.boundingBox` — **정규화** 좌표(0~1, 원점 좌하단).
    ///   - imageSize: Vision에 넘긴 이미지의 픽셀 크기(방향 `.up` 기준).
    static func imagePoints(_ region: VNFaceLandmarkRegion2D?, boundingBox: CGRect, imageSize: CGSize) -> [CGPoint] {
        guard let region else { return [] }
        return imagePoints(normalized: region.normalizedPoints, boundingBox: boundingBox, imageSize: imageSize)
    }

    /// 테스트 가능한 순수 버전. `normalizedPoints`는 얼굴 boundingBox 기준 정규화 좌표(0~1, 원점 좌하단).
    ///
    /// 유도: 랜드마크 점 p는 boundingBox 안의 상대 위치이므로 이미지 정규화 좌표는
    ///   (bb.minX + p.x·bb.width, bb.minY + p.y·bb.height)
    /// 이고, 여기에 이미지 크기를 곱하면 픽셀 좌표가 된다. Vision과 CIImage 모두 원점이 좌하단이라 y 뒤집기는 없다.
    /// (`VNImagePointForFaceLandmarkPoint`와 같은 계산을 직접 한다 — 정수 크기 인자·vector_float2 변환을 피하려고.)
    static func imagePoints(normalized: [CGPoint], boundingBox: CGRect, imageSize: CGSize) -> [CGPoint] {
        normalized.map { p in
            CGPoint(x: (boundingBox.minX + p.x * boundingBox.width) * imageSize.width,
                    y: (boundingBox.minY + p.y * boundingBox.height) * imageSize.height)
        }
    }

    /// 모든 점을 평행 이동(이미지 extent 원점이 0이 아닐 때 보정용).
    func offsetBy(dx: CGFloat, dy: CGFloat) -> FaceLandmarks {
        guard dx != 0 || dy != 0 else { return self }
        func move(_ pts: [CGPoint]) -> [CGPoint] { pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        return FaceLandmarks(faceContour: move(faceContour), leftEye: move(leftEye), rightEye: move(rightEye),
                             outerLips: move(outerLips), innerLips: move(innerLips), nose: move(nose),
                             leftEyebrow: move(leftEyebrow), rightEyebrow: move(rightEyebrow))
    }

    /// 두 랜드마크를 점별로 선형 보간(t=0 → self, t=1 → other). 부위별 점 개수가 다르면 other를 쓴다.
    func interpolated(to other: FaceLandmarks, t: CGFloat) -> FaceLandmarks {
        func mix(_ a: [CGPoint], _ b: [CGPoint]) -> [CGPoint] {
            guard a.count == b.count, !a.isEmpty else { return b }
            return zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
        }
        return FaceLandmarks(faceContour: mix(faceContour, other.faceContour),
                             leftEye: mix(leftEye, other.leftEye), rightEye: mix(rightEye, other.rightEye),
                             outerLips: mix(outerLips, other.outerLips), innerLips: mix(innerLips, other.innerLips),
                             nose: mix(nose, other.nose),
                             leftEyebrow: mix(leftEyebrow, other.leftEyebrow),
                             rightEyebrow: mix(rightEyebrow, other.rightEyebrow))
    }
}

/// 검출된 얼굴 하나.
struct DetectedFace: Equatable {
    /// 이미지 픽셀 좌표, 원점 좌하단(CIImage 규약). 입력 이미지 extent와 같은 좌표계.
    var boundingBox: CGRect
    var landmarks: FaceLandmarks
    /// 라디안. Vision이 주지 않으면 nil.
    var roll: Double? = nil
    var yaw: Double? = nil

    var center: CGPoint { CGPoint(x: boundingBox.midX, y: boundingBox.midY) }
}

// MARK: - 검출기

/// Vision 얼굴 랜드마크 검출. 상태가 없어(CIContext만 공유) 여러 스레드에서 동시에 불러도 된다.
final class FaceDetector: @unchecked Sendable {
    /// 짧은 변 대비 얼굴 너비가 이보다 작으면 제외(너무 작은 얼굴은 마스크·블러가 아티팩트를 만들기 쉽다).
    /// 12% ≈ 넓이 1.5%. TODO(실기기): 단체 사진(5명)에서 얼굴이 빠지면 0.08로 낮춘다.
    static let minFaceWidthFraction: CGFloat = 0.12
    static let defaultMaxFaces = 5
    /// 저장 경로 기본 검출 해상도(긴 변). 풀해상도 12MP로 검출하지 않는다.
    static let defaultDetectionMaxDimension: CGFloat = 1024

    /// Vision이 CIImage를 렌더할 때 쓸 컨텍스트(매번 새로 만들지 않게).
    private let ciContext: CIContext

    init(ciContext: CIContext? = nil) {
        self.ciContext = ciContext ?? CIContext(options: [.cacheIntermediates: false])
    }

    /// 얼굴 검출. 실패·미검출이면 빈 배열(throw 안 함). 넓이 큰 순으로 최대 `maxFaces`개.
    /// - Parameters:
    ///   - image: 방향이 이미 반영된(세운) 이미지. 결과 좌표는 이 이미지의 extent 좌표계다.
    ///   - orientation: Vision에 알려 줄 방향. 이미 세운 CIImage면 `.up`(기본). `.up`이 아니면 결과 좌표는
    ///     회전된 이미지 기준이 되어 입력 extent와 맞지 않으므로 이 앱에서는 `.up`만 쓴다.
    ///   - detectionMaxDimension: 검출용 다운샘플 긴 변. 좌표는 원본 extent로 환산해 돌려준다.
    func detect(in image: CIImage,
                maxFaces: Int = FaceDetector.defaultMaxFaces,
                orientation: CGImagePropertyOrientation = .up,
                detectionMaxDimension: CGFloat = FaceDetector.defaultDetectionMaxDimension,
                minFaceWidthFraction: CGFloat = FaceDetector.minFaceWidthFraction) -> [DetectedFace] {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, maxFaces > 0 else { return [] }

        // 다운샘플(원점 0으로 이동 포함). 정규화 좌표는 해상도와 무관하므로 원본 extent 크기를 곱하면 된다.
        var small = EnhanceRenderer.downsample(image, maxDimension: detectionMaxDimension)
        if small.extent.origin != .zero {
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        }

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: small, orientation: orientation,
                                            options: [.ciContext: ciContext])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results, !observations.isEmpty else { return [] }

        let faces = observations.map { Self.face(from: $0, imageExtent: extent) }
        return Self.select(faces, imageExtent: extent, maxFaces: maxFaces, minFaceWidthFraction: minFaceWidthFraction)
    }

    /// 관측 하나 → 이미지 픽셀 좌표의 얼굴.
    static func face(from observation: VNFaceObservation, imageExtent: CGRect) -> DetectedFace {
        let bb = observation.boundingBox   // 정규화, 원점 좌하단
        let size = imageExtent.size
        let lm = observation.landmarks
        let landmarks = FaceLandmarks(
            faceContour: FaceLandmarks.imagePoints(lm?.faceContour, boundingBox: bb, imageSize: size),
            leftEye: FaceLandmarks.imagePoints(lm?.leftEye, boundingBox: bb, imageSize: size),
            rightEye: FaceLandmarks.imagePoints(lm?.rightEye, boundingBox: bb, imageSize: size),
            outerLips: FaceLandmarks.imagePoints(lm?.outerLips, boundingBox: bb, imageSize: size),
            innerLips: FaceLandmarks.imagePoints(lm?.innerLips, boundingBox: bb, imageSize: size),
            nose: FaceLandmarks.imagePoints(lm?.nose, boundingBox: bb, imageSize: size),
            leftEyebrow: FaceLandmarks.imagePoints(lm?.leftEyebrow, boundingBox: bb, imageSize: size),
            rightEyebrow: FaceLandmarks.imagePoints(lm?.rightEyebrow, boundingBox: bb, imageSize: size)
        ).offsetBy(dx: imageExtent.minX, dy: imageExtent.minY)
        let box = CGRect(x: imageExtent.minX + bb.minX * size.width,
                         y: imageExtent.minY + bb.minY * size.height,
                         width: bb.width * size.width,
                         height: bb.height * size.height)
        return DetectedFace(boundingBox: box, landmarks: landmarks,
                            roll: observation.roll?.doubleValue, yaw: observation.yaw?.doubleValue)
    }

    /// 너무 작은 얼굴 제외 → 넓이 큰 순 → 상위 `maxFaces`개. 순수 함수.
    /// 인물 보정은 짧은 변의 12%(`minFaceWidthFraction`), 효과(R2)는 여러 명 단체 사진까지 잡도록 더 작게 쓴다.
    static func select(_ faces: [DetectedFace], imageExtent: CGRect, maxFaces: Int,
                       minFaceWidthFraction: CGFloat = FaceDetector.minFaceWidthFraction) -> [DetectedFace] {
        let shortSide = min(imageExtent.width, imageExtent.height)
        let minWidth = shortSide * minFaceWidthFraction
        return faces
            .filter { $0.boundingBox.width >= minWidth }
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .prefix(max(0, maxFaces))
            .map { $0 }
    }
}

// MARK: - 시간축 평활(순수 로직)

/// 프레임마다 들어오는 검출 결과를 얼굴별로 추적해 지수 이동 평균으로 떨림을 줄인다.
/// - 매칭: 중심 거리가 가장 가까운 쌍부터 탐욕적으로(전역 최소 거리 우선) 짝짓는다. 거리 한도 = 얼굴 너비 × `matchDistanceFactor`.
/// - 짝이 없는 기존 얼굴은 `misses`를 올리고 마지막 값을 유지하다가 `maxMisses`번 연속 놓치면 제거.
/// - 결과 순서는 추적 id 순(처음 나타난 순)으로 고정 — 프레임마다 얼굴 순서가 바뀌지 않는다.
struct FaceSmoother {
    struct Track {
        let id: Int
        var face: DetectedFace
        var misses: Int
    }

    /// 새 검출의 가중치. 0.5 = 이전 평활값과 반반.
    var alpha: CGFloat = 0.5
    /// 이 횟수만큼 연속으로 놓치면 제거.
    var maxMisses: Int = 3
    var matchDistanceFactor: CGFloat = 0.6

    private(set) var tracks: [Track] = []
    private var nextID = 0

    init(alpha: CGFloat = 0.5, maxMisses: Int = 3) {
        self.alpha = alpha
        self.maxMisses = maxMisses
    }

    /// 현재 평활 결과(추적 id 순).
    var faces: [DetectedFace] { tracks.map(\.face) }

    /// 한 번의 검출 결과를 반영하고 평활 결과를 돌려준다.
    @discardableResult
    mutating func update(_ detections: [DetectedFace]) -> [DetectedFace] {
        // 모든 (추적, 검출) 쌍의 거리 → 가까운 순으로 짝짓기.
        var pairs: [(track: Int, det: Int, dist: CGFloat)] = []
        for (ti, track) in tracks.enumerated() {
            for (di, det) in detections.enumerated() {
                let dx = track.face.center.x - det.center.x
                let dy = track.face.center.y - det.center.y
                let dist = (dx * dx + dy * dy).squareRoot()
                let limit = max(track.face.boundingBox.width, det.boundingBox.width) * matchDistanceFactor
                if dist <= limit { pairs.append((ti, di, dist)) }
            }
        }
        pairs.sort { $0.dist < $1.dist }

        var usedTracks = Set<Int>()
        var usedDets = Set<Int>()
        for pair in pairs where !usedTracks.contains(pair.track) && !usedDets.contains(pair.det) {
            usedTracks.insert(pair.track)
            usedDets.insert(pair.det)
            tracks[pair.track].face = Self.blend(tracks[pair.track].face, detections[pair.det], alpha: alpha)
            tracks[pair.track].misses = 0
        }

        // 놓친 추적
        for ti in tracks.indices where !usedTracks.contains(ti) {
            tracks[ti].misses += 1
        }
        tracks.removeAll { $0.misses >= maxMisses }

        // 새 얼굴
        for (di, det) in detections.enumerated() where !usedDets.contains(di) {
            tracks.append(Track(id: nextID, face: det, misses: 0))
            nextID += 1
        }
        return faces
    }

    /// EMA: previous + α·(new − previous).
    static func blend(_ previous: DetectedFace, _ new: DetectedFace, alpha: CGFloat) -> DetectedFace {
        let a = previous.boundingBox, b = new.boundingBox
        let box = CGRect(x: a.minX + (b.minX - a.minX) * alpha,
                         y: a.minY + (b.minY - a.minY) * alpha,
                         width: a.width + (b.width - a.width) * alpha,
                         height: a.height + (b.height - a.height) * alpha)
        func mix(_ p: Double?, _ q: Double?) -> Double? {
            guard let p, let q else { return q }
            return p + (q - p) * Double(alpha)
        }
        return DetectedFace(boundingBox: box,
                            landmarks: previous.landmarks.interpolated(to: new.landmarks, t: alpha),
                            roll: mix(previous.roll, new.roll),
                            yaw: mix(previous.yaw, new.yaw))
    }
}

// MARK: - 라이브 트래커

/// 라이브 프리뷰용 얼굴 추적. N프레임마다 검출하고 사이 프레임은 마지막 평활 결과를 재사용한다.
///
/// 스레드 규칙:
/// - `faces(in:)`는 **카메라 비디오 큐(직렬)에서만** 부른다. 평활 상태는 그 큐 전용(잠금 없음).
/// - `faceCount`·`lastFaceRects`·`reset()`은 어느 스레드에서나(보통 메인) 부른다. 잠금으로 보호되는 값만 만진다.
final class SmoothedFaceTracker: @unchecked Sendable {
    static let defaultInterval = 3
    /// 라이브 검출 해상도. 프리뷰(≤1024)를 한 번 더 줄여 Vision 비용을 낮춘다.
    /// TODO(실기기): 얼굴이 자주 놓치면 1024로 올린다.
    static let liveDetectionMaxDimension: CGFloat = 640
    /// 이 시간(초) 동안 갱신이 없으면 `faceCount`는 0(인물 단계가 호출되지 않는 상태).
    static let countStaleSeconds: TimeInterval = 1

    let detector: FaceDetector
    let interval: Int
    let detectionMaxDimension: CGFloat
    let maxFaces: Int
    let minFaceWidthFraction: CGFloat

    // 비디오 큐 전용
    private var smoother = FaceSmoother()
    private var frameIndex = 0
    private var lastExtent: CGRect = .null
    private var current: [DetectedFace] = []

    // 잠금 보호
    private let lock = NSLock()
    private var sharedCount = 0
    /// 마지막 프레임의 얼굴 사각형(프리뷰 이미지 정규화 좌표 0~1, 원점 좌하단). 화면 마커용(R1-S8b).
    private var sharedRects: [CGRect] = []
    /// 마지막 프레임의 이미지 크기(마커를 뷰 좌표로 옮길 때 aspect-fill 계산용).
    private var sharedImageSize: CGSize = .zero
    private var lastUpdate: TimeInterval = 0
    private var resetRequested = false

    init(detector: FaceDetector = FaceDetector(),
         interval: Int = SmoothedFaceTracker.defaultInterval,
         detectionMaxDimension: CGFloat = SmoothedFaceTracker.liveDetectionMaxDimension,
         maxFaces: Int = FaceDetector.defaultMaxFaces,
         minFaceWidthFraction: CGFloat = FaceDetector.minFaceWidthFraction) {
        self.detector = detector
        self.maxFaces = maxFaces
        self.minFaceWidthFraction = minFaceWidthFraction
        self.interval = max(1, interval)
        self.detectionMaxDimension = detectionMaxDimension
    }

    /// 이번 프레임의 (평활된) 얼굴. 비디오 큐 전용.
    func faces(in image: CIImage) -> [DetectedFace] {
        let needsReset = lock.withLock { () -> Bool in
            let r = resetRequested
            resetRequested = false
            return r
        }
        // 해상도가 바뀌면(발열로 프리뷰 축소 등) 이전 좌표가 맞지 않으므로 처음부터.
        if needsReset || image.extent != lastExtent {
            smoother = FaceSmoother()
            frameIndex = 0
            current = []
            lastExtent = image.extent
        }
        if frameIndex % interval == 0 {
            let detected = detector.detect(in: image, maxFaces: maxFaces, detectionMaxDimension: detectionMaxDimension,
                                           minFaceWidthFraction: minFaceWidthFraction)
            current = smoother.update(detected)
        }
        frameIndex &+= 1

        let count = current.count
        let rects = Self.normalizedRects(current, in: image.extent)
        let size = image.extent.size
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            sharedCount = count
            sharedRects = rects
            sharedImageSize = size
            lastUpdate = now
        }
        return current
    }

    /// 화면 표시용 얼굴 수. 최근 1초 안에 갱신되지 않았으면 0.
    var faceCount: Int {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock { now - lastUpdate < Self.countStaleSeconds ? sharedCount : 0 }
    }

    /// 화면 마커용 얼굴 사각형(정규화, 원점 좌하단)과 이미지 크기, 마지막 갱신 시각(`systemUptime`).
    /// 최근 1초 안에 갱신되지 않았으면 빈 배열(인물 단계가 호출되지 않는 상태·원본 보기 중).
    var lastFaceRects: (rects: [CGRect], imageSize: CGSize, lastUpdate: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            let fresh = now - lastUpdate < Self.countStaleSeconds
            return (fresh ? sharedRects : [], sharedImageSize, lastUpdate)
        }
    }

    /// 얼굴 boundingBox(이미지 픽셀, extent 기준) → 이미지 정규화 좌표(0~1, 원점 좌하단). 순수 함수.
    static func normalizedRects(_ faces: [DetectedFace], in extent: CGRect) -> [CGRect] {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return [] }
        return faces.map { f in
            let b = f.boundingBox
            return CGRect(x: (b.minX - extent.minX) / extent.width,
                          y: (b.minY - extent.minY) / extent.height,
                          width: b.width / extent.width,
                          height: b.height / extent.height)
        }
    }

    /// 추적 상태를 비운다(인물 모드 끔 등). 실제 초기화는 다음 프레임에 비디오 큐에서 한다.
    func reset() {
        lock.withLock {
            resetRequested = true
            sharedCount = 0
            sharedRects = []
            lastUpdate = 0
        }
    }
}
