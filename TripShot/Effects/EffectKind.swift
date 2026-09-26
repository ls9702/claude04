// 효과(R2): 촬영 탭 [효과] 버튼의 템플릿 20종 목록과, 얼굴 랜드마크에서 스티커·왜곡 위치를 정하는 기준점(순수 값).
import CoreGraphics
import Foundation

/// 효과 템플릿. rawValue는 `PresetParams.effect`에 저장되는 값이라 바꾸지 않는다(없어진 값은 디코딩 시 무시된다).
/// 목록은 시중 앱(Snapchat·B612·SNOW·Photo Booth 등)의 인기 효과를 조사해 골랐다. 스티커 그림은 Fluent Emoji(MIT, Microsoft)
/// 벡터를 Mac에서 PNG로 변환해 번들에 넣었다(`Resources/Stickers`, 재생성: `tools/stickers`).
enum EffectKind: String, CaseIterable, Identifiable, Codable {
    // 스티커 16
    case puppyFace, catFace, bunnyEars, bearEars, mouseEars, flowerCrown, crown, heartHalo
    case sunglasses, nerdGlasses, ribbon, topHat, gradCap, butterflies, angelHalo, devilHorns
    // 얼굴 6
    case bigEyes, bigMouth, faceSwap, balloonFace, tinyFace, alien
    // 렌즈 22
    case bulge, pinch, twirl, mirror, fisheye, lightTunnel
    case mirrorVertical, kaleidoscope, glassRing, blackHole, stretch, vortex
    case ripple, wave, crystalBall, cylinder, splash, droste, triangleKaleido, eightfold, quadMirror, magnifier
    // 스타일 16
    case comic, thermal, backgroundSwap, popArt, colorPoint, snowfall
    case xray, sketch, neon, vintage, noir, mosaic, pointillism, halftone, crystallize, glitch

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case sticker = "스티커", face = "얼굴", lens = "렌즈", style = "스타일"
    }

    var category: Category {
        switch self {
        case .puppyFace, .catFace, .bunnyEars, .bearEars, .mouseEars, .flowerCrown, .crown, .heartHalo,
             .sunglasses, .nerdGlasses, .ribbon, .topHat, .gradCap, .butterflies, .angelHalo, .devilHorns:
            return .sticker
        case .bigEyes, .bigMouth, .faceSwap, .balloonFace, .tinyFace, .alien:
            return .face
        case .bulge, .pinch, .twirl, .mirror, .fisheye, .lightTunnel,
             .mirrorVertical, .kaleidoscope, .glassRing, .blackHole, .stretch, .vortex,
             .ripple, .wave, .crystalBall, .cylinder, .splash, .droste, .triangleKaleido, .eightfold, .quadMirror, .magnifier:
            return .lens
        case .comic, .thermal, .backgroundSwap, .popArt, .colorPoint, .snowfall,
             .xray, .sketch, .neon, .vintage, .noir, .mosaic, .pointillism, .halftone, .crystallize, .glitch:
            return .style
        }
    }

    var title: String {
        switch self {
        case .puppyFace: return "강아지"
        case .catFace: return "고양이"
        case .bunnyEars: return "토끼"
        case .bearEars: return "곰돌이"
        case .mouseEars: return "생쥐"
        case .flowerCrown: return "꽃왕관"
        case .crown: return "왕관"
        case .heartHalo: return "하트뿅뿅"
        case .sunglasses: return "선글라스"
        case .nerdGlasses: return "안경"
        case .ribbon: return "리본"
        case .topHat: return "신사모자"
        case .gradCap: return "학사모"
        case .butterflies: return "나비"
        case .angelHalo: return "천사링"
        case .devilHorns: return "악마뿔"
        case .bigEyes: return "왕눈이"
        case .bigMouth: return "큰입"
        case .faceSwap: return "얼굴교환"
        case .balloonFace: return "풍선얼굴"
        case .tinyFace: return "꼬마얼굴"
        case .alien: return "외계인"
        case .bulge: return "볼록"
        case .pinch: return "오목"
        case .twirl: return "소용돌이"
        case .mirror: return "좌우거울"
        case .fisheye: return "어안렌즈"
        case .lightTunnel: return "빛터널"
        case .mirrorVertical: return "상하거울"
        case .kaleidoscope: return "만화경"
        case .glassRing: return "유리링"
        case .blackHole: return "블랙홀"
        case .stretch: return "늘이기"
        case .vortex: return "회오리"
        case .comic: return "만화"
        case .thermal: return "열화상"
        case .backgroundSwap: return "배경바꾸기"
        case .popArt: return "팝아트"
        case .colorPoint: return "컬러포인트"
        case .snowfall: return "눈내림"
        case .ripple: return "물결"
        case .wave: return "일렁임"
        case .crystalBall: return "수정구슬"
        case .cylinder: return "원통"
        case .splash: return "스플래시"
        case .droste: return "무한반복"
        case .triangleKaleido: return "삼각만화경"
        case .eightfold: return "8방거울"
        case .quadMirror: return "4분할거울"
        case .magnifier: return "돋보기"
        case .xray: return "X레이"
        case .sketch: return "스케치"
        case .neon: return "네온"
        case .vintage: return "빈티지"
        case .noir: return "느와르"
        case .mosaic: return "모자이크"
        case .pointillism: return "점묘화"
        case .halftone: return "하프톤"
        case .crystallize: return "크리스탈"
        case .glitch: return "글리치"
        }
    }

    /// 타일에 쓸 스티커 그림 이름(`Resources/Stickers/stk_<이름>.png`). 없으면 `icon` 이모지.
    var tileAsset: String? {
        switch self {
        case .puppyFace: return "ears_dog"
        case .catFace: return "ears_cat"
        case .bunnyEars: return "ears_rabbit"
        case .bearEars: return "ears_bear"
        case .mouseEars: return "ears_mouse"
        case .flowerCrown: return "cherry_blossom"
        case .crown: return "crown"
        case .heartHalo: return "sparkling_heart"
        case .sunglasses: return "sunglasses"
        case .nerdGlasses: return "glasses"
        case .ribbon: return "ribbon"
        case .topHat: return "top_hat"
        case .gradCap: return "graduation_cap"
        case .butterflies: return "butterfly"
        case .angelHalo: return "halo"
        case .devilHorns: return "horns"
        case .snowfall: return "snowflake"
        default: return nil
        }
    }

    /// 타일 아이콘(이모지). 스티커는 `tileAsset` 그림을 우선한다.
    var icon: String {
        switch self {
        case .puppyFace: return "🐶"
        case .catFace: return "🐱"
        case .bunnyEars: return "🐰"
        case .bearEars: return "🐻"
        case .mouseEars: return "🐭"
        case .flowerCrown: return "🌸"
        case .crown: return "👑"
        case .heartHalo: return "💖"
        case .sunglasses: return "🕶️"
        case .nerdGlasses: return "👓"
        case .ribbon: return "🎀"
        case .topHat: return "🎩"
        case .gradCap: return "🎓"
        case .butterflies: return "🦋"
        case .angelHalo: return "😇"
        case .devilHorns: return "😈"
        case .bigEyes: return "👀"
        case .bigMouth: return "👄"
        case .faceSwap: return "🔄"
        case .balloonFace: return "🎈"
        case .tinyFace: return "🤏"
        case .alien: return "👽"
        case .bulge: return "🔮"
        case .pinch: return "🫨"
        case .twirl: return "🌀"
        case .mirror: return "🪞"
        case .fisheye: return "🐟"
        case .lightTunnel: return "💫"
        case .mirrorVertical: return "🙃"
        case .kaleidoscope: return "❄️"
        case .glassRing: return "💍"
        case .blackHole: return "🕳️"
        case .stretch: return "↔️"
        case .vortex: return "🌪️"
        case .comic: return "💥"
        case .thermal: return "🌡️"
        case .backgroundSwap: return "🌈"
        case .popArt: return "🎨"
        case .colorPoint: return "🎯"
        case .snowfall: return "☃️"
        case .ripple: return "💧"
        case .wave: return "🌊"
        case .crystalBall: return "🪩"
        case .cylinder: return "🥫"
        case .splash: return "💦"
        case .droste: return "♾️"
        case .triangleKaleido: return "🔺"
        case .eightfold: return "✳️"
        case .quadMirror: return "🪟"
        case .magnifier: return "🔍"
        case .xray: return "🩻"
        case .sketch: return "✏️"
        case .neon: return "🌃"
        case .vintage: return "📷"
        case .noir: return "🎬"
        case .mosaic: return "🟦"
        case .pointillism: return "🖌️"
        case .halftone: return "🔘"
        case .crystallize: return "💎"
        case .glitch: return "📺"
        }
    }

    /// 한 줄 설명(선택 화면).
    var summary: String {
        switch self {
        case .puppyFace: return "강아지 귀·코, 입 벌리면 혀"
        case .catFace: return "고양이 귀·코·수염"
        case .bunnyEars: return "쫑긋 토끼 귀·수염"
        case .bearEars: return "동글 곰 귀·주둥이"
        case .mouseEars: return "큰 생쥐 귀·수염"
        case .flowerCrown: return "머리 위 꽃 화관"
        case .crown: return "금색 왕관"
        case .heartHalo: return "머리 주위를 도는 하트"
        case .sunglasses: return "눈에 맞는 선글라스"
        case .nerdGlasses: return "파란 알 안경"
        case .ribbon: return "머리 위 빨간 리본"
        case .topHat: return "신사 실크햇"
        case .gradCap: return "졸업 학사모"
        case .butterflies: return "머리 주위를 나는 나비"
        case .angelHalo: return "머리 위 천사 링"
        case .devilHorns: return "보라색 악마 뿔"
        case .bigEyes: return "눈만 크게"
        case .bigMouth: return "입이 커지는 웃긴 얼굴"
        case .faceSwap: return "얼굴 바꾸기(2명 이상, 여러 명이면 돌아가며)"
        case .balloonFace: return "얼굴이 풍선처럼 부풂"
        case .tinyFace: return "얼굴이 쏙 작아짐"
        case .alien: return "왕눈에 작은 입"
        case .bulge: return "가운데가 볼록"
        case .pinch: return "가운데가 쏙"
        case .twirl: return "빙글빙글 소용돌이"
        case .mirror: return "좌우 대칭"
        case .fisheye: return "둥근 어안 렌즈"
        case .lightTunnel: return "빛 터널 속으로"
        case .mirrorVertical: return "위아래 대칭(물 반사)"
        case .kaleidoscope: return "여섯 갈래 만화경"
        case .glassRing: return "얼굴 둘레 유리 고리 굴절"
        case .blackHole: return "가운데로 빨려 들어감"
        case .stretch: return "가로로 쭉 늘어남"
        case .vortex: return "강한 회오리"
        case .comic: return "만화책 느낌"
        case .thermal: return "열화상 카메라"
        case .backgroundSwap: return "사람 뒤 배경을 그라데이션으로"
        case .popArt: return "네 칸 팝아트"
        case .colorPoint: return "사람만 컬러, 배경은 흑백"
        case .snowfall: return "눈송이가 내림"
        case .ripple: return "얼굴에서 퍼지는 동심원 물결"
        case .wave: return "물속처럼 좌우로 일렁임"
        case .crystalBall: return "뒤집힌 상이 비치는 수정 구슬"
        case .cylinder: return "원통에 감긴 듯 가운데가 커짐"
        case .splash: return "가장자리가 물보라처럼 퍼짐"
        case .droste: return "끝없이 안으로 말려 들어감"
        case .triangleKaleido: return "세모 조각 만화경"
        case .eightfold: return "여덟 방향 반사 무늬"
        case .quadMirror: return "위아래·좌우 모두 대칭"
        case .magnifier: return "얼굴 부분만 크게 보는 돋보기"
        case .xray: return "엑스레이 사진"
        case .sketch: return "연필 스케치"
        case .neon: return "어둠 속 네온 윤곽선"
        case .vintage: return "빛바랜 필름 사진"
        case .noir: return "흑백 영화"
        case .mosaic: return "큰 픽셀 모자이크"
        case .pointillism: return "점으로 찍은 그림"
        case .halftone: return "인쇄물 망점"
        case .crystallize: return "크리스탈 조각"
        case .glitch: return "화면 깨짐·색 번짐"
        }
    }

    /// 얼굴 검출이 필요한지. 렌즈 중 일부는 얼굴이 있으면 가장 큰 얼굴 중심, 없으면 화면 중심.
    var usesFaces: Bool {
        switch category {
        case .sticker, .face: return true
        case .lens:
            switch self {
            case .bulge, .pinch, .twirl, .lightTunnel, .glassRing, .blackHole, .vortex, .kaleidoscope,
                 .ripple, .crystalBall, .splash, .magnifier, .droste: return true
            default: return false
            }
        case .style: return false
        }
    }

    /// 사람 분리 마스크가 필요한지.
    var needsPersonMask: Bool { self == .backgroundSwap || self == .colorPoint }

    /// 효과가 동작하는 최소 얼굴 수(얼굴교환 2, 스티커·얼굴 변형 1, 나머지 0).
    var minimumFaces: Int {
        switch self {
        case .faceSwap: return 2
        default: return category == .sticker || category == .face ? 1 : 0
        }
    }

    /// 한 장면에서 효과를 적용할 최대 얼굴 수(단체 사진).
    static let maxFaces = 8
    /// 효과용 얼굴 최소 폭(짧은 변 대비). 인물 보정(12%)보다 작게 잡아 여러 명이 멀리 있어도 모두 적용한다.
    static let minFaceWidthFraction: CGFloat = 0.035
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
