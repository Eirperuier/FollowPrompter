import SwiftUI

/// iPad 提词页的"遥控器"面板：已连接的设备、安卓配对码、手动连接地址。
struct RemoteConnectView: View {
    @Bindable var host: RemoteHost
    @State private var address = LANRemoteServer.wifiAddress()

    var body: some View {
        NavigationStack {
            Form {
                Section("已连接") {
                    if host.connectedCount == 0 {
                        Text("还没有遥控器连接").foregroundStyle(.secondary)
                    }
                    if host.appleCount > 0 {
                        Label(host.appleCount > 1 ? "iPhone × \(host.appleCount)" : "iPhone", systemImage: "iphone")
                    }
                    ForEach(host.lanClients, id: \.id) { c in
                        Label(c.name, systemImage: "candybarphone")
                    }
                }

                Section {
                    Label("同一个 App 装到 iPhone 上，打开「遥控器」页，靠近 iPad 会自动连接。", systemImage: "iphone")
                        .font(.callout)
                } header: {
                    Text("iPhone")
                }

                Section {
                    LabeledContent("配对码") {
                        Text(host.pairingCode)
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .kerning(6)
                            .foregroundStyle(.primary)
                    }
                    if let address, let port = host.lanPort {
                        LabeledContent("地址") {
                            Text("\(address):\(String(port))").monospaced().textSelection(.enabled)
                        }
                    } else if host.lanPort == nil {
                        LabeledContent("地址") { Text("正在启动…").foregroundStyle(.secondary) }
                    } else {
                        LabeledContent("地址") { Text("未连接 Wi‑Fi").foregroundStyle(.secondary) }
                    }
                    Button("更换配对码") { host.regenerateCode() }
                } header: {
                    Text("安卓手机")
                } footer: {
                    Text("在安卓手机上安装「随声提词遥控器」，和 iPad 连同一个 Wi‑Fi，打开后会自动找到这台 iPad，第一次输入上面的配对码即可（之后会记住）。找不到时（有些公司 / 酒店 Wi‑Fi 会屏蔽设备发现）可以在遥控器里手动输入地址。")
                }
            }
            .navigationTitle("遥控器")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { address = LANRemoteServer.wifiAddress() }
    }
}
