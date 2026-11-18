import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - 连接流程状态

@MainActor @Observable
final class FeishuConnector {
    enum Phase: Equatable {
        case idle
        case preparing(step: Int)
        case waiting(step: Int, code: FeishuDeviceCode)
        case connected
        case failed(String)
    }

    private(set) var phase: Phase
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        phase = FeishuAccount.isConnected ? .connected : .idle
    }

    /// 没有应用就先自动创建，再做用户授权
    func connect() {
        task?.cancel()
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = FeishuAccount.isConnected ? .connected : .idle
    }

    func disconnect() {
        cancel()
        FeishuAccount.token = nil
        phase = .idle
    }

    /// 改用自己在开发者后台创建的应用
    func useCustomApp(id: String, secret: String, lark: Bool) {
        FeishuAccount.app = FeishuApp(appID: id.trimmingCharacters(in: .whitespaces),
                                      appSecret: secret.trimmingCharacters(in: .whitespaces),
                                      brand: lark ? .lark : .feishu)
        FeishuAccount.token = nil
        connect()
    }

    func forgetApp() {
        cancel()
        FeishuAccount.app = nil
        FeishuAccount.token = nil
        phase = .idle
    }

    private func run() async {
        do {
            var app = FeishuAccount.app
            if app == nil {
                phase = .preparing(step: 1)
                let code = try await FeishuAuth.beginAppRegistration()
                phase = .waiting(step: 1, code: code)
                let created = try await FeishuAuth.waitForApp(code)
                FeishuAccount.app = created
                app = created
            }
            guard let app else { return }
            phase = .preparing(step: 2)
            let code = try await FeishuAuth.beginUserAuthorization(app: app)
            phase = .waiting(step: 2, code: code)
            FeishuAccount.token = try await FeishuAuth.waitForUserToken(app: app, code: code)
            phase = .connected
        } catch is CancellationError {
            // 用户取消
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 连接页面

struct FeishuConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScriptStore.self) private var store
    @State private var connector = FeishuConnector()
    @State private var customID = ""
    @State private var customSecret = ""
    @State private var customLark = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    content
                } header: {
                    Text("连接飞书")
                }

                Section {
                    Text("连接后，每次打开 App、打开稿件、开始提词前都会自动拉取飞书上的最新版本；在稿件列表下拉也可以手动刷新。只要你的飞书账号能打开的文档都能同步。飞书上是唯一来源，iPad 上的本地修改会在下次同步时被覆盖。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("同步规则")
                }

                Section {
                    DisclosureGroup("使用自己在开发者后台创建的应用") {
                        TextField("App ID（cli_ 开头）", text: $customID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("App Secret", text: $customSecret)
                        Toggle("Lark 国际版", isOn: $customLark)
                        Button("用这个应用授权") {
                            connector.useCustomApp(id: customID, secret: customSecret, lark: customLark)
                        }
                        .disabled(customID.isEmpty || customSecret.isEmpty)
                        Text("应用需要开通「查看新版文档」和「查看知识库」的用户身份权限，并在安全设置中开启刷新 user_access_token。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if FeishuAccount.app != nil {
                        Button("删除应用凭证，重新创建", role: .destructive) { connector.forgetApp() }
                    }
                } header: {
                    Text("高级")
                }
            }
            .navigationTitle("飞书同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        connector.cancel()
                        dismiss()
                    }
                }
            }
            .onChange(of: connector.phase) { _, phase in
                if phase == .connected { Task { await store.syncAllLinked() } }
            }
            .onDisappear { connector.cancel() }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-feishuAutoConnect"), connector.phase == .idle {
                    connector.connect()
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch connector.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    FeishuLogo(size: 40)
                    Text("连接你的飞书账号").font(.headline)
                }
                Text("在飞书里确认两次就能连接：")
                    .font(.subheadline.weight(.semibold))
                Label("自动创建一个只属于你的应用", systemImage: "1.circle.fill")
                Label("授权它以你的身份读取文档", systemImage: "2.circle.fill")
                Text("不需要去开发者后台，也不需要给每篇文档添加应用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button {
                connector.connect()
            } label: {
                Text("连接飞书")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.feishuBlue)

        case .preparing(let step):
            HStack(spacing: 10) {
                ProgressView()
                Text(step == 1 ? "正在生成确认链接…" : "应用已就绪，正在生成授权链接…")
            }

        case .waiting(let step, let code):
            DeviceCodeCard(step: step, code: code) { connector.cancel() }

        case .connected:
            HStack(spacing: 10) {
                FeishuLogo(size: 24)
                Label("已连接飞书", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if !FeishuAccount.canBrowse {
                Text("点「重新授权」开启浏览和搜索文档的权限。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("重新授权") { connector.connect() }
            Button("断开连接", role: .destructive) { connector.disconnect() }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
            Button("重试") { connector.connect() }
        }
    }
}

/// 显示二维码 + 链接，等待用户在飞书里确认
private struct DeviceCodeCard: View {
    let step: Int
    let code: FeishuDeviceCode
    var onCancel: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("第 \(step) 步，共 2 步：\(step == 1 ? "创建你的专属应用" : "授权读取你的飞书文档")")
                .font(.headline)

            HStack(alignment: .top, spacing: 20) {
                QRCodeView(text: code.url.absoluteString)
                    .frame(width: 168, height: 168)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("用手机飞书扫码，或在浏览器中打开链接，登录后点「确认」。")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        openURL(code.url)
                    } label: {
                        Label("在浏览器中打开", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        UIPasteboard.general.string = code.url.absoluteString
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    if !code.userCode.isEmpty {
                        Text("确认码：\(code.userCode)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("等待你在飞书里确认…").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel).font(.footnote)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray.opacity(0.2)
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 输入链接：新建 / 关联

struct FeishuLinkSheet: View {
    enum Purpose { case importNew, link(UUID) }

    let purpose: Purpose
    var onDone: (UUID) -> Void

    @Environment(ScriptStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var working = false
    @State private var error: String?
    @State private var showConnect = false
    @State private var connected = FeishuAccount.isConnected

    var body: some View {
        NavigationStack {
            Form {
                if !connected {
                    Section {
                        Button {
                            showConnect = true
                        } label: {
                            Label { Text("先连接飞书（扫码确认即可）") } icon: { FeishuLogo(size: 20) }
                        }
                    } footer: {
                        Text("连接一次之后，你能打开的飞书文档都可以直接导入。")
                    }
                }

                Section {
                    TextField("https://xxx.feishu.cn/docx/...", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { link = s }
                    }
                } header: {
                    Text("飞书文档链接")
                } footer: {
                    Text("在飞书文档里点「分享」→「复制链接」。支持云文档和知识库页面。")
                }

                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isImport ? "从飞书导入" : "关联飞书文档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(isImport ? "导入" : "关联") { submit() }
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || !connected)
                    }
                }
            }
            .sheet(isPresented: $showConnect, onDismiss: { connected = FeishuAccount.isConnected }) {
                FeishuConnectView()
            }
        }
    }

    private var isImport: Bool {
        if case .importNew = purpose { return true }
        return false
    }

    private func submit() {
        guard FeishuClient.parse(link) != nil else {
            error = FeishuError.badURL.localizedDescription
            return
        }
        working = true
        error = nil
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
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - 飞书图标

/// 飞书品牌图标（Assets 里的矢量 SVG）
struct FeishuLogo: View {
    var size: CGFloat = 16

    var body: some View {
        Image("FeishuLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// 飞书品牌蓝 #3370FF
    static let feishuBlue = Color(red: 0x33 / 255, green: 0x70 / 255, blue: 0xFF / 255)
}

extension UIImage {
    /// 菜单里用的固定尺寸、保持原色的飞书图标（菜单会忽略 SwiftUI 的 frame）
    static let feishuMenuIcon: UIImage = {
        guard let logo = UIImage(named: "FeishuLogo") else { return UIImage() }
        let box = CGSize(width: 22, height: 22)
        let scale = min(box.width / logo.size.width, box.height / logo.size.height)
        let drawn = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
        let image = UIGraphicsImageRenderer(size: box).image { _ in
            logo.draw(in: CGRect(x: (box.width - drawn.width) / 2, y: (box.height - drawn.height) / 2,
                                 width: drawn.width, height: drawn.height))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }()
}
