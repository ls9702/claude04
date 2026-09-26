// 쇼츠 템플릿(R3-S2): 여행 쇼츠에서 많이 쓰는 전환 기법 10가지를 칸(길이·촬영 안내·가이드 도형)과 전환 방식으로 정의한다.
// 템플릿은 앱 코드에 고정(프로젝트는 `templateKey`로 참조). 칸 촬영 화면(R3-S3)이 `SlotGuide`를 그리고, 조립(R3-S4)이 `transition`을 쓴다.
import CoreGraphics
import Foundation

/// 칸 사이 전환.
enum ShortsTransition: String, Codable, CaseIterable {
    /// 바로 이어 붙임(장면 자체가 이어지게 찍는 템플릿: 순간이동·손 가리기·프레임 밖으로·같은 포즈).
    case cut
    /// 겹치며 서서히(0.4초).
    case dissolve
    /// 오른쪽으로 휙(가로 흔들림 블러 + 밀어내기, 0.3초).
    case whipRight
    /// 가운데로 확대해 들어가기(0.35초).
    case zoomIn
    /// 위로 밀어 올리기(하늘로 넘기기, 0.4초).
    case slideUp
    /// 화면이 빙글 돌며 넘어감(카메라 돌리기, 0.4초).
    case spin

    /// 전환 길이(초). 컷은 0.
    var duration: Double {
        switch self {
        case .cut: return 0
        case .dissolve: return 0.4
        case .whipRight: return 0.3
        case .zoomIn: return 0.35
        case .slideUp: return 0.4
        case .spin: return 0.4
        }
    }

    var title: String {
        switch self {
        case .cut: return "컷"
        case .dissolve: return "디졸브"
        case .whipRight: return "휙 패닝"
        case .zoomIn: return "줌 인"
        case .slideUp: return "위로 넘기기"
        case .spin: return "회전"
        }
    }
}

/// 즉석 촬영 화면 위에 그릴 가이드(좌표는 화면 비율 0~1, 원점 좌상단).
struct SlotGuide: Codable, Equatable {
    enum Silhouette: String, Codable {
        /// 정면으로 선 사람
        case standing
        /// 뒷모습
        case back
        /// 두 팔을 든 포즈
        case armsUp
    }

    enum Arrow: String, Codable {
        /// 왼쪽 밖에서 들어오기 / 오른쪽 밖에서 들어오기 / 왼쪽으로 나가기 / 오른쪽으로 나가기 / 위로 / 아래로 / 오른쪽으로 휙 / 시계 방향으로 돌리기
        case enterFromLeft, enterFromRight, exitLeft, exitRight, up, down, whipRight, rotate
    }

    var silhouette: Silhouette? = nil
    /// 실루엣 가운데 x(0~1)와 발끝 y(0~1), 키(화면 높이 대비).
    var silhouetteX: Double = 0.5
    var silhouetteFootY: Double = 0.88
    var silhouetteHeight: Double = 0.55
    /// 시작할 때 보일 화살표(촬영 시작 전~초반).
    var startArrow: Arrow? = nil
    /// 끝날 때 보일 화살표(마지막 1초).
    var endArrow: Arrow? = nil
    /// 가운데 원(줌 인 목표).
    var centerCircle = false
    /// 앞 칸의 마지막 장면을 반투명으로 겹쳐 보여 준다(같은 자리·자세 맞추기).
    var ghostPrevious = false
    /// 시작·끝에 크게 보일 짧은 지시(예: "손으로 렌즈 가리기").
    var startCue: String? = nil
    var endCue: String? = nil
    /// 수평선 기준선(화면 높이 비율). nil이면 없음.
    var horizonY: Double? = nil
}

/// 칸 하나.
struct SlotSpec: Codable, Equatable, Identifiable {
    var id: Int { index }
    var index: Int
    var title: String
    /// 촬영 안내(칸 카드·촬영 화면 위).
    var instruction: String
    /// 결과물에서 이 칸이 차지하는 길이(초).
    var seconds: Double
    var guide: SlotGuide
}

