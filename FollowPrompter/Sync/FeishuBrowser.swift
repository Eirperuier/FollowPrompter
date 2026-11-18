import SwiftUI

/// 直接浏览 / 搜索飞书文档，点一下导入
struct FeishuDocPicker: View {
    enum Purpose { case importNew, link(UUID) }

    let purpose: Purpose
    var onDone: (UUID) -> Void

    @Environment(ScriptStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var importing: String?
    @State private var importError: String?
    @State private var showConnect = false
    @State private var showLinkSheet = false
    @State private var connected = FeishuAccount.isConnected
    @State private var canBrowse = FeishuAccount.canBrowse
    @State private var path: [FeishuItemList.Source] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !connected {
                    connectPrompt(title: "先连接飞书", detail: "扫码确认一次，就能在这里浏览和搜索你的飞书文档。")
                } else if !canBrowse {
                    connectPrompt(title: "需要重新授权一次", detail: "浏览和搜索文档需要额外的只读权限。重新扫码确认一次即可，已同步的稿件不受影响。")
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    rootList
                } else {
                    FeishuItemList(source: .search(query.trimmingCharacters(in: .whitespaces)), onPick: pick)
                        .id(query)
                }
            }
            .navigationTitle("从飞书选择")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FeishuItemList.Source.self) { source in
                FeishuItemList(source: source, onPick: pick)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索飞书文档和知识库")
            .disabled(importing != nil)
            .overlay {
                if importing != nil {
                    ProgressView("正在导入…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showLinkSheet = true
                    } label: {
                        Label("粘贴链接", systemImage: "link")
                    }
                }
            }
            .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("好") {}
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $showConnect, onDismiss: refreshState) { FeishuConnectView() }
            #if DEBUG
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-feishuQuery"), i + 1 < args.count { query = args[i + 1] }
                if args.contains("-feishuWiki") { path = [.wikiSpaces] }
                if args.contains("-feishuMyLib") {
                    Task {
                        if let lib = try? await FeishuClient.shared.listWikiSpaces().items.first(where: { $0.id.hasPrefix("lib-") }),
                           let id = lib.spaceID {
                            path = [.wikiSpaces, .wikiNodes(space: id, parent: nil, title: lib.title)]
                        }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showLinkSheet) {
                FeishuLinkSheet(purpose: linkPurpose) { id in
                    onDone(id)
                    dismiss()
                }
            }
        }
    }

    private var rootList: some View {
        List {
            Section {
                FeishuItemRows(source: .recent, onPick: pick)
            } header: {
                Text("最近编辑")
            } footer: {
                Text("包含「我的空间」和「我的文档库」。找不到的话可以在上方搜索，或按目录浏览。")
            }
            Section("按目录浏览") {
                NavigationLink(value: FeishuItemList.Source.folder(token: "", title: "我的空间")) {
                    Label("我的空间", systemImage: "folder")
                }
                NavigationLink(value: FeishuItemList.Source.wikiSpaces) {
                    Label("知识库（含我的文档库）", systemImage: "books.vertical")
                }
            }
        }
    }

    private func connectPrompt(title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { FeishuLogo(size: 56) }
        } description: {
            Text(detail)
        } actions: {
            Button("连接飞书") { showConnect = true }
                .buttonStyle(.borderedProminent)
                .tint(.feishuBlue)
        }
    }

    private var linkPurpose: FeishuLinkSheet.Purpose {
        switch purpose {
        case .importNew: .importNew
        case .link(let id): .link(id)
        }
    }

    private func refreshState() {
        connected = FeishuAccount.isConnected
        canBrowse = FeishuAccount.canBrowse
    }

    private func pick(_ item: FeishuClient.Item) {
        guard let link = item.link else { return }
        // 已经导入过的直接打开，不重复导入
        if case .importNew = purpose, let existing = store.script(linkedTo: link) {
            onDone(existing.id)
            dismiss()
            return
        }
        importing = item.id
        Task {
            do {
                switch purpose {
                case .importNew:
                    let s = try await store.importFromFeishu(link)
                    onDone(s.id)
                case .link(let id):
                    try await store.link(id, to: link)
                    onDone(id)
                }
                importing = nil
                dismiss()
            } catch {
                importing = nil
                if case FeishuError.needsReauth = error { canBrowse = false }
                importError = error.localizedDescription
            }
        }
    }
}

/// 一个可分页加载的飞书列表（文件夹 / 知识库 / 知识库节点 / 搜索结果）
struct FeishuItemList: View {
    enum Source: Hashable {
        case folder(token: String, title: String)
        case recent
        case wikiSpaces
        case wikiNodes(space: String, parent: String?, title: String)
        case search(String)

