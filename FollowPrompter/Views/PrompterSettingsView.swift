import SwiftUI

struct PrompterSettingsView: View {
    /// 当前稿件（语言选"自动"时据此判断）
    var scriptText: String = ""
    @AppStorage("fontSize") private var fontSize: Double = 56
    @AppStorage("lineSpacing") private var lineSpacing: Double = 1.35
    @AppStorage("sideMargin") private var sideMargin: Double = 72
    @AppStorage("readingLine") private var readingLine: Double = 0.35
    @AppStorage("mirrorH") private var mirrorH = false
    @AppStorage("mirrorV") private var mirrorV = false
    @AppStorage("dimRead") private var dimRead = true
    @AppStorage("autoSpeed") private var autoSpeed: Double = 60
    @AppStorage("speechLocale") private var speechLocale = SpeechLanguage.automatic
    @AppStorage("speechEngine") private var speechEngine = "auto"
    private var models: SpeechModelStore { .shared }
    @AppStorage("countdown") private var useCountdown = true

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section("文字") {
                slider("字号", value: $fontSize, range: 28...140, step: 2, format: { "\(Int($0))" })
                slider("行距", value: $lineSpacing, range: 1.0...2.2, step: 0.05, format: { String(format: "%.2f", $0) })
                slider("左右边距", value: $sideMargin, range: 0...320, step: 4, format: { "\(Int($0))" })
                slider("阅读线位置", value: $readingLine, range: 0.15...0.7, step: 0.01,
                       format: { "\(Int(($0 * 100).rounded()))%" })
                Toggle("已读文字变暗", isOn: $dimRead)
            }

            Section {
                Toggle("水平镜像", isOn: $mirrorH)
                Toggle("垂直翻转", isOn: $mirrorV)
            } header: {
                Text("镜像")
            } footer: {
                Text("配合提词器分光玻璃使用时打开水平镜像。")
            }

            Section {
                Picker("识别语言", selection: $speechLocale) {
                    Text("自动（跟随稿件）").tag(SpeechLanguage.automatic)
                    ForEach(SpeechLanguage.all) { Text($0.name).tag($0.id) }
                }
                if speechLocale == SpeechLanguage.automatic {
                    LabeledContent("稿件语言") {
                        Text(SpeechLanguage.name(of: effectiveLocale)).foregroundStyle(.secondary)
                    }
                }
                Picker("识别引擎", selection: $speechEngine) {
                    Text("自动（推荐）").tag("auto")
                    Text("旧版").tag("legacy")
                }
                LabeledContent("当前使用") {
                    Text(engineStatus).foregroundStyle(.secondary)
                }
                if speechEngine != "legacy" {
                    modelRow
                }
            } header: {
                Text("跟读").id("voiceSection")
            } footer: {
                Text("跟读模式会实时识别你的声音，在稿子里定位当前读到的位置，滚动速度随你的语速变化。停下来它就停，跳读或重读也能自动找回位置。\n\n识别语言选「自动」时按稿件文字判断（中英混排以占多数的为准）。识别引擎选「自动」时，iPadOS 26 及以上使用新版语音识别（更快、适合长时间连续朗读、完全离线），每种语言首次使用需下载一次模型；否则使用旧版。")
            }

            Section("匀速") {
                slider("滚动速度", value: $autoSpeed, range: 10...300, step: 5, format: { "\(Int($0))" })
            }

            Section {
                Toggle("开始前倒计时 3 秒", isOn: $useCountdown)
            } footer: {
                Text("快捷操作：单击屏幕显示/隐藏控制栏；双击某个字从那里开始；拖动文字手动调整位置。外接键盘或翻页笔：空格 开始/暂停，方向键/翻页键 前后移动。")
            }
        }
        .task(id: effectiveLocale) {
            await models.refresh(effectiveLocale)
        }
        .task {
            guard Self.debugScrollToBottom else { return }
            try? await Task.sleep(for: .milliseconds(600))
            proxy.scrollTo("voiceSection", anchor: .top)
        }
        }
    }

    #if DEBUG
    private static let debugScrollToBottom = ProcessInfo.processInfo.arguments.contains("-settingsBottom")
    #else
    private static let debugScrollToBottom = false
    #endif

    private var effectiveLocale: String { SpeechLanguage.resolve(speechLocale, text: scriptText) }

    private var modelStatus: SpeechModelStore.Status { models.status(effectiveLocale) }

    private var engineStatus: String {
        let legacy = SpeechListener.legacySupportsOnDevice(effectiveLocale) ? "旧版 · 离线" : "旧版 · 需联网"
        guard speechEngine != "legacy" else { return legacy }
        switch modelStatus {
        case .installed, .notInstalled, .downloading, .failed: return "新版识别（离线）"
        case .unknown: return "检查中…"
        case .deviceUnsupported:
            return SpeechListener.modernEngineAvailable
                ? "\(legacy)（这台设备不支持新版，模拟器也不支持）"
                : "\(legacy)（新版需要 iPadOS 26）"
        case .languageUnsupported: return "\(legacy)（新版暂不支持这种语言）"
        }
    }

    /// 识别模型：已下载 / 下载按钮 / 下载进度
    @ViewBuilder private var modelRow: some View {
        switch modelStatus {
        case .installed:
            LabeledContent("识别模型") {
                Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .notInstalled, .failed:
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("识别模型") {
                    Button("下载") { download() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if case .failed(let message) = modelStatus {
                    Text("下载失败：\(message)").font(.caption).foregroundStyle(.red)
                } else {
                    Text("首次使用「\(SpeechLanguage.name(of: effectiveLocale))」需要下载，提前下好开始时就不用等").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("识别模型") {
                    Text("下载中 \(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: p)
            }
        case .unknown, .deviceUnsupported, .languageUnsupported:
            EmptyView()
        }
    }

    private func download() {
        let id = effectiveLocale
        Task { try? await models.ensure(id) }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
