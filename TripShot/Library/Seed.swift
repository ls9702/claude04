import Foundation
import SwiftData

/// 첫 실행 시 기본 규격·템플릿·프리셋을 넣는다. 이미 있으면 건너뜀.
enum Seed {
    static func runIfNeeded(context: ModelContext) {
        let formatCount = (try? context.fetchCount(FetchDescriptor<FormatPreset>())) ?? 0
        if formatCount == 0 { seedFormats(context) }
        let templateCount = (try? context.fetchCount(FetchDescriptor<ShotTemplate>())) ?? 0
        if templateCount == 0 { seedTemplates(context) }
        let presetCount = (try? context.fetchCount(FetchDescriptor<Preset>())) ?? 0
        if presetCount == 0 { seedPresets(context) }
        try? context.save()
    }

    private static func seedFormats(_ ctx: ModelContext) {
        // §4.2
        ctx.insert(FormatPreset(name: "세로 9:16", width: 1080, height: 1920, safeTop: 0.15, safeBottom: 0.20, safeRight: 0.15, isBuiltIn: true, sortOrder: 0))
        ctx.insert(FormatPreset(name: "세로 4:5", width: 1080, height: 1350, isBuiltIn: true, sortOrder: 1))
        ctx.insert(FormatPreset(name: "정사각 1:1", width: 1080, height: 1080, isBuiltIn: true, sortOrder: 2))
        ctx.insert(FormatPreset(name: "가로 16:9", width: 1920, height: 1080, isBuiltIn: true, sortOrder: 3))
    }

    private static func seedTemplates(_ ctx: ModelContext) {
        for (i, def) in TemplateLoader.builtIn().enumerated() {
            ctx.insert(ShotTemplate(name: def.name, shots: def.shots, isBuiltIn: true, sortOrder: i))
        }
    }

    private static func seedPresets(_ ctx: ModelContext) {
        // §3.2 기본 6종. 값은 P4에서 실제 보정 결과를 보며 조정.
        var sky = PresetParams(); sky.vibrance = 25; sky.contrast = 10; sky.clarity = 10; sky.sharpness = 25
        var golden = PresetParams(); golden.temperature = 30; golden.shadows = 15; golden.vibrance = 15; golden.vignette = 15
        var night = PresetParams(); night.lowLight = 70; night.shadows = 30; night.highlights = -20; night.sharpness = 10
        var food = PresetParams(); food.temperature = 10; food.vibrance = 30; food.clarity = 15; food.sharpness = 30
        var indoor = PresetParams(); indoor.exposure = 10; indoor.temperature = -10; indoor.shadows = 20
        var mono = PresetParams(); mono.lutName = "mono"; mono.contrast = 15; mono.clarity = 20
        let list: [(String, PresetParams)] = [("맑은 하늘", sky), ("골든아워", golden), ("야경", night), ("음식", food), ("실내", indoor), ("흑백", mono)]
        for (i, (name, p)) in list.enumerated() {
            ctx.insert(Preset(name: name, params: p, isBuiltIn: true, sortOrder: i))
        }
    }
}

enum TemplateLoader {
    /// Resources/Templates/default-templates.json
    static func builtIn() -> [TemplateDefinition] {
        guard let url = Bundle.main.url(forResource: "default-templates", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return fallback }
        return decode(data) ?? fallback
    }

    static func decode(_ data: Data) -> [TemplateDefinition]? {
        try? JSONDecoder().decode([TemplateDefinition].self, from: data)
    }

    static let fallback: [TemplateDefinition] = [
        TemplateDefinition(name: "자유", shots: []),
    ]
}