/// 템플릿 하나.
struct ShortsTemplate: Identifiable, Equatable {
    /// 저장용 키(바꾸지 않는다).
    let id: String
    let name: String
    let summary: String
    /// 목록 아이콘(SF Symbol).
    let symbol: String
    let slots: [SlotSpec]
    let transition: ShortsTransition
    /// 권장 박자(비트 컷 템플릿). 음악을 붙이면 칸 경계를 박자에 맞춘다(R3-S5).
    let beatsPerMinute: Double?

    /// 결과물 전체 길이(전환이 겹치는 만큼 뺀 값).
    var totalSeconds: Double {
        let sum = slots.reduce(0) { $0 + $1.seconds }
        return sum - transition.duration * Double(max(slots.count - 1, 0))
    }
}

extension ShortsTemplate {
    /// 음악 bpm에 맞춘 칸 길이(R3-S5). 칸마다 템플릿 bpm 기준 박 수를 유지한다(1박 = 60/bpm).
    /// 비트 컷(120bpm, 칸 1초 = 2박)은 음악이 100bpm이면 칸 1.2초(2박). 템플릿 bpm이 없거나 bpm이 0 이하면 원래 길이.
    func slotSecondsAdjusted(forBPM bpm: Double) -> [Double] {
        guard let templateBPM = beatsPerMinute, templateBPM > 0, bpm > 0 else { return slots.map(\.seconds) }
        return slots.map { $0.seconds * templateBPM / bpm }
    }
}

enum ShortsTemplateLibrary {
    static func template(for key: String?) -> ShortsTemplate? {
        guard let key else { return nil }
        return all.first { $0.id == key }
    }

    /// 칸 목록 만들기 도우미.
    private static func slots(_ items: [(String, String, Double, SlotGuide)]) -> [SlotSpec] {
        items.enumerated().map { i, item in
            SlotSpec(index: i, title: item.0, instruction: item.1, seconds: item.2, guide: item.3)
        }
    }

    static let all: [ShortsTemplate] = [
        walkTeleport, handCover, whipPan, zoomJump, outOfFrame, samePose, skyTilt, lookBack, beatCut, basicStory,
        jumpTeleport, cameraSpin, wallWipe, fingerSnap, panoramaFlow,
    ]

    // 1. 걸어서 순간이동
    static let walkTeleport: ShortsTemplate = {
        let first = SlotGuide(silhouette: .standing, startArrow: .enterFromLeft)
        let next = SlotGuide(silhouette: .standing, ghostPrevious: true, startCue: "앞 영상과 같은 자리·걸음으로")
        return ShortsTemplate(
            id: "walkTeleport", name: "걸어서 순간이동",
            summary: "같은 자리를 걷는데 걸음마다 장소가 바뀌어요",
            symbol: "figure.walk.motion",
            slots: slots([
                ("장소 1", "카메라를 고정하고, 실루엣 자리를 향해 걸어오세요.", 3.5, first),
                ("장소 2", "앞 영상의 마지막 모습(반투명)에 몸을 맞춘 채 이어서 걸으세요.", 3.5, next),
                ("장소 3", "같은 거리·같은 높이에서 이어 걷기.", 3.5, next),
                ("장소 4", "같은 거리·같은 높이에서 이어 걷기.", 3.5, next),
                ("장소 5", "마지막 장소에서 멈추고 카메라를 보세요.", 3.5, next),
            ]),
            transition: .cut, beatsPerMinute: nil)
    }()

