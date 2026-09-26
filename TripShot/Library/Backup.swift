// 프리셋·템플릿·규격·앱 설정의 JSON 백업(내보내기)과 복원(병합/교체). 사진은 다루지 않는다(사진은 사진 보관함에 있음).
import Foundation
import SwiftData

// MARK: - 문서

/// 백업 파일 한 개. 필드를 추가할 때는 `decodeIfPresent`로 읽어 이전 백업도 열리게 한다.
struct BackupDocument: Codable, Equatable {
    /// 형식 버전. 이 앱이 읽을 수 있는 최대값은 `Backup.currentVersion`.
    var version: Int = Backup.currentVersion
    var exportedAt: Date
    var presets: [PresetExport]
    var templates: [TemplateExport]
    var formats: [FormatExport]
    var settings: SettingsExport

    init(version: Int = Backup.currentVersion, exportedAt: Date, presets: [PresetExport],
         templates: [TemplateExport], formats: [FormatExport], settings: SettingsExport) {
        self.version = version
        self.exportedAt = exportedAt
        self.presets = presets
        self.templates = templates
        self.formats = formats
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case version, exportedAt, presets, templates, formats, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? .distantPast
        presets = try c.decodeIfPresent([PresetExport].self, forKey: .presets) ?? []
        templates = try c.decodeIfPresent([TemplateExport].self, forKey: .templates) ?? []
        formats = try c.decodeIfPresent([FormatExport].self, forKey: .formats) ?? []
        settings = try c.decodeIfPresent(SettingsExport.self, forKey: .settings) ?? SettingsExport()
    }
}

/// 병합 규칙이 쓰는 공통 성질(이름으로 같은 항목을 찾는다).
protocol BackupNamedItem {
    var name: String { get }
    var isBuiltIn: Bool { get }
}

struct PresetExport: Codable, Equatable, BackupNamedItem {
    var name: String
    var params: PresetParams
    var isBuiltIn: Bool
    var sortOrder: Int
}

struct TemplateExport: Codable, Equatable, BackupNamedItem {
    var name: String
    var shots: [ShotSpec]
    var isBuiltIn: Bool
    var sortOrder: Int
}

struct FormatExport: Codable, Equatable, BackupNamedItem {
    var name: String
    var width: Int
    var height: Int
    var safeTop: Double
    var safeBottom: Double
    var safeRight: Double
    var isBuiltIn: Bool
    var sortOrder: Int
}

struct SettingsExport: Codable, Equatable {
    var portraitModeEnabled: Bool = false
    /// `PortraitStrength.rawValue`.
    var portraitStrength: String = PortraitStrength.normal.rawValue
    var customPortrait: PortraitParams? = nil
    /// 선택 프리셋은 기기마다 UUID가 달라 이름으로 저장한다. nil이면 자동 보정.
    var selectedPresetName: String? = nil
    var preferredFrameRate: Double = 30

    init(portraitModeEnabled: Bool = false, portraitStrength: String = PortraitStrength.normal.rawValue,
         customPortrait: PortraitParams? = nil, selectedPresetName: String? = nil, preferredFrameRate: Double = 30) {
        self.portraitModeEnabled = portraitModeEnabled
        self.portraitStrength = portraitStrength
        self.customPortrait = customPortrait
        self.selectedPresetName = selectedPresetName
        self.preferredFrameRate = preferredFrameRate
    }

    enum CodingKeys: String, CodingKey {
        case portraitModeEnabled, portraitStrength, customPortrait, selectedPresetName, preferredFrameRate
    }

    init(from decoder: Decoder) throws {
        let d = SettingsExport()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portraitModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .portraitModeEnabled) ?? d.portraitModeEnabled
        portraitStrength = try c.decodeIfPresent(String.self, forKey: .portraitStrength) ?? d.portraitStrength
        customPortrait = try c.decodeIfPresent(PortraitParams.self, forKey: .customPortrait)
        selectedPresetName = try c.decodeIfPresent(String.self, forKey: .selectedPresetName)
        preferredFrameRate = try c.decodeIfPresent(Double.self, forKey: .preferredFrameRate) ?? d.preferredFrameRate
    }
}

