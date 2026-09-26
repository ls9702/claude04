import Foundation
import SwiftData

// MARK: - 사진 보정 프리셋

/// §3.2 파이프라인 파라미터 묶음. 값은 0~100 (또는 -100~100).
struct PresetParams: Codable, Equatable {
    var auto: Bool = true
    var exposure: Double = 0        // -100...100
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var temperature: Double = 0     // -100(차가움)...100(따뜻함)
    var vibrance: Double = 0
    var sharpness: Double = 20      // 0...100
    var clarity: Double = 0
    var lowLight: Double = 0        // 0이면 Zero-DCE 비활성
    var lutName: String? = nil
    var lutIntensity: Double = 100
    var vignette: Double = 0
    var autoHorizon: Bool = false
    var portrait: PortraitParams = .init()
}

struct PortraitParams: Codable, Equatable {
    var enabled: Bool = true
    var skinSmooth: Double = 30
    var faceSlim: Double = 20
    var eyeEnlarge: Double = 0
    var teethWhiten: Double = 0
    /// 피부톤 업(R1-S8a): 피부 마스크 안에서만 밝게·따뜻하게. 0~100, 0이면 효과 없음.
    var skinBrighten: Double = 0
    /// 배경 흐림(R1-S8b): Vision 인물 분리로 사람 바깥만 흐린다. 0~100, 0이면 효과 없음. 저장·앨범에서만(라이브 미적용).
    var backgroundBlur: Double = 0
    /// 몸 슬림(전신 보정): Vision 몸 자세로 찾은 몸 중심선 쪽으로 가로를 좁힌다. 0~100, 0이면 효과 없음. 저장·앨범에서만.
    var bodySlim: Double = 0
    /// 다리 길게(전신 보정): 엉덩이 아래를 세로로 늘린다(발목이 잡힌 전신 사진에서만). 0~100, 0이면 효과 없음. 저장·앨범에서만.
    var legLengthen: Double = 0

    enum CodingKeys: String, CodingKey {
        case enabled, skinSmooth, faceSlim, eyeEnlarge, teethWhiten, skinBrighten, backgroundBlur, bodySlim, legLengthen
    }
}

extension PortraitParams {
    // 자동 합성 디코더는 기본값이 있어도 키가 반드시 있어야 한다. 필드를 추가해도(예: skinBrighten)
    // 이전에 저장한 프리셋·편집 JSON이 읽히도록 모든 키를 선택으로 읽고 없으면 기본값을 쓴다.
    // (extension에 두어 멤버와이즈 이니셜라이저를 유지한다. 인코딩은 합성 그대로.)
    init(from decoder: Decoder) throws {
        let defaults = PortraitParams()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        skinSmooth = try c.decodeIfPresent(Double.self, forKey: .skinSmooth) ?? defaults.skinSmooth
        faceSlim = try c.decodeIfPresent(Double.self, forKey: .faceSlim) ?? defaults.faceSlim
        eyeEnlarge = try c.decodeIfPresent(Double.self, forKey: .eyeEnlarge) ?? defaults.eyeEnlarge
        teethWhiten = try c.decodeIfPresent(Double.self, forKey: .teethWhiten) ?? defaults.teethWhiten
        skinBrighten = try c.decodeIfPresent(Double.self, forKey: .skinBrighten) ?? defaults.skinBrighten
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? defaults.backgroundBlur
        bodySlim = try c.decodeIfPresent(Double.self, forKey: .bodySlim) ?? defaults.bodySlim
        legLengthen = try c.decodeIfPresent(Double.self, forKey: .legLengthen) ?? defaults.legLengthen
    }
}

@Model
final class Preset {
    @Attribute(.unique) var id: UUID
    var name: String
    var isBuiltIn: Bool
    var sortOrder: Int
    var paramsData: Data
    var createdAt: Date

    init(name: String, params: PresetParams, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.paramsData = (try? JSONEncoder().encode(params)) ?? Data()
        self.createdAt = .now
    }

