// 효과(R2): 촬영 탭 [효과] 버튼의 템플릿 20종 목록과, 얼굴 랜드마크에서 스티커·왜곡 위치를 정하는 기준점(순수 값).
import CoreGraphics
import Foundation

/// 효과 템플릿. rawValue는 `PresetParams.effect`에 저장되는 값이라 바꾸지 않는다.
/// 목록은 시중 앱(Snapchat·B612·SNOW·Photo Booth 등)의 인기 효과를 조사해 Apple 프레임워크만으로 만들 수 있는 것으로 골랐다.
enum EffectKind: String, CaseIterable, Identifiable, Codable {
    // 얼굴 스티커
    case puppyFace, catFace, bunnyEars, flowerCrown, crown, heartHalo, sunglasses, blushFreckles
    // 얼굴 변형
    case bigEyes, bigMouth, faceSwap
    // 렌즈
    case bulge, pinch, twirl, mirror, fisheye, lightTunnel
    // 스타일·배경
    case comic, thermal, backgroundSwap

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case sticker = "스티커", face = "얼굴", lens = "렌즈", style = "스타일"
    }

    var category: Category {
        switch self {
        case .puppyFace, .catFace, .bunnyEars, .flowerCrown, .crown, .heartHalo, .sunglasses, .blushFreckles: return .sticker
        case .bigEyes, .bigMouth, .faceSwap: return .face
        case .bulge, .pinch, .twirl, .mirror, .fisheye, .lightTunnel: return .lens
        case .comic, .thermal, .backgroundSwap: return .style
        }
    }

    var title: String {
        switch self {
        case .puppyFace: return "강아지"
        case .catFace: return "고양이"
        case .bunnyEars: return "토끼귀"
        case .flowerCrown: return "꽃왕관"
        case .crown: return "왕관"
        case .heartHalo: return "하트뿅뿅"
        case .sunglasses: return "선글라스"
        case .blushFreckles: return "볼터치"
        case .bigEyes: return "왕눈이"
        case .bigMouth: return "큰입"
        case .faceSwap: return "얼굴교환"
        case .bulge: return "볼록"
        case .pinch: return "오목"
        case .twirl: return "소용돌이"
        case .mirror: return "거울"
        case .fisheye: return "어안렌즈"
        case .lightTunnel: return "빛터널"
        case .comic: return "만화"
        case .thermal: return "열화상"
        case .backgroundSwap: return "배경바꾸기"
        }
    }

    /// 타일 아이콘(이모지).
    var icon: String {
        switch self {
        case .puppyFace: return "🐶"
        case .catFace: return "🐱"
        case .bunnyEars: return "🐰"
        case .flowerCrown: return "🌸"
        case .crown: return "👑"
        case .heartHalo: return "💕"
        case .sunglasses: return "🕶️"
        case .blushFreckles: return "☺️"
        case .bigEyes: return "👀"
        case .bigMouth: return "👄"
        case .faceSwap: return "🔄"
        case .bulge: return "🔮"
        case .pinch: return "🫨"
        case .twirl: return "🌀"
        case .mirror: return "🪞"
        case .fisheye: return "🐟"
        case .lightTunnel: return "💫"
        case .comic: return "💥"
        case .thermal: return "🌡️"
        case .backgroundSwap: return "🌈"
        }
    }

    /// 한 줄 설명(선택 화면).
    var summary: String {
        switch self {
        case .puppyFace: return "강아지 귀·코, 입 벌리면 혀"
        case .catFace: return "고양이 귀·수염·분홍 코"
        case .bunnyEars: return "쫑긋 토끼 귀 머리띠"
        case .flowerCrown: return "머리 위 꽃 화관"
        case .crown: return "금색 왕관"
        case .heartHalo: return "머리 주위를 도는 하트"
        case .sunglasses: return "눈에 맞는 선글라스"
        case .blushFreckles: return "발그레 볼터치·주근깨"
        case .bigEyes: return "눈만 크게"
        case .bigMouth: return "입이 커지는 웃긴 얼굴"
        case .faceSwap: return "두 사람 얼굴 바꾸기(2명 필요)"
        case .bulge: return "가운데가 볼록"
        case .pinch: return "가운데가 쏙"
        case .twirl: return "빙글빙글 소용돌이"
        case .mirror: return "좌우 대칭"
        case .fisheye: return "둥근 어안 렌즈"
        case .lightTunnel: return "빛 터널 속으로"
        case .comic: return "만화책 느낌"
        case .thermal: return "열화상 카메라"
        case .backgroundSwap: return "사람 뒤 배경을 무지개 그라데이션으로"
        }
    }

    /// 얼굴 검출이 필요한지. 렌즈 효과(볼록·오목·소용돌이·빛터널)는 얼굴이 있으면 얼굴 중심, 없으면 화면 중심.
    var usesFaces: Bool {
        switch category {
        case .sticker, .face: return true
        case .lens: return self == .bulge || self == .pinch || self == .twirl || self == .lightTunnel
        case .style: return false
        }
    }

    /// 사람 분리 마스크가 필요한지.
    var needsPersonMask: Bool { self == .backgroundSwap }

    /// 효과가 동작하는 최소 얼굴 수(얼굴교환 2, 스티커·얼굴 변형 1, 나머지 0).
    var minimumFaces: Int {
        switch self {
        case .faceSwap: return 2
        default: return category == .sticker || category == .face ? 1 : 0
        }
    }
}