    // 2. 손으로 가리기
    static let handCover: ShortsTemplate = {
        let g = SlotGuide(silhouette: .standing, startCue: "손바닥으로 렌즈를 가렸다가 떼며 시작", endCue: "끝에 손바닥으로 렌즈 가리기")
        return ShortsTemplate(
            id: "handCover", name: "손으로 가리기",
            summary: "렌즈를 손으로 가렸다 떼면 다른 장소",
            symbol: "hand.raised.fill",
            slots: slots([
                ("장소 1", "끝날 때 손바닥으로 렌즈를 완전히 가리세요.", 4, SlotGuide(silhouette: .standing, endCue: "끝에 손바닥으로 렌즈 가리기")),
                ("장소 2", "가린 상태로 시작해 손을 떼고, 끝에 다시 가리기.", 4, g),
                ("장소 3", "가린 상태로 시작해 손을 떼고, 끝에 다시 가리기.", 4, g),
                ("장소 4", "가린 상태로 시작해 손을 떼며 마무리.", 4, SlotGuide(silhouette: .standing, startCue: "손바닥으로 렌즈를 가렸다가 떼며 시작")),
            ]),
            transition: .cut, beatsPerMinute: nil)
    }()

    // 3. 휙 패닝
    static let whipPan: ShortsTemplate = {
        let g = SlotGuide(startArrow: .enterFromLeft, endArrow: .whipRight, startCue: "왼쪽에서 휙 들어오며 시작", endCue: "오른쪽으로 휙!")
        return ShortsTemplate(
            id: "whipPan", name: "휙 패닝",
            summary: "카메라를 빠르게 돌린 흔들림으로 장면이 넘어가요",
            symbol: "arrow.right.to.line",
            slots: slots([
                ("장면 1", "풍경을 담다가 마지막 1초에 카메라를 오른쪽으로 빠르게 돌리세요.", 3, SlotGuide(endArrow: .whipRight, endCue: "오른쪽으로 휙!")),
                ("장면 2", "왼쪽에서 휙 들어오며 시작, 끝에 다시 오른쪽으로 휙.", 3, g),
                ("장면 3", "왼쪽에서 휙 들어오며 시작, 끝에 다시 오른쪽으로 휙.", 3, g),
                ("장면 4", "왼쪽에서 휙 들어오며 시작, 끝에 다시 오른쪽으로 휙.", 3, g),
                ("장면 5", "왼쪽에서 휙 들어오며 시작하고 천천히 멈추기.", 3, SlotGuide(startArrow: .enterFromLeft, startCue: "왼쪽에서 휙 들어오며 시작")),
            ]),
            transition: .whipRight, beatsPerMinute: nil)
    }()

    // 4. 줌 인 점프
    static let zoomJump: ShortsTemplate = {
        let g = SlotGuide(centerCircle: true, endCue: "원 안 물체로 다가가기")
        return ShortsTemplate(
            id: "zoomJump", name: "줌 인 점프",
            summary: "한 점으로 빨려 들어가면 다음 장소",
            symbol: "plus.magnifyingglass",
            slots: slots([
                ("장면 1", "가운데 원 안에 간판·문·음식 등을 두고, 끝에 그쪽으로 다가가세요.", 3, g),
                ("장면 2", "가운데 원 안에 물체를 두고 끝에 다가가기.", 3, g),
                ("장면 3", "가운데 원 안에 물체를 두고 끝에 다가가기.", 3, g),
                ("장면 4", "가운데 원 안에 물체를 두고 끝에 다가가기.", 3, g),
                ("장면 5", "마지막 장면은 뒤로 물러나며 전경을 보여 주세요.", 3, SlotGuide(centerCircle: true)),
            ]),
            transition: .zoomIn, beatsPerMinute: nil)
    }()

