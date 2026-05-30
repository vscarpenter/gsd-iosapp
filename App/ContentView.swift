import SwiftUI
import GSDModel
import GSDStore

struct ContentView: View {
    @Environment(TaskStore.self) private var store
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Capture a task… (try !! and #tag)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .padding()
                List(store.tasks) { task in
                    Text(task.title).strikethrough(task.completed)
                }
            }
            .navigationTitle("GSD")
        }
    }

    private func add() {
        let parsed = CaptureParser.parse(draft)
        guard !parsed.title.isEmpty else { return }
        draft = ""
        _Concurrency.Task { try? await store.add(parsed) }
    }
}
