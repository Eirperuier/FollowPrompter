import SwiftUI
import Observation

struct Script: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var updatedAt = Date()
    /// 关联的飞书文档链接；有值时以飞书内容为准
    var feishuURL: String?
    var syncedAt: Date?

    var isLinked: Bool { !(feishuURL ?? "").isEmpty }
}

@MainActor @Observable
final class ScriptStore {
    private(set) var scripts: [Script] = []
    /// 正在同步的稿件
    private(set) var syncing: Set<UUID> = []
    /// 最近一次同步失败的原因
    private(set) var syncErrors: [UUID: String] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("scripts.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = decoded
        }
        if scripts.isEmpty { scripts = [Script.sample] }
    }

    @discardableResult
    func create(title: String = "未命名稿件", body: String = "") -> Script {
        let s = Script(title: title, body: body)
        scripts.insert(s, at: 0)
        scheduleSave()
        return s
    }

    func delete(at offsets: IndexSet) {
        scripts.remove(atOffsets: offsets)
        scheduleSave()
    }

    func script(_ id: UUID) -> Script? { scripts.first { $0.id == id } }

    /// 已关联到同一篇飞书文档的稿件（按文档 token 比较，忽略域名和参数）
    func script(linkedTo link: String) -> Script? {
        guard let ref = FeishuClient.parse(link) else { return nil }
        return scripts.first { s in
            guard let url = s.feishuURL, let r = FeishuClient.parse(url) else { return false }
            return r.token == ref.token
        }
    }

    func update(_ s: Script, touch: Bool = true) {
        guard let i = scripts.firstIndex(where: { $0.id == s.id }), scripts[i] != s else { return }
        var s = s
        if touch || scripts[i].body != s.body { s.updatedAt = Date() }
        scripts[i] = s
        scheduleSave()
    }

    func binding(for id: UUID) -> Binding<Script>? {
        guard let initial = script(id) else { return nil }
        return Binding(
            get: { [weak self] in self?.script(id) ?? initial },
            set: { [weak self] in self?.update($0) }
        )
    }

    // MARK: 飞书同步

    /// 从飞书链接新建一篇稿件
    func importFromFeishu(_ link: String) async throws -> Script {
        let doc = try await FeishuClient.shared.fetch(link)
        var s = Script(title: doc.title.isEmpty ? "飞书文档" : doc.title, body: doc.content)
        s.feishuURL = link.trimmingCharacters(in: .whitespacesAndNewlines)
        s.syncedAt = Date()
        scripts.insert(s, at: 0)
        scheduleSave()
        return s
    }

    /// 给已有稿件关联飞书文档并立即拉取
    func link(_ id: UUID, to url: String) async throws {
        let doc = try await FeishuClient.shared.fetch(url)   // 先确认能读到，再关联
        guard var s = script(id) else { return }
        s.feishuURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !doc.title.isEmpty { s.title = doc.title }
        s.body = doc.content
        s.syncedAt = Date()
        syncErrors[id] = nil
        update(s)
    }

    func unlink(_ id: UUID) {
        guard var s = script(id) else { return }
        s.feishuURL = nil
        s.syncedAt = nil
        syncErrors[id] = nil
        update(s)
    }

    /// 拉取飞书最新内容覆盖本地正文
    func sync(_ id: UUID) async throws {
        guard let s = script(id), let url = s.feishuURL, !url.isEmpty, !syncing.contains(id) else { return }
        syncing.insert(id)
        defer { syncing.remove(id) }
        do {
            let doc = try await FeishuClient.shared.fetch(url)
            guard var latest = script(id) else { return }
            if !doc.title.isEmpty { latest.title = doc.title }
            latest.body = doc.content
            latest.syncedAt = Date()
            syncErrors[id] = nil
            update(latest, touch: false)
        } catch {
            syncErrors[id] = error.localizedDescription
            throw error
        }
    }

    /// 同步所有关联了飞书的稿件（打开 App、下拉刷新时调用）
    func syncAllLinked() async {
        guard FeishuAccount.isConnected else { return }
        await withTaskGroup(of: Void.self) { group in
            for s in scripts where s.isLinked {
                group.addTask { @MainActor in try? await self.sync(s.id) }
            }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            let data = try JSONEncoder().encode(scripts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("保存失败：\(error)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}

extension Script {
    static let sample = Script(title: "试试跟读", body: """
    大家好，欢迎使用随声提词。

    点右上角的开始按钮，倒数三秒之后，对着 iPad 把这段文字读出来。你会发现，文字会跟着你的语速往上走：你读得快，它就走得快；你读得慢，它就走得慢；你停下来喝口水，它也会停下来等你。

    读过的文字会变暗，橙色的阅读线标出你现在读到的位置。就算你临时加了几句话，或者跳过了一段，它也会自己找回来。

    如果想从某一句重新开始，双击那一句就可以；也可以直接用手指拖动文字。单击屏幕可以隐藏或显示控制栏。

    配合提词器玻璃使用时，在文字设置里打开水平镜像。祝你录制顺利！
    """)
}
