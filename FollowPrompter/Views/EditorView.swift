import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Binding var script: Script
    var onStart: () -> Void

    @Environment(ScriptStore.self) private var store
    @State private var importing = false
    @State private var importError: String?
    @State private var linkingFeishu = false
    @State private var preparing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("标题", text: $script.title)
                .font(.largeTitle.bold())
                .padding(.horizontal, 24)
                .padding(.top, 16)

            Text(stats)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 4)

            if script.isLinked { feishuBar.padding(.horizontal, 24).padding(.top, 10) }

            Divider().padding(.top, 12)

            TextEditor(text: $script.body)
                .font(.system(size: 20))
                .lineSpacing(6)
                .padding(.horizontal, 18)
                .overlay(alignment: .topLeading) {
                    if script.body.isEmpty {
                        Text("在这里粘贴或输入你的演讲稿……")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 23)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                if script.isLinked {
                    Button(role: .destructive) {
                        store.unlink(script.id)
                    } label: {
                        Label("取消关联飞书", systemImage: "link.badge.plus")
                    }
                } else {
                    Button {
                        linkingFeishu = true
                    } label: {
                        Label { Text("关联飞书文档…") } icon: { Image(uiImage: .feishuMenuIcon) }
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("导入文本文件", systemImage: "doc.badge.plus")
                }
                Button {
                    if let s = UIPasteboard.general.string {
                        script.body += (script.body.isEmpty ? "" : "\n\n") + s
                    }
                } label: {
                    Label("粘贴到末尾", systemImage: "doc.on.clipboard")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: start) {
                    if preparing {
                        HStack(spacing: 6) { ProgressView(); Text("同步中") }
                    } else {
                        Label("开始提词", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(preparing || (script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !script.isLinked))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .utf8PlainText]) { result in
            switch result {
            case .success(let url):
                do {
                    let text = try Self.readText(url)
                    script.body = text
                    if script.title.isEmpty || script.title == "未命名稿件" {
                        script.title = url.deletingPathExtension().lastPathComponent
                    }
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $linkingFeishu) {
            FeishuDocPicker(purpose: .link(script.id)) { _ in }
        }
        .task(id: script.id) {
            // 打开稿件时拉取飞书最新内容
            if script.isLinked { try? await store.sync(script.id) }
        }
        .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好") {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var feishuBar: some View {
        let syncing = store.syncing.contains(script.id)
        let error = store.syncErrors[script.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                FeishuLogo(size: 18)
                if syncing {
                    Text("正在从飞书同步…")
                    ProgressView().controlSize(.small)
                } else if let date = script.syncedAt {
                    Text("已关联飞书 · 上次同步：\(date.formatted(.relative(presentation: .named)))")
                } else {
                    Text("已关联飞书")
                }
                Spacer()
                Button("立即同步") {
                    Task { try? await store.sync(script.id) }
                }
                .disabled(syncing)
                if let url = script.feishuURL.flatMap(URL.init(string:)) {
                    Link("在飞书打开", destination: url)
                }
            }
            .font(.footnote)
            if let error {
                Text("同步失败：\(error)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("以飞书上的内容为准，在这里的修改会在下次同步时被覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.feishuBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 开始提词前先拉一次最新稿（最多等 6 秒；失败就用本地缓存的版本）
    private func start() {
        guard script.isLinked else { onStart(); return }
        preparing = true
        let id = script.id
        Task {
            let sync = Task { try await store.sync(id) }
            let timeout = Task { try await Task.sleep(for: .seconds(6)); sync.cancel() }
            _ = try? await sync.value
            timeout.cancel()
            preparing = false
            onStart()
        }
    }

    private var stats: String {
        let (count, cjk) = Tokenizer.countUnits(script.body)
        let isCJK = cjk * 2 >= count
        let perMinute = isCJK ? 240.0 : 150.0
        let seconds = Int((Double(count) / perMinute * 60).rounded())
        return "\(count) \(isCJK ? "字" : "词") · 正常语速约 \(seconds / 60) 分 \(seconds % 60) 秒"
    }

    /// 读取 UTF-8 / UTF-16 / GB18030 编码的文本
    private static func readText(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        throw NSError(domain: "FollowPrompter", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法识别文件编码"])
    }
}
