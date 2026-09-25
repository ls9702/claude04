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
