import SwiftUI
import GSDModel
import GSDStore

struct TaskEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var quadrant: Quadrant
    @State private var tags: [String]
    @State private var tagDraft = ""
    @State private var saveError: String?
    /// The task being edited (nil = creating a new one). Saving an edit mutates
    /// THIS value so non-edited (Phase-2) fields survive.
    private let original: Task?

    init(request: EditorRequest) {
        switch request {
        case .new(let q, let prefill):
            _title = State(initialValue: prefill?.title ?? "")
            _description = State(initialValue: prefill?.descriptionAdditions.joined(separator: "\n") ?? "")
            _quadrant = State(initialValue: prefill.map { Quadrant(urgent: $0.urgent, important: $0.important) } ?? q)
            _tags = State(initialValue: prefill?.tags ?? [])
            original = nil
        case .edit(let t):
            _title = State(initialValue: t.title)
            _description = State(initialValue: t.description)
            _quadrant = State(initialValue: t.quadrant)
            _tags = State(initialValue: t.tags)
            original = t
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Title"), text: $title)
                        .onChange(of: title) { _, _ in saveError = nil }
                }
                Section(String(localized: "Quadrant")) { quadrantPicker }
                Section(String(localized: "Tags")) { tagField }
                Section(String(localized: "Notes")) {
                    TextField(String(localized: "Description"), text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let saveError {
                    Section { Text(saveError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(original == nil ? String(localized: "New Task") : String(localized: "Edit Task"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var quadrantPicker: some View {
        LazyVGrid(columns: [GridItem(), GridItem()], spacing: 8) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button { quadrant = q } label: {
                    VStack(spacing: 4) {
                        Image(systemName: QuadrantStyle.symbol(q))
                        Text(q.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .background(quadrant == q ? QuadrantStyle.accent(q).opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(QuadrantStyle.accent(q), lineWidth: quadrant == q ? 2 : 0.5))
                }
                .tint(QuadrantStyle.accent(q))
                .accessibilityAddTraits(quadrant == q ? .isSelected : [])
            }
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: { Text("#\(tag)  ✕").font(.caption2) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            TextField(String(localized: "Add tag"), text: $tagDraft)
                .onSubmit(addTag)
                .onChange(of: tagDraft) { _, new in if new.hasSuffix(",") { addTag() } }
        }
    }

    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).lowercased()
        tagDraft = ""
        guard !t.isEmpty, FieldLimits.tagLengthRange.contains(t.count), !tags.contains(t), tags.count < FieldLimits.maxTags else { return }
        tags.append(t)
    }

    private func save() {
        var task: Task
        if let original {
            task = original
            task.title = title.trimmingCharacters(in: .whitespaces)
            task.description = description
            task.urgent = quadrant.isUrgent
            task.important = quadrant.isImportant
            task.tags = tags
        } else {
            let now = Date.now
            task = Task(id: IDGenerator.generate(size: IDGenerator.Size.task),
                        title: title.trimmingCharacters(in: .whitespaces),
                        description: description,
                        urgent: quadrant.isUrgent, important: quadrant.isImportant,
                        createdAt: now, updatedAt: now, tags: tags)
        }
        _Concurrency.Task { @MainActor in
            do {
                if original == nil { try await store.create(task) } else { try await store.save(task) }
                dismiss()
            } catch let error as ValidationError {
                saveError = error.message
            } catch {
                saveError = String(localized: "Couldn't save. Please try again.")
            }
        }
    }
}