// MARK: - 얼굴 기준점

/// 스티커·왜곡을 붙일 얼굴 기준점(이미지 픽셀 좌표, 원점 좌하단).
/// 크기 단위는 두 눈 사이 거리(IOD) — 얼굴 크기·거리와 무관하게 스티커 크기를 맞춘다.
struct FaceAnchors: Equatable {
    /// 이미지 왼쪽/오른쪽에 있는 눈 중심.
    var eyeLeft: CGPoint
    var eyeRight: CGPoint
    /// 두 눈 사이 거리(픽셀).
    var iod: CGFloat
    /// 기울기(라디안, 반시계 +): 왼쪽 눈 → 오른쪽 눈 벡터의 각도.
    var roll: CGFloat
    var noseTip: CGPoint
    var mouthCenter: CGPoint
    /// 입 벌림 정도(안쪽 입술 높이 / IOD). 0 = 다묾.
    var mouthOpen: CGFloat
    var faceCenter: CGPoint
    /// 얼굴 사각형 폭·높이.
    var faceSize: CGSize

    var eyeMid: CGPoint { CGPoint(x: (eyeLeft.x + eyeRight.x) / 2, y: (eyeLeft.y + eyeRight.y) / 2) }
    /// 얼굴 "위" 방향 단위 벡터(기울기 반영).
    var up: CGVector { CGVector(dx: -sin(roll), dy: cos(roll)) }
    /// 얼굴 "오른쪽"(이미지 기준) 단위 벡터.
    var right: CGVector { CGVector(dx: cos(roll), dy: sin(roll)) }

    /// 눈 중점에서 위로 `k`·IOD, 오른쪽으로 `r`·IOD 떨어진 점.
    func point(fromEyesUp k: CGFloat, right r: CGFloat = 0) -> CGPoint {
        offset(eyeMid, up: k * iod, right: r * iod)
    }

    func offset(_ p: CGPoint, up u: CGFloat, right r: CGFloat = 0) -> CGPoint {
        CGPoint(x: p.x + up.dx * u + right.dx * r, y: p.y + up.dy * u + right.dy * r)
    }

    /// 머리 꼭대기 추정: 눈 중점 위 1.8·IOD(성인 얼굴 비율 근사).
    var headTop: CGPoint { point(fromEyesUp: 1.8) }

    init(eyeLeft: CGPoint, eyeRight: CGPoint, noseTip: CGPoint, mouthCenter: CGPoint, mouthOpen: CGFloat,
         faceCenter: CGPoint, faceSize: CGSize) {
        self.eyeLeft = eyeLeft
        self.eyeRight = eyeRight
        let dx = eyeRight.x - eyeLeft.x, dy = eyeRight.y - eyeLeft.y
        iod = max(hypot(dx, dy), 1)
        roll = atan2(dy, dx)
        self.noseTip = noseTip
        self.mouthCenter = mouthCenter
        self.mouthOpen = mouthOpen
        self.faceCenter = faceCenter
        self.faceSize = faceSize
    }

    /// 검출된 얼굴 → 기준점. 랜드마크가 없으면 얼굴 사각형 비율로 추정한다.
    init(face: DetectedFace) {
        let box = face.boundingBox
        let lm = face.landmarks
        func mean(_ pts: [CGPoint]) -> CGPoint? {
            guard !pts.isEmpty else { return nil }
            let n = CGFloat(pts.count)
            return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
        }
        let fallbackL = CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.62)
        let fallbackR = CGPoint(x: box.minX + box.width * 0.7, y: box.minY + box.height * 0.62)
        var a = mean(lm.leftEye) ?? fallbackL
        var b = mean(lm.rightEye) ?? fallbackR
        if a.x > b.x { swap(&a, &b) }   // 이미지 왼쪽 눈이 먼저

        let dx = b.x - a.x, dy = b.y - a.y
        let roll = atan2(dy, dx)
        let upV = CGVector(dx: -sin(roll), dy: cos(roll))
        func height(_ p: CGPoint) -> CGFloat { p.x * upV.dx + p.y * upV.dy }

        // 코끝: 코 점 중 "위" 방향으로 가장 낮은 점.
        let nose = lm.nose.min { height($0) < height($1) }
            ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.4)
        let mouth = mean(lm.outerLips) ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.22)
        let iod = max(hypot(dx, dy), 1)
        var open: CGFloat = 0
        if let top = lm.innerLips.map(height).max(), let bottom = lm.innerLips.map(height).min() {
            open = max(top - bottom, 0) / iod
        }
        self.init(eyeLeft: a, eyeRight: b, noseTip: nose, mouthCenter: mouth, mouthOpen: open,
                  faceCenter: CGPoint(x: box.midX, y: box.midY), faceSize: box.size)
    }
}