enum BackupError: Error, LocalizedError, Equatable {
    /// 이 앱보다 새 형식 버전.
    case unsupportedVersion(Int)
    /// 파일을 읽지 못함(권한·iCloud 미다운로드 등).
    case unreadable
    /// JSON이 아니거나 형식이 다름.
    case invalidFormat

    var errorDescription: String? { UserMessage.text(for: self) }
}

/// 복원 방식.
enum RestoreMode: Equatable {
    /// 이름이 같으면 값 갱신, 없으면 추가. 기본 항목은 값만 갱신(이름·기본 표시·순서 유지). 백업에 없는 항목은 그대로.
    case merge
    /// 직접 만든 항목을 모두 지운 뒤 병합 규칙으로 추가(기본 항목은 지우지 않고 값만 갱신).
    case replace
}

/// 복원 결과(알림 문구용).
struct RestoreSummary: Equatable {
    var presets = 0
    var templates = 0
    var formats = 0

    var message: String {
        var text = "프리셋 \(presets)개, 템플릿 \(templates)개"
        if formats > 0 { text += ", 규격 \(formats)개" }
        return text + " 복원"
    }
}

/// 병합 계획(순수). `update`는 이미 있는 같은 이름 항목에 덮어쓸 값, `insert`는 새로 넣을 값.
struct MergePlan<Item: Equatable>: Equatable {
    var update: [Item] = []
    var insert: [Item] = []
}

/// 병합 계획의 기존 항목 요약(이름·기본 여부).
struct BackupExistingItem: Equatable {
    var name: String
    var isBuiltIn: Bool
}

// MARK: - 백업·복원

enum Backup {
    /// 이 앱이 쓰고 읽는 형식 버전.
    static let currentVersion = 1

    // MARK: 파일

