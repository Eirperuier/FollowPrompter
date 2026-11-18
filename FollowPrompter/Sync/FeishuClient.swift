import Foundation
import Security

// 参考 larksuite/cli（lark-cli config init / auth login）的做法：
// 1. 设备码"应用注册"：给用户一个链接/二维码，确认后飞书自动创建一个专属应用并回传 App ID / Secret
// 2. 设备码"用户授权"：再给一个链接，用户确认后拿到 user_access_token，以用户身份读文档
//    （用户自己能看的文档都能读，不需要逐篇"添加文档应用"）

// MARK: - 品牌 / 账号存储

enum FeishuBrand: String, Codable {
    case feishu, lark
    var open: String { self == .lark ? "https://open.larksuite.com" : "https://open.feishu.cn" }
    var accounts: String { self == .lark ? "https://accounts.larksuite.com" : "https://accounts.feishu.cn" }
}

struct FeishuApp: Codable, Equatable {
    var appID: String
    var appSecret: String
    var brand: FeishuBrand
}

struct FeishuUserToken: Codable, Equatable {
    var access: String
    var accessExpires: Date
    var refresh: String
    var refreshExpires: Date
    /// 用户实际授予的权限（空格分隔）
    var scope: String? = nil
}

/// 应用凭证和用户令牌都存在钥匙串里
enum FeishuAccount {
    private static let service = "com.reiureprie.followprompter.feishu"

    static var app: FeishuApp? {
        get { load("app") }
        set { save(newValue, "app") }
    }

    static var token: FeishuUserToken? {
        get { load("userToken") }
        set { save(newValue, "userToken") }
    }

    /// 浏览 / 搜索文档需要的权限是否都已授予（老版本授权的令牌没有这些权限）
    static var canBrowse: Bool {
        guard let granted = grantedScopes else { return true }   // 未知时先放行，接口报缺权限再提示
        return FeishuAuth.browseScopes.allSatisfy(granted.contains)
    }

    /// 已授予的权限：优先用保存的记录，没有就从 JWT 令牌的 scope 声明里解析
    static var grantedScopes: Set<String>? {
        guard let t = token else { return nil }
        let raw = t.scope ?? jwtScope(t.access)
        return raw.map { Set($0.split(separator: " ").map(String.init)) }
    }

    static func jwtScope(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["scope"] as? String
    }

    static var isConnected: Bool {
        guard app != nil, let t = token else { return false }
        return t.accessExpires > Date() || (!t.refresh.isEmpty && t.refreshExpires > Date())
    }

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T?, _ key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - 错误

enum FeishuError: LocalizedError {
    case notConnected
    case authExpired
    case needsReauth
    case badURL
    case unsupported(String)
    case oauth(String)
    case api(code: Int, msg: String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "还没有连接飞书。"
        case .authExpired:
            return "飞书授权已过期，请在「飞书同步」里重新授权。"
        case .needsReauth:
            return "需要重新授权一次飞书，开启「浏览和搜索文档」的权限。"
        case .badURL:
            return "无法识别这个链接。请复制飞书文档或知识库页面的链接（形如 https://xxx.feishu.cn/docx/... 或 /wiki/...）。"
        case .unsupported(let s), .oauth(let s):
            return s
        case .http(let status):
            return "连接飞书失败（HTTP \(status)）。"
        case .api(let code, let msg):
            let m = msg.lowercased()
            var hint = ""
            if m.contains("forbidden") || m.contains("permission") || m.contains("no access") || m.contains("无权限") {
                hint = "\n请确认你的飞书账号能打开这篇文档；如果授权时取消了读取文档的权限，请重新授权。"
            }
            return "飞书返回错误 \(code)：\(msg)" + hint
        }
    }
}

// MARK: - 设备码授权流程

struct FeishuDeviceCode: Equatable {
    let deviceCode: String
    let userCode: String
    let url: URL
    let expiresAt: Date
    let interval: Int
}

enum FeishuAuth {
    /// 浏览 / 搜索：搜索文档、列出我的空间、列出知识库
    static let browseScopes = ["search:docs:read", "drive:drive.metadata:readonly", "wiki:space:retrieve"]
    /// 读取文档、读取知识库节点、浏览 / 搜索、刷新令牌
    static let scopes = (["docx:document:readonly", "wiki:node:retrieve"] + browseScopes + ["offline_access"])
        .joined(separator: " ")

    // 第 1 步：注册专属应用