    // 5. 프레임 밖으로
    static let outOfFrame: ShortsTemplate = {
        let g = SlotGuide(silhouette: .standing, startArrow: .enterFromRight, endArrow: .exitLeft,
                          startCue: "오른쪽 밖에서 걸어 들어오기", endCue: "왼쪽으로 걸어 나가기")
        return ShortsTemplate(
            id: "outOfFrame", name: "프레임 밖으로",
            summary: "왼쪽으로 나가면 다음 장소에서 오른쪽으로 등장",
            symbol: "figure.walk.departure",
            slots: slots([
                ("장소 1", "카메라를 고정. 화면에 있다가 왼쪽 밖으로 걸어 나가세요.", 4,
                 SlotGuide(silhouette: .standing, endArrow: .exitLeft, endCue: "왼쪽으로 걸어 나가기")),
                ("장소 2", "오른쪽 밖에서 들어와 왼쪽으로 나가기.", 4, g),
                ("장소 3", "오른쪽 밖에서 들어와 왼쪽으로 나가기.", 4, g),
                ("장소 4", "오른쪽 밖에서 들어와 가운데에서 멈추기.", 4,
                 SlotGuide(silhouette: .standing, startArrow: .enterFromRight, startCue: "오른쪽 밖에서 걸어 들어오기")),
            ]),
            transition: .cut, beatsPerMinute: nil)
    }()

    // 6. 같은 포즈 여러 장소
    static let samePose: ShortsTemplate = {
        let g = SlotGuide(silhouette: .armsUp, ghostPrevious: true, startCue: "같은 포즈로")
        let first = SlotGuide(silhouette: .armsUp, startCue: "만세 포즈로")
        let items: [(String, String, Double, SlotGuide)] = (1...8).map { i in
            ("장소 \(i)", i == 1 ? "실루엣에 몸을 맞춰 두 팔을 들고 서세요." : "앞 영상 모습(반투명)과 같은 크기·자세로 서세요.", 1.2, i == 1 ? first : g)
        }
        return ShortsTemplate(
            id: "samePose", name: "같은 포즈 여러 장소",
            summary: "같은 포즈 그대로 장소만 빠르게 바뀌어요",
            symbol: "figure.arms.open",
            slots: slots(items),
            transition: .cut, beatsPerMinute: 100)
    }()

    // 7. 하늘로 넘기기
    static let skyTilt: ShortsTemplate = {
        let g = SlotGuide(startArrow: .down, endArrow: .up, startCue: "하늘에서 내려오며 시작", endCue: "하늘로 올려 찍기", horizonY: 0.5)
        return ShortsTemplate(
            id: "skyTilt", name: "하늘로 넘기기",
            summary: "하늘로 올라갔다 다음 장소로 내려와요",
            symbol: "cloud.sun.fill",
            slots: slots([
                ("장소 1", "장소를 담다가 끝에 카메라를 하늘로 천천히 올리세요.", 4,
                 SlotGuide(endArrow: .up, endCue: "하늘로 올려 찍기", horizonY: 0.5)),
                ("장소 2", "하늘에서 시작해 내려오고, 끝에 다시 하늘로.", 4, g),
                ("장소 3", "하늘에서 시작해 내려오고, 끝에 다시 하늘로.", 4, g),
                ("장소 4", "하늘에서 시작해 내려와 멈추기.", 4,
                 SlotGuide(startArrow: .down, startCue: "하늘에서 내려오며 시작", horizonY: 0.5)),
            ]),
            transition: .slideUp, beatsPerMinute: nil)
    }()

    // 8. 뒤돌아보기
    static let lookBack: ShortsTemplate = {
        let g = SlotGuide(silhouette: .back, startCue: "뒷모습으로 서 있다가", endCue: "천천히 뒤돌아보기")
        return ShortsTemplate(
            id: "lookBack", name: "뒤돌아보기",
            summary: "뒷모습에서 돌아보면 다음 장소",
            symbol: "person.fill.turn.left",
            slots: slots([
                ("장소 1", "풍경을 보는 뒷모습으로 서 있다가 끝에 카메라 쪽으로 돌아보세요.", 4, g),
                ("장소 2", "같은 자리·크기로 뒷모습 → 돌아보기.", 4, g),
                ("장소 3", "같은 자리·크기로 뒷모습 → 돌아보기.", 4, g),
                ("장소 4", "돌아보며 웃기로 마무리.", 4, g),
            ]),
            transition: .dissolve, beatsPerMinute: nil)
    }()