    /// `TripShot-백업-yyyyMMdd-HHmm.json`.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "TripShot-백업-\(formatter.string(from: date)).json"
    }

    static func encode(_ document: BackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// 디코드 + 버전 확인. 형식이 다르면 `BackupError.invalidFormat`, 새 버전이면 `.unsupportedVersion`.
    static func decode(_ data: Data) throws -> BackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: BackupDocument
        do {
            document = try decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw BackupError.invalidFormat
        }
        guard document.version <= currentVersion else { throw BackupError.unsupportedVersion(document.version) }
        return document
    }

    /// 백업 파일을 임시 폴더에 쓰고 URL을 돌려준다(`ShareLink`로 내보낸다). 같은 이름이 있으면 덮어쓴다.
    static func writeTemporaryFile(_ document: BackupDocument) throws -> URL {
        let data = try encode(document)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(for: document.exportedAt))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 파일 가져오기(`.fileImporter`) URL 읽기. 보안 스코프 접근을 열고 닫는다.
    static func readImportedFile(at url: URL) throws -> BackupDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.unreadable
        }
        return try decode(data)
    }

    // MARK: 만들기

    /// 현재 앱 데이터로 백업 문서를 만든다.
    @MainActor
    static func make(context: ModelContext, services: AppServices, now: Date = .now) -> BackupDocument {
        let presets = (try? context.fetch(FetchDescriptor<Preset>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let templates = (try? context.fetch(FetchDescriptor<ShotTemplate>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let formats = (try? context.fetch(FetchDescriptor<FormatPreset>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let selectedName = services.selectedPresetID.flatMap { id in presets.first { $0.id == id }?.name }
        let settings = SettingsExport(portraitModeEnabled: services.portraitModeEnabled,
                                      portraitStrength: services.portraitStrength.rawValue,
                                      customPortrait: services.customPortrait,
                                      selectedPresetName: selectedName,
                                      preferredFrameRate: services.preferredFrameRate)
        return make(presets: presets.map { PresetExport($0) },
                    templates: templates.map { TemplateExport($0) },
                    formats: formats.map { FormatExport($0) },
                    settings: settings,
                    now: now)
    }

    /// 순수 버전(테스트용).
    static func make(presets: [PresetExport], templates: [TemplateExport], formats: [FormatExport],
                     settings: SettingsExport, now: Date = .now) -> BackupDocument {
        BackupDocument(exportedAt: now, presets: presets, templates: templates, formats: formats, settings: settings)
    }

    // MARK: 병합 규칙 (순수)

    /// 이름이 같은 기존 항목이 있으면 `update`, 없으면 `insert`.
    /// 백업 안에 같은 이름이 여러 개면 **처음 것만** 쓴다(이름이 복원의 열쇠이므로).
    static func mergePlan<Item: BackupNamedItem & Equatable>(existing: [BackupExistingItem],
                                                             incoming: [Item]) -> MergePlan<Item> {
        let existingNames = Set(existing.map(\.name))
        var seen: Set<String> = []
        var plan = MergePlan<Item>()
        for item in incoming {
            guard seen.insert(item.name).inserted else { continue }
            if existingNames.contains(item.name) {
                plan.update.append(item)
            } else {
                plan.insert.append(item)
            }
        }
        return plan
    }

    // MARK: 복원

    /// 백업을 앱에 적용한다. 기본 항목은 지우지 않고 값만 갱신한다. 설정(인물 모드·강도·프레임 레이트·선택 프리셋)도 되돌린다.
    /// - Returns: 복원(갱신 + 추가)한 항목 수.
    @MainActor
    @discardableResult
    static func restore(_ doc: BackupDocument, context: ModelContext, services: AppServices,
                        mode: RestoreMode) throws -> RestoreSummary {
        guard doc.version <= currentVersion else { throw BackupError.unsupportedVersion(doc.version) }
        var summary = RestoreSummary()

        // 프리셋
        var presets = try context.fetch(FetchDescriptor<Preset>(sortBy: [SortDescriptor(\.sortOrder)]))
        if mode == .replace {
            for p in presets where !p.isBuiltIn { context.delete(p) }
            presets.removeAll { !$0.isBuiltIn }
        }
        let presetPlan = mergePlan(existing: presets.map { BackupExistingItem(name: $0.name, isBuiltIn: $0.isBuiltIn) },
                                   incoming: doc.presets)
        for item in presetPlan.update {
            guard let target = presets.first(where: { $0.name == item.name }) else { continue }
            target.params = item.params
            if !target.isBuiltIn { target.sortOrder = item.sortOrder }
        }
        for item in presetPlan.insert {
            // 기본 표시는 이 기기의 시드만 갖는다. 백업의 "기본" 중 이 기기에 없는 이름은 직접 만든 항목으로 넣는다.
            context.insert(Preset(name: item.name, params: item.params, isBuiltIn: false, sortOrder: item.sortOrder))
        }
        summary.presets = presetPlan.update.count + presetPlan.insert.count

        // 템플릿
        var templates = try context.fetch(FetchDescriptor<ShotTemplate>(sortBy: [SortDescriptor(\.sortOrder)]))
        if mode == .replace {
            for t in templates where !t.isBuiltIn { context.delete(t) }
            templates.removeAll { !$0.isBuiltIn }
        }
        let templatePlan = mergePlan(existing: templates.map { BackupExistingItem(name: $0.name, isBuiltIn: $0.isBuiltIn) },
                                     incoming: doc.templates)
        for item in templatePlan.update {
            guard let target = templates.first(where: { $0.name == item.name }) else { continue }
            target.shots = item.shots
            if !target.isBuiltIn { target.sortOrder = item.sortOrder }
        }
        for item in templatePlan.insert {
            context.insert(ShotTemplate(name: item.name, shots: item.shots, isBuiltIn: false, sortOrder: item.sortOrder))
        }
        summary.templates = templatePlan.update.count + templatePlan.insert.count

        // 규격
        var formats = try context.fetch(FetchDescriptor<FormatPreset>(sortBy: [SortDescriptor(\.sortOrder)]))
        if mode == .replace {
            for f in formats where !f.isBuiltIn { context.delete(f) }
            formats.removeAll { !$0.isBuiltIn }
        }
        let formatPlan = mergePlan(existing: formats.map { BackupExistingItem(name: $0.name, isBuiltIn: $0.isBuiltIn) },
                                   incoming: doc.formats)
        for item in formatPlan.update {
            guard let target = formats.first(where: { $0.name == item.name }) else { continue }
            target.width = item.width
            target.height = item.height
            target.safeTop = item.safeTop
            target.safeBottom = item.safeBottom
            target.safeRight = item.safeRight
            if !target.isBuiltIn { target.sortOrder = item.sortOrder }
        }
        for item in formatPlan.insert {
            context.insert(FormatPreset(name: item.name, width: item.width, height: item.height,
                                        safeTop: item.safeTop, safeBottom: item.safeBottom, safeRight: item.safeRight,
                                        isBuiltIn: false, sortOrder: item.sortOrder))
        }
        summary.formats = formatPlan.update.count + formatPlan.insert.count

        try context.save()

        // 설정. 선택 프리셋은 이름으로 다시 찾는다(복원 후 목록 기준).
        let s = doc.settings
        services.portraitModeEnabled = s.portraitModeEnabled
        if let custom = s.customPortrait {
            services.portraitStrength = PortraitStrength(rawValue: s.portraitStrength) ?? .normal
            services.customPortrait = custom
        } else {
            services.selectPortraitStrength(PortraitStrength(rawValue: s.portraitStrength) ?? .normal)
        }
        services.preferredFrameRate = s.preferredFrameRate
        if let name = s.selectedPresetName {
            let all = (try? context.fetch(FetchDescriptor<Preset>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
            services.selectedPresetID = all.first { $0.name == name }?.id
        } else {
            services.selectedPresetID = nil
        }
        return summary
    }

    // MARK: 앱 데이터 초기화

    /// 직접 만든 프리셋·템플릿·규격을 지우고 기본 프리셋 값을 처음 값으로 되돌린 뒤 설정을 초기화한다.
    /// 사진 보관함은 건드리지 않는다. 쇼츠 프로젝트·음원(릴리즈 2)도 건드리지 않는다.
    @MainActor
    static func resetAppData(context: ModelContext, services: AppServices) throws {
        let presets = try context.fetch(FetchDescriptor<Preset>())
        let seeds = Dictionary(Seed.builtInPresets.map { ($0.name, $0.params) }, uniquingKeysWith: { a, _ in a })
        for p in presets {
            if p.isBuiltIn {
                if let original = seeds[p.name] { p.params = original }
            } else {
                context.delete(p)
            }
        }
        for t in try context.fetch(FetchDescriptor<ShotTemplate>()) where !t.isBuiltIn { context.delete(t) }
        for f in try context.fetch(FetchDescriptor<FormatPreset>()) where !f.isBuiltIn { context.delete(f) }
        try context.save()
        services.resetSettings()
    }
}

// MARK: - 모델 → 내보내기 값

extension PresetExport {
    init(_ preset: Preset) {
        self.init(name: preset.name, params: preset.params, isBuiltIn: preset.isBuiltIn, sortOrder: preset.sortOrder)
    }
}

extension TemplateExport {
    init(_ template: ShotTemplate) {
        self.init(name: template.name, shots: template.shots, isBuiltIn: template.isBuiltIn, sortOrder: template.sortOrder)
    }
}

extension FormatExport {
    init(_ format: FormatPreset) {
        self.init(name: format.name, width: format.width, height: format.height,
                  safeTop: format.safeTop, safeBottom: format.safeBottom, safeRight: format.safeRight,
                  isBuiltIn: format.isBuiltIn, sortOrder: format.sortOrder)
    }
}