        var title: String {
            switch self {
            case .folder(_, let t), .wikiNodes(_, _, let t): t
            case .recent: "最近编辑"
            case .wikiSpaces: "知识库"
            case .search: "搜索结果"
            }
        }
    }

    let source: Source
    var onPick: (FeishuClient.Item) -> Void

    var body: some View {
        List {
            FeishuItemRows(source: source, onPick: onPick)
        }
        .navigationTitle(source.title)
    }
}

/// 列表内容（可嵌入其他 List 的 Section）
struct FeishuItemRows: View {
    let source: FeishuItemList.Source
    var onPick: (FeishuClient.Item) -> Void

    @Environment(ScriptStore.self) private var store
    @State private var items: [FeishuClient.Item] = []
    @State private var next: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Group {
            ForEach(items) { item in
                row(item)
            }
            if loading || (!loaded && error == nil) {
                // 首次加载前也要有一行内容，否则空 Group 不会出现，.task 不会触发
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button("重试") { Task { await load(reset: items.isEmpty) } }.font(.footnote)
                }
            } else if loaded && items.isEmpty {
                Text(emptyText).font(.footnote).foregroundStyle(.secondary)
            } else if next != nil {
                Button("加载更多") { Task { await load(reset: false) } }
            }
        }
        .task(id: source) {
            if !loaded { await load(reset: true) }
        }
    }

    @ViewBuilder
    private func row(_ item: FeishuClient.Item) -> some View {
        switch item.kind {
        case .folder where item.importable:
            // 有子页面的知识库文档：点标题导入，点箭头进入子页面
            HStack {
                Button { onPick(item) } label: { label(item, icon: "doc.text") }
                    .buttonStyle(.plain)
                Spacer()
                NavigationLink(value: childSource(item)) { EmptyView() }
                    .frame(width: 30)
            }
        case .folder, .wikiSpace:
            NavigationLink(value: childSource(item)) {
                label(item, icon: item.kind == .wikiSpace ? "books.vertical" : "folder")
            }
        case .document:
            Button { onPick(item) } label: { label(item, icon: "doc.text") }
                .buttonStyle(.plain)
        case .other:
            label(item, icon: "doc")
                .opacity(0.4)
        }
    }

    private func label(_ item: FeishuClient.Item, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(item.kind == .other ? Color.secondary : Color.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.kind == .other ? "\(item.typeLabel) · 暂不支持" : item.typeLabel)
                    if let d = item.modified {
                        Text("· \(d.formatted(.relative(presentation: .named)))编辑")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let link = item.link, store.script(linkedTo: link) != nil {
                Text("已导入")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.2), in: Capsule())
            }
        }
        .contentShape(Rectangle())
    }

    private func childSource(_ item: FeishuClient.Item) -> FeishuItemList.Source {
        switch item.kind {
        case .wikiSpace:
            return .wikiNodes(space: item.spaceID ?? "", parent: nil, title: item.title)
        default:
            if let space = item.spaceID {
                return .wikiNodes(space: space, parent: item.container, title: item.title)
            }
            return .folder(token: item.container ?? "", title: item.title)
        }
    }

    private var emptyText: String {
        if case .search = source { return "没有找到相关文档。" }
        return "这里是空的。"
    }

    private func load(reset: Bool) async {
        if case .search = source, reset {
            try? await Task.sleep(for: .milliseconds(350))   // 输入防抖
            if Task.isCancelled { return }
        }
        loading = true
        error = nil
        defer { loading = false; loaded = true }
        do {
            let page = try await fetch(reset ? nil : next)
            if reset { items = page.items } else { items += page.items }
            next = page.next
            #if DEBUG
            if reset, source == .recent,
               ProcessInfo.processInfo.arguments.contains("-feishuImportFirst"),
               let first = items.first(where: { $0.kind == .document }) {
                onPick(first)
            }
            #endif
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }

    private func fetch(_ page: String?) async throws -> FeishuClient.Page {
        let client = FeishuClient.shared
        switch source {
        case .folder(let token, _): return try await client.listFolder(token, page: page)
        case .recent: return try await client.listRecent()
        case .wikiSpaces: return try await client.listWikiSpaces(page: page)
        case .wikiNodes(let space, let parent, _): return try await client.listWikiNodes(space: space, parent: parent, page: page)
        case .search(let q): return try await client.search(q, page: page)
        }
    }
}