    static func beginAppRegistration() async throws -> FeishuDeviceCode {
        let json = try await postForm(FeishuBrand.feishu.accounts + "/oauth/v1/app/registration", [
            "action": "begin",
            "archetype": "PersonalAgent",
            "auth_method": "client_secret",
            "request_user_info": "open_id tenant_brand",
        ])
        return try deviceCode(from: json, defaultExpiry: 600)
    }

    static func waitForApp(_ code: FeishuDeviceCode) async throws -> FeishuApp {
        var brand = FeishuBrand.feishu
        var switched = false
        var interval = code.interval
        var waitFirst = false
        while true {
            if waitFirst { try await Task.sleep(for: .seconds(interval)) }
            waitFirst = true
            guard Date() < code.expiresAt else { throw FeishuError.oauth("确认超时，请重新开始。") }
            guard let json = try? await postForm(brand.accounts + "/oauth/v1/app/registration",
                                                 ["action": "poll", "device_code": code.deviceCode]) else {
                interval = min(interval + 1, 60)   // 网络抖动（例如 App 在后台）继续等
                continue
            }
            // 用户属于 Lark 国际版租户时，切换到对应域名继续轮询（只切一次）
            if !switched, let info = json["user_info"] as? [String: Any],
               let tb = info["tenant_brand"] as? String, let b = FeishuBrand(rawValue: tb), b != brand {
                brand = b
                switched = true
                waitFirst = false
                continue
            }
            if let err = json["error"] as? String, !err.isEmpty {
                if try handlePollError(err, json, interval: &interval) { continue }
            }
            if let id = json["client_id"] as? String, let secret = json["client_secret"] as? String,
               !id.isEmpty, !secret.isEmpty {
                return FeishuApp(appID: id, appSecret: secret, brand: brand)
            }
        }
    }

    // 第 2 步：用户授权

    static func beginUserAuthorization(app: FeishuApp) async throws -> FeishuDeviceCode {
        let basic = Data("\(app.appID):\(app.appSecret)".utf8).base64EncodedString()
        let json = try await postForm(app.brand.accounts + "/oauth/v1/device_authorization",
                                      ["client_id": app.appID, "scope": scopes],
                                      headers: ["Authorization": "Basic \(basic)"])
        if let err = json["error"] as? String, !err.isEmpty {
            throw FeishuError.oauth("发起授权失败：\(json["error_description"] as? String ?? err)")
        }
        return try deviceCode(from: json, defaultExpiry: 240)
    }

    static func waitForUserToken(app: FeishuApp, code: FeishuDeviceCode) async throws -> FeishuUserToken {
        var interval = code.interval
        var waitFirst = false
        while true {
            if waitFirst { try await Task.sleep(for: .seconds(interval)) }
            waitFirst = true
            guard Date() < code.expiresAt else { throw FeishuError.oauth("授权超时，请重新开始。") }
            guard let json = try? await postForm(app.brand.accounts + "/oauth/v3/token", [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": code.deviceCode,
                "client_id": app.appID,
                "client_secret": app.appSecret,
            ]) else {
                interval = min(interval + 1, 60)
                continue
            }
            if let token = token(from: json, previous: nil) { return token }
            let err = json["error"] as? String ?? ""
            if try handlePollError(err.isEmpty ? "unknown" : err, json, interval: &interval) { continue }
        }
    }

    static func refresh(app: FeishuApp, token: FeishuUserToken) async throws -> FeishuUserToken {
        let json = try await postJSON(app.brand.accounts + "/oauth/v3/token", [
            "grant_type": "refresh_token",
            "refresh_token": token.refresh,
            "client_id": app.appID,
            "client_secret": app.appSecret,
        ])
        guard let t = Self.token(from: json, previous: token) else {
            throw FeishuError.authExpired
        }
        return t
    }

    // MARK: 工具

    /// 返回 true 表示继续轮询；终止性错误直接抛出
    private static func handlePollError(_ err: String, _ json: [String: Any], interval: inout Int) throws -> Bool {
        switch err {
        case "authorization_pending":
            return true
        case "slow_down":
            interval = min(interval + 5, 60)
            return true
        case "access_denied":
            throw FeishuError.oauth("你在飞书里取消了确认。")
        case "expired_token", "invalid_grant":
            throw FeishuError.oauth("链接已过期，请重新开始。")
        default:
            throw FeishuError.oauth(json["error_description"] as? String ?? err)
        }
    }