    // 9. 비트 컷
    static let beatCut: ShortsTemplate = {
        let items: [(String, String, Double, SlotGuide)] = (1...10).map { i in
            ("컷 \(i)", "1초짜리 짧은 장면. 움직임이 있는 것일수록 좋아요.", 1.0, SlotGuide())
        }
        return ShortsTemplate(
            id: "beatCut", name: "비트 컷",
            summary: "짧은 장면 10개를 박자에 맞춰 빠르게",
            symbol: "metronome.fill",
            slots: slots(items),
            transition: .cut, beatsPerMinute: 120)
    }()

    // 10. 오프닝·엔딩 기본형
    static let basicStory: ShortsTemplate = ShortsTemplate(
        id: "basicStory", name: "여행 기본형",
        summary: "풍경 → 인물 → 음식 → 디테일 → 엔딩",
        symbol: "film.stack",
        slots: slots([
            ("오프닝", "장소가 한눈에 보이는 넓은 풍경.", 3.5, SlotGuide(horizonY: 0.45)),
            ("인물", "여행하는 사람. 실루엣 자리에 서서 자연스럽게.", 4, SlotGuide(silhouette: .standing)),
            ("음식", "가까이서, 김·단면이 보이게.", 3.5, SlotGuide(centerCircle: true)),
            ("디테일", "간판·소품·손 같은 작은 것.", 3, SlotGuide(centerCircle: true)),
            ("엔딩", "노을·뒷모습 등 여운이 남는 장면.", 4, SlotGuide(silhouette: .back)),
        ]),
        transition: .dissolve, beatsPerMinute: nil)

    // 11. 점프 순간이동
    static let jumpTeleport: ShortsTemplate = {
        let g = SlotGuide(silhouette: .standing, ghostPrevious: true, startCue: "공중에서 착지하며 시작", endCue: "점프!")
        return ShortsTemplate(
            id: "jumpTeleport", name: "점프 순간이동",
            summary: "뛰어오를 때마다 다른 장소에 착지",
            symbol: "figure.jumprope",
            slots: slots([
                ("장소 1", "실루엣 자리에 서 있다가 끝에 제자리에서 높이 점프하세요.", 2.5,
                 SlotGuide(silhouette: .standing, endCue: "점프!")),
                ("장소 2", "같은 자리·크기로, 점프 착지로 시작해 끝에 다시 점프.", 2.5, g),
                ("장소 3", "같은 자리·크기로, 점프 착지로 시작해 끝에 다시 점프.", 2.5, g),
                ("장소 4", "같은 자리·크기로, 점프 착지로 시작해 끝에 다시 점프.", 2.5, g),
                ("장소 5", "착지하며 시작해 포즈로 마무리.", 2.5,
                 SlotGuide(silhouette: .standing, ghostPrevious: true, startCue: "공중에서 착지하며 시작")),
            ]),
            transition: .cut, beatsPerMinute: nil)
    }()

    // 12. 카메라 돌리기
    static let cameraSpin: ShortsTemplate = {
        let g = SlotGuide(startArrow: .rotate, endArrow: .rotate, startCue: "돌리던 방향 그대로 멈추며 시작", endCue: "시계 방향으로 휙 돌리기")
        return ShortsTemplate(
            id: "cameraSpin", name: "카메라 돌리기",
            summary: "폰을 빙글 돌리면 화면이 돌며 다음 장소",
            symbol: "arrow.clockwise.circle",
            slots: slots([
                ("장소 1", "끝 1초에 폰을 시계 방향으로 빠르게 돌리세요.", 3, SlotGuide(endArrow: .rotate, endCue: "시계 방향으로 휙 돌리기")),
                ("장소 2", "돌아가던 상태로 시작해 멈추고, 끝에 다시 돌리기.", 3, g),
                ("장소 3", "돌아가던 상태로 시작해 멈추고, 끝에 다시 돌리기.", 3, g),
                ("장소 4", "돌아가던 상태로 시작해 멈추며 마무리.", 3, SlotGuide(startArrow: .rotate, startCue: "돌리던 방향 그대로 멈추며 시작")),
            ]),
            transition: .spin, beatsPerMinute: nil)
    }()

