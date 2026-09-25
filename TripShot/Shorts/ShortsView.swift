import SwiftData
import SwiftUI

/// R1-S0: 프로젝트 목록·생성. 클립·조립은 릴리즈 2(R2 단계).
struct ShortsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ShortsProject.createdAt, order: .reverse) private var projects: [ShortsProject]
    @Query(sort: \FormatPreset.sortOrder) private var formats: [FormatPreset]
    @Query(sort: \ShotTemplate.sortOrder) private var templates: [ShotTemplate]
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView("쇼츠 프로젝트가 없습니다", systemImage: "film.stack", description: Text("+ 를 눌러 규격과 템플릿을 고르고 촬영을 시작하세요."))
                } else {
                    List {
                        ForEach(projects) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.title).font(.headline)
                                Text("\(formatName(p.formatPresetID)) · \(templateName(p.templateID)) · 클립 \(p.clips.count)개")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idx in idx.map { projects[$0] }.forEach(context.delete) }
                    }
                }
            }
            .navigationTitle("쇼츠")
            .toolbar { Button { showNew = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showNew) { NewProjectSheet(formats: formats, templates: templates) }
        }
    }

    private func formatName(_ id: UUID) -> String { formats.first { $0.id == id }?.name ?? "규격" }
    private func templateName(_ id: UUID?) -> String { templates.first { $0.id == id }?.name ?? "자유" }
}

struct NewProjectSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let formats: [FormatPreset]
    let templates: [ShotTemplate]
    @State private var title = ""
    @State private var formatID: UUID?
    @State private var templateID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                TextField("제목 (예: 교토 첫날)", text: $title)
                Picker("규격", selection: $formatID) {
                    ForEach(formats) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("템플릿", selection: $templateID) {
                    ForEach(templates) { t in
                        Text(t.shots.isEmpty ? t.name : "\(t.name) · \(Int(t.totalSeconds))초").tag(Optional(t.id))
                    }
                }
            }
            .navigationTitle("새 쇼츠")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") {
                        guard let f = formats.first(where: { $0.id == formatID }) else { return }
                        let t = templates.first { $0.id == templateID }
                        let name = title.trimmingCharacters(in: .whitespaces)
                        context.insert(ShortsProject(title: name.isEmpty ? Date.now.formatted(date: .abbreviated, time: .omitted) : name, format: f, template: t))
                        dismiss()
                    }
                    .disabled(formatID == nil)
                }
            }
            .onAppear {
                formatID = formatID ?? formats.first?.id
                templateID = templateID ?? templates.first?.id
            }
        }
    }
}