    var params: PresetParams {
        get { (try? JSONDecoder().decode(PresetParams.self, from: paramsData)) ?? PresetParams() }
        set { paramsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

// MARK: - 쇼츠 규격

@Model
final class FormatPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var width: Int
    var height: Int
    /// 세이프존 비율 (0~1). 오버레이가 덮는 영역.
    var safeTop: Double
    var safeBottom: Double
    var safeRight: Double
    var isBuiltIn: Bool
    var sortOrder: Int

    init(name: String, width: Int, height: Int, safeTop: Double = 0, safeBottom: Double = 0, safeRight: Double = 0, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.width = width
        self.height = height
        self.safeTop = safeTop
        self.safeBottom = safeBottom
        self.safeRight = safeRight
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    var aspectRatio: Double { Double(width) / Double(height) }
}

// MARK: - 템플릿

struct ShotSpec: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var hint: String = ""
    var targetSeconds: Double

    init(id: UUID = UUID(), name: String, hint: String = "", targetSeconds: Double) {
        self.id = id
        self.name = name
        self.hint = hint
        self.targetSeconds = targetSeconds
    }

    // 자동 합성 디코더는 기본값이 있어도 키가 반드시 있어야 하므로,
    // `id`·`hint`가 없는 번들 JSON(default-templates.json)도 읽히도록 직접 구현한다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        targetSeconds = try c.decode(Double.self, forKey: .targetSeconds)
    }
}

struct TemplateDefinition: Codable {
    var name: String
    var shots: [ShotSpec]
    var totalSeconds: Double { shots.reduce(0) { $0 + $1.targetSeconds } }
}

@Model
final class ShotTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var isBuiltIn: Bool
    var sortOrder: Int
    var shotsData: Data

    init(name: String, shots: [ShotSpec], isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.shotsData = (try? JSONEncoder().encode(shots)) ?? Data()
    }

    var shots: [ShotSpec] {
        get { (try? JSONDecoder().decode([ShotSpec].self, from: shotsData)) ?? [] }
        set { shotsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var totalSeconds: Double { shots.reduce(0) { $0 + $1.targetSeconds } }
}

// MARK: - 쇼츠 프로젝트

enum ProjectStatus: String, Codable { case shooting, assembling, exported }

@Model
final class ShortsProject {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var statusRaw: String
    var formatPresetID: UUID
    var templateID: UUID?
    var musicTrackID: UUID?
    var musicStartSeconds: Double
    var exportedAssetLocalID: String?
    @Relationship(deleteRule: .cascade, inverse: \Clip.project) var clips: [Clip]

    init(title: String, format: FormatPreset, template: ShotTemplate?) {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.statusRaw = ProjectStatus.shooting.rawValue
        self.formatPresetID = format.id
        self.templateID = template?.id
        self.musicTrackID = nil
        self.musicStartSeconds = 0
        self.exportedAssetLocalID = nil
        self.clips = []
    }

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .shooting }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class Clip {
    @Attribute(.unique) var id: UUID
    var shotIndex: Int
    var order: Int
    /// PHAsset.localIdentifier
    var assetLocalID: String
    var inSeconds: Double
    var outSeconds: Double
    var muted: Bool
    var project: ShortsProject?

    init(shotIndex: Int, order: Int, assetLocalID: String, inSeconds: Double, outSeconds: Double) {
        self.id = UUID()
        self.shotIndex = shotIndex
        self.order = order
        self.assetLocalID = assetLocalID
        self.inSeconds = inSeconds
        self.outSeconds = outSeconds
        self.muted = false
    }
}

// MARK: - 음원

@Model
final class MusicTrack {
    @Attribute(.unique) var id: UUID
    var title: String
    /// 앱 Documents/Music/ 아래 파일명
    var fileName: String
    var durationSeconds: Double
    var sourceURL: String?
    var addedAt: Date

    init(title: String, fileName: String, durationSeconds: Double, sourceURL: String?) {
        self.id = UUID()
        self.title = title
        self.fileName = fileName
        self.durationSeconds = durationSeconds
        self.sourceURL = sourceURL
        self.addedAt = .now
    }
}