    // 13. 벽 스치기
    static let wallWipe: ShortsTemplate = {
        let g = SlotGuide(startArrow: .enterFromLeft, endArrow: .whipRight,
                          startCue: "기둥·벽 뒤에서 나오며 시작", endCue: "기둥·벽 뒤로 지나가며 가리기")
        return ShortsTemplate(
            id: "wallWipe", name: "벽 스치기",
            summary: "기둥이나 벽이 화면을 가리는 순간 장소가 바뀜",
            symbol: "rectangle.portrait.lefthalf.inset.filled",
            slots: slots([
                ("장소 1", "걸으며 찍다가 끝에 기둥·나무·벽이 화면을 꽉 가리도록 옆으로 지나가세요.", 3.5,
                 SlotGuide(endArrow: .whipRight, endCue: "기둥·벽 뒤로 지나가며 가리기")),
                ("장소 2", "가려진 상태에서 나오며 시작, 끝에 다시 가리기.", 3.5, g),
                ("장소 3", "가려진 상태에서 나오며 시작, 끝에 다시 가리기.", 3.5, g),
                ("장소 4", "가려진 상태에서 나오며 마무리.", 3.5,
                 SlotGuide(startArrow: .enterFromLeft, startCue: "기둥·벽 뒤에서 나오며 시작")),
            ]),
            transition: .cut, beatsPerMinute: nil)
    }()

    // 14. 손가락 스냅
    static let fingerSnap: ShortsTemplate = {
        let g = SlotGuide(silhouette: .standing, ghostPrevious: true, startCue: "스냅 직후 자세로 시작", endCue: "딱! 손가락 튕기기")
        return ShortsTemplate(
            id: "fingerSnap", name: "손가락 스냅",
            summary: "딱! 손가락을 튕길 때마다 장소·옷이 바뀜",
            symbol: "hand.point.up.left.fill",
            slots: slots([
                ("장소 1", "카메라를 보며 서 있다가 끝에 손가락을 딱 튕기세요.", 3,
                 SlotGuide(silhouette: .standing, endCue: "딱! 손가락 튕기기")),
                ("장소 2", "튕긴 손 그대로 시작해, 끝에 다시 딱!", 3, g),
                ("장소 3", "튕긴 손 그대로 시작해, 끝에 다시 딱!", 3, g),
                ("장소 4", "튕긴 손 그대로 시작해 웃으며 마무리.", 3,
                 SlotGuide(silhouette: .standing, ghostPrevious: true, startCue: "스냅 직후 자세로 시작")),
            ]),
            transition: .cut, beatsPerMinute: nil)
    }()

    // 15. 파노라마 이어가기
    static let panoramaFlow: ShortsTemplate = {
        let g = SlotGuide(startArrow: .enterFromLeft, endArrow: .exitRight, startCue: "왼쪽에서 오른쪽으로 천천히", horizonY: 0.5)
        return ShortsTemplate(
            id: "panoramaFlow", name: "파노라마 이어가기",
            summary: "천천히 옆으로 돌리는 풍경이 장소를 넘어 이어짐",
            symbol: "pano",
            slots: slots([
                ("풍경 1", "수평선을 기준선에 맞추고 왼쪽에서 오른쪽으로 천천히 돌리세요.", 4, g),
                ("풍경 2", "같은 속도·같은 방향으로.", 4, g),
                ("풍경 3", "같은 속도·같은 방향으로.", 4, g),
                ("풍경 4", "같은 속도로 돌리다 멈추기.", 4, g),
            ]),
            transition: .dissolve, beatsPerMinute: nil)
    }()
}
