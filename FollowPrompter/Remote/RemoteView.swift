import SwiftUI

/// iPhone 遥控器界面。按钮做得大，录制时不用低头看也能按到。
struct RemoteView: View {
    @Bindable var client: RemoteClient
    @State private var tapCount = 0
    @State private var rereadTapCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                connectionHeader
                statusCard
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .navigationTitle("遥控器")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.impact(weight: .medium), trigger: tapCount)
            .sensoryFeedback(.warning, trigger: rereadTapCount)
        }
        .onAppear {
            client.start()
            UIApplication.shared.isIdleTimerDisabled = true   // 锁屏会断开连接
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #if DEBUG
        .onChange(of: client.status != nil) { _, has in
            let args = ProcessInfo.processInfo.arguments
            guard has, let i = args.firstIndex(of: "-sendOnConnect"), i + 1 < args.count,
                  let cmd = RemoteCommand(rawValue: args[i + 1]) else { return }
            Task { try? await Task.sleep(for: .seconds(1)); send(cmd, strong: true) }
        }
        #endif
    }

    // MARK: 连接状态

    @ViewBuilder
    private var connectionHeader: some View {
        if let peer = client.connected {
            HStack {
                Circle().fill(.green).frame(width: 10, height: 10)
                Text("已连接 \(peer.displayName)").font(.subheadline.weight(.medium))
                Spacer()
                Button("断开") { client.disconnect() }.font(.subheadline)
            }
            .padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(client.connecting != nil ? "正在连接…" : "正在寻找 iPad…")
                        .font(.subheadline.weight(.medium))
                }
                if client.found.count > 1 || (!client.found.isEmpty && client.connecting == nil) {
                    ForEach(Array(client.found.enumerated()), id: \.offset) { i, peer in
                        Button {
                            client.connect(peer)
                        } label: {
                            Label(client.found.count > 1 ? "\(peer.displayName) \(i + 1)" : peer.displayName,
                                  systemImage: "ipad.landscape")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("在 iPad 上打开任意稿件的提词页面，两台设备靠近一些即可自动连接（需要打开蓝牙或 Wi‑Fi，不需要联网）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    // MARK: 提词状态

    @ViewBuilder
    private var statusCard: some View {
        if let s = client.status {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(s.title.isEmpty ? "未命名稿件" : s.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(stateText(s))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((s.running ? Color.green : Color.gray).opacity(0.25), in: Capsule())
                }
                ProgressView(value: s.progress).tint(.orange)
                HStack {
                    Text(String(format: "%d:%02d", s.elapsed / 60, s.elapsed % 60)).monospacedDigit()
                    Spacer()
                    Text("\(Int((s.progress * 100).rounded()))%").monospacedDigit()
                    Spacer()
                    Text("重读 \(s.rereadCount) 次").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                Text(s.current.isEmpty ? "—" : s.current)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !s.next.isEmpty {
                    Text(s.next)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if client.isConnected {
            ProgressView("正在同步…").frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func stateText(_ s: RemoteStatus) -> String {
        if let c = s.countdown { return "倒数 \(c)" }
        let mode = PrompterMode(rawValue: s.mode)?.title ?? ""
        return s.running ? "\(mode)中" : "已暂停"
    }

    // MARK: 按钮

    private var controls: some View {
        let s = client.status
        let enabled = client.isConnected
        return VStack(spacing: 12) {
            Button {
                send(.rereadSentence, strong: true)
            } label: {
                VStack(spacing: 4) {
                    Label("重读本句", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                    Text("连按逐句后退").font(.footnote.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
            .buttonStyle(RemoteButtonStyle(color: .red))

            HStack(spacing: 12) {
                bigButton("重读本段", icon: "arrow.uturn.backward.circle", color: .orange) { send(.rereadParagraph, strong: true) }
                bigButton("回到开头", icon: "backward.end.fill", color: .gray) { send(.restart) }
            }

            HStack(spacing: 12) {
                bigButton("上一句", icon: "chevron.up", color: .gray) { send(.previousSentence) }
                Button {
                    send(.toggle)
                } label: {
                    Image(systemName: (s?.running ?? false) || s?.countdown != nil ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 84)
                }
                .buttonStyle(RemoteButtonStyle(color: .green))
                bigButton("下一句", icon: "chevron.down", color: .gray) { send(.nextSentence) }
            }

            if s?.mode == PrompterMode.auto.rawValue {
                HStack(spacing: 12) {
                    bigButton("慢一点", icon: "tortoise.fill", color: .blue) { send(.slower) }
                    Text("\(s?.autoSpeed ?? 0)")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .frame(width: 70)
                    bigButton("快一点", icon: "hare.fill", color: .blue) { send(.faster) }
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func bigButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2.weight(.semibold))
                Text(title).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 84)
        }
        .buttonStyle(RemoteButtonStyle(color: color))
    }

    private func send(_ cmd: RemoteCommand, strong: Bool = false) {
        client.send(cmd)
        if strong { rereadTapCount += 1 } else { tapCount += 1 }
    }
}

private struct RemoteButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.55 : 0.85),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
