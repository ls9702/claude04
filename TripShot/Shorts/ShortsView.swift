// 쇼츠 탭(R3-S2): 프로젝트 목록(여러 개) · 새 프로젝트(제목 + 템플릿 10개 중 선택) → 프로젝트 화면에서 칸을 채운다.
import SwiftData
import SwiftUI

struct ShortsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ShortsProject.createdAt, order: .reverse) private var projects: [ShortsProject]
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("쇼츠 프로젝트가 없습니다", systemImage: "film.stack")
                    } description: {
                        Text("+ 를 눌러 템플릿을 고르고, 여행하면서 칸을 하나씩 채워 보세요.")
                    } actions: {
                        Button("새 쇼츠 만들기") { showNew = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(projects) { project in
                            NavigationLink(value: project.id) { ProjectRow(project: project) }
                        }
                        .onDelete { idx in idx.map { projects[$0] }.forEach(context.delete) }
                    }
                }
            }
            .navigationTitle("쇼츠")
            .navigationDestination(for: UUID.self) { id in
                if let project = projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                }
            }
            .toolbar { Button { showNew = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showNew) { NewProjectSheet() }
        }
    }
}

private struct ProjectRow: View {
    let project: ShortsProject

    var body: some View {
        let template = ShortsTemplateLibrary.template(for: project.templateKey)
        HStack(spacing: 12) {
            Image(systemName: template?.symbol ?? "film")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).font(.headline)
                if let template {
                    let filled = project.filledSlotCount(of: template)
                    Text("\(template.name) · \(filled)/\(template.slots.count)칸")
                        .font(.footnote).foregroundStyle(.secondary)
                    ProgressView(value: Double(filled), total: Double(max(template.slots.count, 1)))
                } else {
                    Text("클립 \(project.clips.count)개").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 새 쇼츠: 제목 + 템플릿 선택.
struct NewProjectSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FormatPreset.sortOrder) private var formats: [FormatPreset]
    @State private var title = ""
    @State private var templateKey: String = ShortsTemplateLibrary.all.first?.id ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") {
                    TextField("예: 오사카 여행", text: $title)
                }
                Section("템플릿") {
                    ForEach(ShortsTemplateLibrary.all) { t in
                        Button { templateKey = t.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: t.symbol).font(.title3).frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.body.weight(.semibold))
                                    Text(t.summary).font(.caption).foregroundStyle(.secondary)
                                    Text("\(t.slots.count)칸 · \(Int(t.totalSeconds.rounded()))초 · 전환 \(t.transition.title)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if templateKey == t.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("새 쇼츠")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") {
                        guard let format = formats.first else { return }
                        let name = title.trimmingCharacters(in: .whitespaces)
                        context.insert(ShortsProject(title: name.isEmpty ? Date.now.formatted(date: .abbreviated, time: .omitted) : name,
                                                     format: format, template: nil, templateKey: templateKey))
                        dismiss()
                    }
                    .disabled(formats.isEmpty)
                }
            }
        }
    }
}
