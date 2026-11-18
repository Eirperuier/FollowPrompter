import SwiftUI

enum PrompterMode: String, CaseIterable, Identifiable {
    case voice, auto, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .voice: "跟读"
        case .auto: "匀速"
        case .manual: "手动"
        }
    }
}

struct PrompterView: View {
    let script: Script

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
    @AppStorage("mode") private var mode: PrompterMode = .voice
    @AppStorage("countdown") private var useCountdown = true

    @State private var tracker: PromptTracker
    @State private var listener = SpeechListener()
    @State private var running = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var showSettings = false
    @State private var showRemote = false
    @State private var accumulated: TimeInterval = 0
    @State private var runStart: Date?
    @State private var now = Date()
    @State private var lastInteraction = Date()
    @State private var alertMessage: String?
    @State private var viewSize: CGSize = .zero
    @State private var remote = RemoteHost()
    @State private var rereadCount = 0
    @State private var toast: String?
    @State private var toastID = 0
    @FocusState private var focused: Bool

    init(script: Script) {
        self.script = script
        _tracker = State(initialValue: PromptTracker(text: script.body))
    }

    private var elapsed: TimeInterval {
        accumulated + (runStart.map { now.timeIntervalSince($0) } ?? 0)
    }

    private var unitName: String { tracker.isMostlyCJK ? "字" : "词" }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack {
                    PrompterTextView(
                        text: tracker.text,
                        tokens: tracker.tokens,
                        spoken: tracker.spoken,
                        revision: tracker.revision,
                        style: PrompterStyle(fontSize: fontSize, lineSpacing: lineSpacing,
                                             sideMargin: sideMargin, dimRead: dimRead),
                        readingLine: readingLine,
                        mirrorH: mirrorH,
                        mirrorV: mirrorV,
                        autoSpeed: (mode == .auto && running && countdown == nil) ? autoSpeed : nil,
                        smoothReveal: mode == .voice,
                        jumps: tracker.jumps,
                        paceRate: tracker.rate,
                        onUserMove: { tracker.jump(to: $0); lastInteraction = Date() },
                        onAutoProgress: { tracker.setFromAutoScroll($0) },
                        onSingleTap: toggleControls
                    )
                    ReadingLineMarker(listening: listener.isListening, level: listener.level)
                        .position(x: geo.size.width / 2,
                                  y: geo.size.height * (mirrorV ? 1 - readingLine : readingLine))
                        .allowsHitTesting(false)
                }
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, s in viewSize = s }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if controlsVisible {
                    topBar.transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if controlsVisible {
                    bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ProgressView(value: tracker.progress)
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .opacity(0.7)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            if let toast {
                VStack {
                    Text(toast)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
            }

            if let text = listener.preparingText {
                VStack(spacing: 12) {
                    if let p = listener.downloadProgress {
                        ProgressView(value: p).frame(width: 260)
                        Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Text(text).font(.headline)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .allowsHitTesting(false)
            }

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 180, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 20)
                    .contentTransition(.numericText(countsDown: true))
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { toggleRun(); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.pageUp) { step(-4); return .handled }
        .onKeyPress(.pageDown) { step(4); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.delete) { perform(.rereadSentence); return .handled }
        .onAppear {
            focused = true
            UIApplication.shared.isIdleTimerDisabled = true
            let t = tracker
            listener.onTranscript = { text, session in t.ingest(transcript: text, session: session) }
            listener.contextualStrings = ScriptVocabulary.terms(from: script.body)
            if mode == .voice {
                // 提前下载识别模型，按开始时不用等
                Task { await listener.prepareModel(localeID: recognitionLocale, preferModern: preferModern) }
            }
            remote.onCommand = { perform($0) }
            remote.start()
            #if DEBUG
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-demoSpoken"),
               i + 1 < ProcessInfo.processInfo.arguments.count,
               let n = Int(ProcessInfo.processInfo.arguments[i + 1]) {
                tracker.jump(to: n)
            }
            if ProcessInfo.processInfo.arguments.contains("-showSettings") { showSettings = true }
            if ProcessInfo.processInfo.arguments.contains("-showRemote") { showRemote = true }
            if ProcessInfo.processInfo.arguments.contains("-demoChunks") {
                // 模拟识别器：每 0.8 秒送来一批 4 个字
                let body = Array(script.body)
                Task { @MainActor in
                    var n = 0
                    while n < body.count {
                        try? await Task.sleep(for: .milliseconds(800))
                        n += 4
                        tracker.ingest(transcript: String(body.prefix(n)), session: 999)
                    }
                }
            }
            #endif
        }
        .onDisappear {
            listener.stop()
            remote.stop()
            countdownTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { date in
            now = date
            if running && countdown == nil { tracker.sampleRate() }
            pushStatus()
            if running, controlsVisible, !showSettings, !showRemote, date.timeIntervalSince(lastInteraction) > 3.5 {
                withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
            }
        }
        .onChange(of: mode) { _, _ in
            pause()
            tracker.resetRate()
        }
        .onChange(of: tracker.spoken) { _, _ in pushStatus() }
        .onChange(of: running) { _, _ in pushStatus() }
        .onChange(of: countdown) { _, _ in pushStatus() }
        .onChange(of: remote.connectedCount) { _, _ in pushStatus() }
        .onChange(of: listener.errorMessage) { _, msg in
            if let msg { alertMessage = msg; pause() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && running { pause() }
        }
        .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: 控制栏

    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())

            Text(script.title.isEmpty ? "未命名稿件" : script.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            Picker("模式", selection: $mode) {
                ForEach(PrompterMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Spacer()

            Button {
                showSettings = true
                lastInteraction = Date()
            } label: {
                Image(systemName: "textformat.size")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())
            .popover(isPresented: $showSettings) {
                PrompterSettingsView(scriptText: script.body)
                    .frame(width: 400, height: 640)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            statusBadge

            HStack(spacing: 18) {
                stat("用时", timeString(elapsed))
                if mode == .voice {
                    stat("语速", tracker.rate > 0 ? "\(Int(tracker.rate)) \(unitName)/分" : "—")
                }
                stat("剩余", remainingString)
                stat("进度", "\(Int((tracker.progress * 100).rounded()))%")
            }

            Spacer()

            Button {
                showRemote = true
                lastInteraction = Date()
            } label: {
                Image(systemName: remote.connectedCount > 0 ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                    .font(.title3)
                    .foregroundStyle(remote.connectedCount > 0 ? .green : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(remote.connectedCount > 0 ? "遥控器已连接" : "连接遥控器")
            .popover(isPresented: $showRemote) {
                RemoteConnectView(host: remote)
                    .frame(width: 380, height: 560)
                    .presentationCompactAdaptation(.popover)
            }

            HStack(spacing: 10) {
                Button { perform(.rereadSentence) } label: {
                    Label("重读本句", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Color.red.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
                circleButton("backward.end.fill") { perform(.restart) }
                circleButton("chevron.up") { step(-1) }
                circleButton("chevron.down") { step(1) }
            }

            Button(action: toggleRun) {
                Image(systemName: running || countdown != nil ? "pause.fill" : "play.fill")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(Color.orange, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch mode {
        case .voice:
            HStack(spacing: 8) {
                MicLevelView(level: listener.level, active: listener.isListening)
                Text(listener.isListening ? "正在聆听" : "跟读已暂停")
                    .font(.subheadline.weight(.medium))
                if let kind = listener.engineKind {
                    Text("\(engineLabel(kind)) · \(SpeechLanguage.shortName(of: recognitionLocale))")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((kind == .modern ? Color.green : Color.gray).opacity(0.25), in: Capsule())
                }
            }
        case .auto:
            Label("匀速 \(Int(autoSpeed))", systemImage: "gauge.with.dots.needle.33percent")
                .font(.subheadline.weight(.medium))
        case .manual:
            Label("手动滚动", systemImage: "hand.draw")
                .font(.subheadline.weight(.medium))
        }
    }

    private func engineLabel(_ kind: SpeechListener.EngineKind) -> String {
        switch kind {
        case .modern: "新版识别"
        case .legacy(let onDevice): onDevice ? "旧版 · 离线" : "旧版 · 联网"
        }
    }

    private var preferModern: Bool { speechEngine != "legacy" }

    /// 实际识别语言（"自动"时按稿件判断）
    private var recognitionLocale: String { SpeechLanguage.resolve(speechLocale, text: script.body) }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            lastInteraction = Date()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var remainingString: String {
        let rate: Double
        switch mode {
        case .voice: rate = tracker.rate > 40 ? tracker.rate : (tracker.isMostlyCJK ? 240 : 150)
        default: rate = tracker.isMostlyCJK ? 240 : 150
        }
        return "约 " + timeString(Double(tracker.remainingTokens) / rate * 60)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 动作

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.25)) { controlsVisible.toggle() }
        lastInteraction = Date()
    }

    private func toggleRun() {
        lastInteraction = Date()
        if running || countdown != nil { pause() } else { start() }
    }

    private func start() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            if mode == .voice {
                // 先启动识别再倒数，倒数结束时识别器已经就绪
                guard await listener.start(localeID: recognitionLocale, preferModern: preferModern) else { return }
                if Task.isCancelled { listener.stop(); return }
            }
            if useCountdown {
                for n in stride(from: 3, through: 1, by: -1) {
                    withAnimation { countdown = n }
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { countdown = nil; return }
                }
                countdown = nil
            }
            begin()
        }
    }

    private func begin() {
        running = true
        runStart = Date()
        lastInteraction = Date()
    }

    private func pause() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        listener.stop()
        if let runStart { accumulated += Date().timeIntervalSince(runStart) }
        runStart = nil
        running = false
        withAnimation { controlsVisible = true }
    }

    // MARK: 遥控 / 重读

    private func perform(_ cmd: RemoteCommand) {
        lastInteraction = Date()
        switch cmd {
        case .toggle: toggleRun()
        case .rereadSentence: reread("重读本句") { tracker.restartSentence() }
        case .rereadParagraph: reread("重读本段") { tracker.restartParagraph() }
        case .previousSentence: tracker.previousSentence()
        case .nextSentence: tracker.nextSentence()
        case .restart:
            tracker.jump(to: 0)
            rereadCount = 0
            resetClock()
        case .faster: autoSpeed = min(300, autoSpeed + 10)
        case .slower: autoSpeed = max(10, autoSpeed - 10)
        }
        pushStatus()
    }

    private func reread(_ message: String, _ move: () -> Void) {
        rereadCount += 1
        move()
        // 匀速模式下停一下、重新倒数，给演讲者调整的时间；跟读模式会自然等你开口
        if mode == .auto && running {
            pause()
            start()
        }
        toastID += 1
        let id = toastID
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if toastID == id { withAnimation(.easeIn(duration: 0.3)) { toast = nil } }
        }
    }

    private func pushStatus() {
        guard remote.connectedCount > 0 else { return }
        remote.publish(RemoteStatus(
            title: script.title,
            mode: mode.rawValue,
            running: running,
            countdown: countdown,
            listening: listener.isListening,
            progress: tracker.progress,
            elapsed: Int(elapsed),
            current: String(tracker.sentenceText().prefix(160)),
            next: String(tracker.sentenceText(offset: 1).prefix(120)),
            rereadCount: rereadCount,
            autoSpeed: Int(autoSpeed)
        ))
    }

    private func resetClock() {
        accumulated = 0
        runStart = running ? Date() : nil
        tracker.resetRate()
    }

    private func close() {
        pause()
        dismiss()
    }

    /// 按"大约一行"的 token 数前进/后退
    private func step(_ lines: Int) {
        let width = max(200, viewSize.width - 2 * sideMargin)
        let perLine = tracker.isMostlyCJK ? width / (fontSize * 1.02) : width / (fontSize * 2.6)
        tracker.jump(by: Int((perLine * Double(lines)).rounded()))
        lastInteraction = Date()
    }
}

// MARK: - 小组件

private struct ReadingLineMarker: View {
    var listening: Bool
    var level: Float

    var body: some View {
        HStack(spacing: 0) {
            Triangle().fill(Color.orange).frame(width: 18, height: 22)
            Rectangle()
                .fill(LinearGradient(colors: [.orange.opacity(0.55), .orange.opacity(0.08), .orange.opacity(0.55)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
            Triangle().fill(Color.orange).frame(width: 18, height: 22).scaleEffect(x: -1)
        }
        .opacity(listening ? 0.6 + Double(level) * 0.4 : 0.6)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

private struct MicLevelView: View {
    var level: Float
    var active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<4) { i in
                let threshold = Float(i) / 4
                Capsule()
                    .fill(active && level > threshold ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 4, height: 8 + CGFloat(i) * 4)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