    private static func token(from json: [String: Any], previous: FeishuUserToken?) -> FeishuUserToken? {
        guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        let expires = (json["expires_in"] as? Double) ?? 7200
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refresh ?? ""
        let refreshExpires = (json["refresh_token_expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            ?? previous?.refreshExpires ?? Date().addingTimeInterval(604_800)
        let scope = (json["scope"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previous?.scope
        return FeishuUserToken(access: access, accessExpires: Date().addingTimeInterval(expires),
                               refresh: refresh, refreshExpires: refreshExpires, scope: scope)
    }

    private static func deviceCode(from json: [String: Any], defaultExpiry: Double) throws -> FeishuDeviceCode {
        if let err = json["error"] as? String, !err.isEmpty {
            throw FeishuError.oauth(json["error_description"] as? String ?? err)
        }
        guard let device = json["device_code"] as? String, !device.isEmpty else {
            throw FeishuError.oauth("飞书没有返回授权码，请稍后重试。")
        }
        let userCode = json["user_code"] as? String ?? ""
        let link = (json["verification_uri_complete"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(json["verification_uri"] as? String ?? "https://open.feishu.cn/page/launcher")?user_code=\(userCode)"
        guard let url = URL(string: link) else { throw FeishuError.oauth("飞书返回的链接无效。") }
        let expires = (json["expires_in"] as? Double) ?? (json["expire_in"] as? Double) ?? defaultExpiry
        let interval = max(1, (json["interval"] as? Int) ?? 5)
        return FeishuDeviceCode(deviceCode: device, userCode: userCode, url: url,
                                expiresAt: Date().addingTimeInterval(expires), interval: interval)
    }

    private static func postForm(_ urlString: String, _ fields: [String: String],
                                 headers: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = Data(body.utf8)
        return try await sendRaw(req)
    }

    private static func postJSON(_ urlString: String, _ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await sendRaw(req)
    }

    /// OAuth 接口在 4xx 时也返回 JSON 错误体，这里不按状态码判断
    static func sendRaw(_ req: URLRequest) async throws -> [String: Any] {
        var req = req
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FeishuError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return json
    }
}

// MARK: - 读取文档

actor FeishuClient {
    static let shared = FeishuClient()

    struct DocRef: Equatable {
        enum Kind: Equatable { case docx, wiki, legacyDoc }
        let apiBase: String
        let kind: Kind
        let token: String
    }

    struct Document {
        let title: String
        let content: String
    }

    private var refreshing: Task<FeishuUserToken, Error>?
    private var myLibraryCache: String?
    private static let invalidTokenCodes: Set<Int> = [99991663, 99991664, 99991661, 99991668, 99991677]

    /// 解析飞书 / Lark 文档链接
    static func parse(_ link: String) -> DocRef? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let apiBase = host.contains("larksuite") ? FeishuBrand.lark.open : FeishuBrand.feishu.open
        let parts = url.pathComponents.filter { $0 != "/" }
        for (i, p) in parts.enumerated() where i + 1 < parts.count {
            let token = parts[i + 1]
            guard token.count >= 8, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            switch p {
            case "docx": return DocRef(apiBase: apiBase, kind: .docx, token: token)
            case "wiki": return DocRef(apiBase: apiBase, kind: .wiki, token: token)
            case "docs": return DocRef(apiBase: apiBase, kind: .legacyDoc, token: token)
            default: continue
            }
        }
        return nil
    }

    func fetch(_ link: String) async throws -> Document {
        guard let ref = Self.parse(link) else { throw FeishuError.badURL }
        guard FeishuAccount.isConnected else { throw FeishuError.notConnected }
        return try await fetch(ref)
    }

    /// 带 user_access_token 的请求；令牌失效时刷新后重试一次
    private func request(_ path: String, method: String = "GET", query: [String: String] = [:],
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        do {
            return try await send(method, path, query: query, body: body, forceRefresh: false)
        } catch FeishuError.api(let code, _) where Self.invalidTokenCodes.contains(code) {
            return try await send(method, path, query: query, body: body, forceRefresh: true)
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String], body: [String: Any]?,
                      forceRefresh: Bool) async throws -> [String: Any] {
        let (token, brand) = try await accessToken(forceRefresh: forceRefresh)
        var comps = URLComponents(string: brand.open + path)!
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let json = try await FeishuAuth.sendRaw(req)
        let code = json["code"] as? Int ?? 0
        guard code == 0 else {
            let msg = json["msg"] as? String ?? ""
            if code == 99991679 || msg.lowercased().contains("scope") { throw FeishuError.needsReauth }
            throw FeishuError.api(code: code, msg: msg)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    /// 取可用的 user_access_token，快过期时用 refresh_token 续期（并发调用只刷新一次）
    private func accessToken(forceRefresh: Bool) async throws -> (token: String, brand: FeishuBrand) {
        guard let app = FeishuAccount.app, let current = FeishuAccount.token else { throw FeishuError.notConnected }
        if !forceRefresh, current.accessExpires > Date().addingTimeInterval(120) {
            return (current.access, app.brand)
        }
        guard !current.refresh.isEmpty, current.refreshExpires > Date() else { throw FeishuError.authExpired }
        let task: Task<FeishuUserToken, Error>
        if let r = refreshing {
            task = r
        } else {
            task = Task { try await FeishuAuth.refresh(app: app, token: current) }
            refreshing = task
        }
        defer { refreshing = nil }
        let fresh = try await task.value
        FeishuAccount.token = fresh
        return (fresh.access, app.brand)
    }

    private func fetch(_ ref: DocRef) async throws -> Document {
        var kind = ref.kind
        var docToken = ref.token
        var title = ""

        if kind == .wiki {
            let data = try await request("/open-apis/wiki/v2/spaces/get_node", query: ["token": docToken])
            guard let node = data["node"] as? [String: Any],
                  let objToken = node["obj_token"] as? String,
                  let objType = node["obj_type"] as? String else {
                throw FeishuError.unsupported("无法读取知识库节点信息。")
            }
            title = node["title"] as? String ?? ""
            docToken = objToken
            switch objType {
            case "docx": kind = .docx
            case "doc": kind = .legacyDoc
            default: throw FeishuError.unsupported("这个知识库页面是「\(objType)」类型，目前只支持同步文档。")
            }
        }

        let content: String
        switch kind {
        case .docx:
            if title.isEmpty,
               let meta = try? await request("/open-apis/docx/v1/documents/\(docToken)"),
               let doc = meta["document"] as? [String: Any] {
                title = doc["title"] as? String ?? ""
            }
            let data = try await request("/open-apis/docx/v1/documents/\(docToken)/raw_content", query: ["lang": "0"])
            content = data["content"] as? String ?? ""
        case .legacyDoc:
            let data = try await request("/open-apis/doc/v2/\(docToken)/raw_content")
            content = data["content"] as? String ?? ""
        case .wiki:
            content = ""
        }
        return Document(title: title, content: Self.clean(content, title: title))
    }

    /// 图片、附件在纯文本里只剩一个文件名（如 image.png），提词时没用
    static func isAttachmentPlaceholder(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), let dot = t.lastIndex(of: "."), dot > t.startIndex else { return false }
        let ext = t[t.index(after: dot)...].lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "mp4", "mov", "pdf", "zip"].contains(ext)
    }

    /// 去掉正文开头重复的标题行、图片占位、多余空行
    static func clean(_ raw: String, title: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if !title.isEmpty, let first = lines.first,
           first.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
            lines.removeFirst()
        }
        var out: [String] = []
        for line in lines where !isAttachmentPlaceholder(line) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, out.last.map({ $0.isEmpty }) ?? true { continue }
            out.append(isBlank ? "" : line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 浏览 / 搜索

    struct Item: Identifiable, Hashable {
        enum Kind: Hashable { case folder, wikiSpace, document, other }
        let id: String
        let title: String
        let kind: Kind
        /// 可导入的文档链接
        let link: String?
        /// 文件夹 token / 知识库 space_id / 有子页面的知识库节点 token
        let container: String?
        let spaceID: String?
        let typeLabel: String
        let modified: Date?
        /// 所有者（搜索结果才有；别人共享的文档据此区分）
        var owner: String? = nil
        /// 我上次打开的时间（搜索结果才有）
        var opened: Date? = nil
        var crossTenant = false

        var importable: Bool { link != nil }
        /// 去重用：文档 / 知识库节点 token
        var docToken: String? { link.flatMap { FeishuClient.parse($0)?.token } }
    }

    struct Page {
        var items: [Item]
        var next: String?
    }

    /// 我的空间（folder 为空即根目录）
    func listFolder(_ folder: String, page: String? = nil) async throws -> Page {
        var q = ["page_size": "50", "folder_token": folder, "order_by": "EditedTime", "direction": "DESC"]
        if let page { q["page_token"] = page }
        let data = try await request("/open-apis/drive/v1/files", query: q)
        let files = data["files"] as? [[String: Any]] ?? []
        let items = files.compactMap { f -> Item? in
            guard let token = f["token"] as? String else { return nil }
            var type = f["type"] as? String ?? ""
            var target = token
            if type == "shortcut", let info = f["shortcut_info"] as? [String: Any] {
                type = info["target_type"] as? String ?? type
                target = info["target_token"] as? String ?? token
            }
            let name = f["name"] as? String ?? "未命名"
            let modified = Self.date(f["modified_time"])
            switch type {
            case "folder":
                return Item(id: token, title: name, kind: .folder, link: nil, container: target, spaceID: nil,
                            typeLabel: "文件夹", modified: modified)
            case "docx", "doc":
                let link = "https://feishu.cn/\(type == "docx" ? "docx" : "docs")/\(target)"
                return Item(id: token, title: name, kind: .document, link: link, container: nil, spaceID: nil,
                            typeLabel: "文档", modified: modified)
            default:
                return Item(id: token, title: name, kind: .other, link: nil, container: nil, spaceID: nil,
                            typeLabel: Self.typeLabel(type), modified: modified)
            }
        }
        return Page(items: items, next: Self.nextToken(data))
    }

    /// "我的文档库"的 space_id（新版飞书在首页新建的文档默认存在这里）
    func myLibraryID() async -> String? {
        if let c = myLibraryCache { return c }
        guard let lib = try? await request("/open-apis/wiki/v2/spaces/my_library"),
              let space = lib["space"] as? [String: Any], let id = space["space_id"] as? String else { return nil }
        myLibraryCache = id
        return id
    }

    /// 最近打开：用户能看到的所有文档（自己的、别人共享的、知识库里的），按我打开的时间倒序。
    /// 开放平台没有"与我共享"列表接口，用空关键词搜索 + 按打开时间排序来实现，和飞书首页的"最近"一致。
    /// 第一页再并入「我的空间」和「我的文档库」，新建后还没打开过的文档也不会漏掉。
    private var myOwnerNames: Set<String> = []

    func listRecent(page: String? = nil) async throws -> Page {
        var result: Page
        var searchError: Error?
        do {
            result = try await searchDocs("", sortByOpenTime: true, page: page)
            if page != nil {
                result.items = result.items.map { item in
                    var item = item
                    if let o = item.owner, myOwnerNames.contains(o) { item.owner = nil }
                    return item
                }
            }
        } catch {
            if page != nil { throw error }
            result = Page(items: [], next: nil)
            searchError = error
        }
        guard page == nil else { return result }
        let own = (try? await listOwnRecent().items) ?? []
        if result.items.isEmpty && own.isEmpty, let searchError { throw searchError }
        let ownTokens = Set(own.compactMap(\.docToken))
        // 同时出现在自己空间里的文档，所有者就是"我"；只给别人的文档显示所有者
        let myNames = Set(result.items.filter { $0.docToken.map(ownTokens.contains) ?? false }.compactMap(\.owner))
        if !myNames.isEmpty {
            myOwnerNames.formUnion(myNames)
        }
        result.items = result.items.map { item in
            var item = item
            if let o = item.owner, myOwnerNames.contains(o) { item.owner = nil }
            return item
        }
        let seen = Set(result.items.compactMap(\.docToken))
        result.items += own.filter { $0.docToken.map { !seen.contains($0) } ?? true }
        result.items.sort { ($0.opened ?? $0.modified ?? .distantPast) > ($1.opened ?? $1.modified ?? .distantPast) }
        return result
    }

    /// 合并「我的空间」根目录和「我的文档库」第一层，按编辑时间倒序
    func listOwnRecent() async throws -> Page {
        var items: [Item] = []
        var firstError: Error?
        do { items += try await listFolder("").items } catch { firstError = error }
        if let lib = await myLibraryID() {
            do { items += try await listWikiNodes(space: lib, parent: nil).items } catch { firstError = firstError ?? error }
        }
        if items.isEmpty, let firstError { throw firstError }
        items.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return Page(items: items, next: nil)
    }

    /// 知识库列表（含"我的文档库"）
    func listWikiSpaces(page: String? = nil) async throws -> Page {
        var items: [Item] = []
        if page == nil, let id = await myLibraryID() {
            items.append(Item(id: "lib-\(id)", title: "我的文档库", kind: .wikiSpace, link: nil, container: nil,
                              spaceID: id, typeLabel: "知识库", modified: nil))
        }
        var q = ["page_size": "50"]
        if let page { q["page_token"] = page }
        let data = try await request("/open-apis/wiki/v2/spaces", query: q)
        for s in data["items"] as? [[String: Any]] ?? [] {
            guard let id = s["space_id"] as? String, !items.contains(where: { $0.spaceID == id }) else { continue }
            items.append(Item(id: id, title: s["name"] as? String ?? "知识库", kind: .wikiSpace, link: nil,
                              container: nil, spaceID: id, typeLabel: "知识库", modified: nil))
        }
        return Page(items: items, next: Self.nextToken(data))
    }

    /// 知识库某一层的页面（parent 为空即第一层）
    func listWikiNodes(space: String, parent: String?, page: String? = nil) async throws -> Page {
        var q = ["page_size": "50"]
        if let parent { q["parent_node_token"] = parent }
        if let page { q["page_token"] = page }
        let data = try await request("/open-apis/wiki/v2/spaces/\(space)/nodes", query: q)
        let items = (data["items"] as? [[String: Any]] ?? []).compactMap { n -> Item? in
            guard let token = n["node_token"] as? String else { return nil }
            let type = n["obj_type"] as? String ?? ""
            let isDoc = type == "docx" || type == "doc"
            let hasChild = n["has_child"] as? Bool ?? false
            return Item(id: token, title: n["title"] as? String ?? "未命名", kind: hasChild ? .folder : (isDoc ? .document : .other),
                        link: isDoc ? "https://feishu.cn/wiki/\(token)" : nil,
                        container: hasChild ? token : nil, spaceID: space,
                        typeLabel: isDoc ? "文档" : Self.typeLabel(type),
                        modified: Self.date(n["obj_edit_time"]))
        }
        return Page(items: items, next: Self.nextToken(data))
    }

    /// 搜索云文档和知识库（范围是当前用户能看到的所有文档，包括别人共享的）
    func search(_ query: String, page: String? = nil) async throws -> Page {
        try await searchDocs(query, sortByOpenTime: false, page: page)
    }

    private func searchDocs(_ query: String, sortByOpenTime: Bool, page: String?) async throws -> Page {
        var filter: [String: Any] = [:]
        if sortByOpenTime {
            filter["sort_type"] = "OPEN_TIME"
            filter["doc_types"] = ["DOCX", "DOC"]
        }
        var body: [String: Any] = ["query": query, "page_size": 20, "doc_filter": filter, "wiki_filter": filter]
        if let page { body["page_token"] = page }
        let data = try await request("/open-apis/search/v2/doc_wiki/search", method: "POST", body: body)
        let units = data["res_units"] as? [[String: Any]] ?? []
        let items = units.enumerated().compactMap { i, u -> Item? in
            let meta = u["result_meta"] as? [String: Any] ?? [:]
            let rawTitle = u["title_highlighted"] as? String ?? u["title"] as? String ?? "未命名"
            let title = rawTitle.replacingOccurrences(of: "<h>", with: "").replacingOccurrences(of: "</h>", with: "")
            let url = meta["url"] as? String ?? ""
            let docType = (meta["doc_types"] as? String ?? u["entity_type"] as? String ?? "").uppercased()
            let parsed = Self.parse(url)
            let isDoc = parsed != nil && (docType.isEmpty || docType.contains("DOC"))
            return Item(id: "\(i)-\(url)", title: title, kind: isDoc ? .document : .other,
                        link: isDoc ? url : nil, container: nil, spaceID: nil,
                        typeLabel: isDoc ? (parsed?.kind == .wiki ? "知识库文档" : "文档") : Self.typeLabel(docType.lowercased()),
                        modified: Self.date(meta["update_time"]),
                        owner: meta["owner_name"] as? String,
                        opened: Self.date(meta["last_open_time"]),
                        crossTenant: meta["is_cross_tenant"] as? Bool ?? false)
        }
        return Page(items: items, next: (data["has_more"] as? Bool ?? false) ? data["page_token"] as? String : nil)
    }

    private static func nextToken(_ data: [String: Any]) -> String? {
        guard data["has_more"] as? Bool ?? false else { return nil }
        return (data["next_page_token"] as? String) ?? (data["page_token"] as? String)
    }

    private static func date(_ raw: Any?) -> Date? {
        let v: Double?
        if let d = raw as? Double { v = d } else if let s = raw as? String { v = Double(s) } else { v = nil }
        guard let v, v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
    }

    private static func typeLabel(_ type: String) -> String {
        switch type {
        case "sheet": return "表格"
        case "bitable": return "多维表格"
        case "mindnote": return "思维笔记"
        case "slides": return "幻灯片"
        case "file": return "文件"
        default: return type.isEmpty ? "其他" : type
        }
    }
}

