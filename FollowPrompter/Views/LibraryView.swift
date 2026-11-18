import SwiftUI

struct LibraryView: View {
    @Environment(ScriptStore.self) private var store
    @State private var selection: UUID?
    @State private var prompting: Script?
    @State private var importingFeishu = false
    @State private var showFeishuSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.scripts) { script in
                    NavigationLink(value: script.id) {
                        ScriptRow(script: script)
                    }
                }
                .onDelete { offsets in
                    if let sel = selection, offsets.contains(where: { store.scripts[$0].id == sel }) {
                        selection = nil
                    }
                    store.delete(at: offsets)
                }
            }
            .navigationTitle("随声提词")
            .refreshable { await store.syncAllLinked() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            selection = store.create().id
                        } label: {
                            Label("新建空白稿件", systemImage: "square.and.pencil")
                        }
                        Button {
                            importingFeishu = true
                        } label: {
                            Label { Text("从飞书选择文档…") } icon: { Image(uiImage: .feishuMenuIcon) }
                        }
                    } label: {
                        Label("新建稿件", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showFeishuSettings = true
                    } label: {
                        Label { Text("飞书同步设置") } icon: { Image(uiImage: .feishuMenuIcon) }
                    }
                }
            }
            .sheet(isPresented: $importingFeishu) {
                FeishuDocPicker(purpose: .importNew) { selection = $0 }
            }
            .sheet(isPresented: $showFeishuSettings) { FeishuConnectView() }
        } detail: {
            if let id = selection, let binding = store.binding(for: id) {
                EditorView(script: binding) { prompting = store.script(id) }
                    .id(id)
            } else {
                ContentUnavailableView("选择或新建一篇稿件", systemImage: "text.alignleft",
                                       description: Text("在左侧列表中选择稿件，然后点「开始提词」。"))
            }
        }
        .onAppear {
            if selection == nil { selection = store.scripts.first?.id }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-openFirst") { prompting = store.scripts.first }
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-openIndex"),
               let n = Int(ProcessInfo.processInfo.arguments[i + 1]), n < store.scripts.count {
                prompting = store.scripts[n]
            }
            if ProcessInfo.processInfo.arguments.contains("-feishuSettings") { showFeishuSettings = true }
            if ProcessInfo.processInfo.arguments.contains("-feishuPicker") { importingFeishu = true }
            #endif
        }
        .fullScreenCover(item: $prompting) { script in
            PrompterView(script: script)
        }
    }
}

private struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(script.title.isEmpty ? "未命名稿件" : script.title)
                    .font(.headline)
                if script.isLinked {
                    FeishuLogo(size: 14)
                        .accessibilityLabel("已关联飞书")
                }
            }
                .lineLimit(1)
            Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(script.updatedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        let s = script.body.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return s.isEmpty ? "（空）" : String(s.prefix(80))
    }
}
