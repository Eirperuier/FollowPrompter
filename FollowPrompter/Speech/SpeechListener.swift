import AVFoundation
import Speech
import Observation

/// 音频线程把麦克风数据交给当前引擎；切换时加锁。
final class AudioRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?

    func set(_ new: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); sink = new; lock.unlock()
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let s = sink; lock.unlock()
        s?(buffer)
    }
}

/// 持续语音识别。两套引擎：
/// - 新版（iOS 26+）：SpeechAnalyzer / SpeechTranscriber，一条连续的识别流
/// - 旧版：SFSpeechRecognizer，任务结束后自动续上新任务
/// 每次（重新）开始识别时 session 号递增，跟踪器据此知道文字是从头累积的。
@MainActor @Observable
final class SpeechListener {
    enum EngineKind: Equatable { case modern, legacy(onDevice: Bool) }

    private(set) var isListening = false
    private(set) var level: Float = 0
    private(set) var errorMessage: String?
    private(set) var engineKind: EngineKind?
    /// 准备阶段的提示（下载模型、启动识别）
    private(set) var preparingText: String?
    /// 正在准备模型的语言
    private(set) var modelLocaleID: String?
    /// 模型下载进度 0...1（和设置页共用 SpeechModelStore 的状态）
    var downloadProgress: Double? {
        guard let id = modelLocaleID, case .downloading(let p) = SpeechModelStore.shared.status(id) else { return nil }
        return p
    }

    @ObservationIgnored var onTranscript: ((String, Int) -> Void)?
    @ObservationIgnored var contextualStrings: [String] = []

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let router = AudioRouter()
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var failures: [Date] = []
    @ObservationIgnored private var localeID = "zh-CN"
    @ObservationIgnored private var preferModern = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // 旧引擎
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var legacyTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var rollover: Task<Void, Never>?

    // 新引擎（类型只在 iOS 26+ 可用，这里用 AnyObject 存）
    @ObservationIgnored private var modernSession: AnyObject?

    var usesOnDevice: Bool {
        switch engineKind {
        case .modern: true
        case .legacy(let onDevice): onDevice
        case nil: false
        }
    }

    // MARK: 能力查询

    static var modernEngineAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    /// 设备本身能否运行新版识别（模拟器和较老的机型不行）
    static var modernDeviceSupported: Bool {
        if #available(iOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    static func legacySupportsOnDevice(_ localeID: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    // MARK: 准备（提前下载模型，进入提词页时调用）

    func prepareModel(localeID: String, preferModern: Bool) async {
        #if DEBUG
        let fake = SpeechModelStore.fakeDownload
        #else
        let fake = false
        #endif
        guard preferModern, fake || SpeechListener.modernEngineAvailable else { return }
        await SpeechModelStore.shared.refresh(localeID)
        guard SpeechModelStore.shared.status(localeID) == .notInstalled else { return }
        do {
            try await ensureModel(localeID)
            guard !isListening else { return }
            preparingText = "识别模型已下载完成"
            try? await Task.sleep(for: .seconds(1.5))
            if !isListening, preparingText == "识别模型已下载完成" { preparingText = nil }
        } catch {
            preparingText = nil
        }
    }

    // MARK: 启停

    /// 开始识别；失败时 errorMessage 会给出原因
    @discardableResult
    func start(localeID: String, preferModern: Bool) async -> Bool {
        guard !isListening else { return true }
        errorMessage = nil
        self.localeID = localeID
        self.preferModern = preferModern

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "没有麦克风权限。请到「设置 › 隐私与安全性 › 麦克风」中允许“随声提词”。"
            return false
        }

        if preferModern, #available(iOS 26, *), let locale = await ModernTranscription.resolveLocale(localeID) {
            do {
                try await startModern(locale, localeID: localeID)
                return true
            } catch {
                print("新版识别启动失败，改用旧版：\(error)")
                await teardownModern()
                teardownAudio()
            }
        }
        preparingText = nil
        return await startLegacy(localeID)
    }

    func stop() {
        isListening = false
        engineKind = nil
        session += 1
        router.set(nil)
        // 旧引擎
        rollover?.cancel(); rollover = nil
        legacyTask?.cancel(); legacyTask = nil
        legacyRequest?.endAudio(); legacyRequest = nil
        // 新引擎
        if let s = modernSession {
            modernSession = nil
            Task { await Self.stopModern(s) }
        }
        teardownAudio()
        removeObservers()
        level = 0
        preparingText = nil
    }

    // MARK: 新引擎

    private func ensureModel(_ localeID: String) async throws {
        let store = SpeechModelStore.shared
        if store.status(localeID) != .installed {
            await store.refresh(localeID)
        }
        switch store.status(localeID) {
        case .installed: return
        case .notInstalled, .downloading, .failed, .unknown:
            modelLocaleID = localeID
            preparingText = "首次使用，正在下载「\(SpeechLanguage.name(of: localeID))」识别模型…"
            defer { modelLocaleID = nil }
            try await store.ensure(localeID)
        case .deviceUnsupported, .languageUnsupported:
            throw Self.noModernError
        }
    }

    @available(iOS 26, *)
    private func startModern(_ locale: Locale, localeID: String) async throws {
        try await ensureModel(localeID)
        preparingText = "正在启动语音识别…"
        defer { preparingText = nil }

        let transcription = await ModernTranscription(locale: locale)
        try configureAudioSession()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Self.noMicError }

        session += 1
        let id = session
        try await transcription.start(
            inputFormat: format,
            contextualStrings: contextualStrings,
            onText: { [weak self] text in
                Task { @MainActor in self?.handle(text: text, session: id) }
            },
            onEnd: { [weak self] error in
                let message = error.map { ($0 as NSError).localizedDescription }
                Task { @MainActor in self?.modernEnded(errorText: message, session: id) }
            })
        modernSession = transcription
        router.set { transcription.feed($0) }
        try startEngine()
        isListening = true
        engineKind = .modern
        failures.removeAll()
        addObservers()
    }

    private func teardownModern() async {
        router.set(nil)
        if let s = modernSession {
            modernSession = nil
            await Self.stopModern(s)
        }
    }

    private static func stopModern(_ object: AnyObject) async {
        if #available(iOS 26, *), let s = object as? ModernTranscription { await s.stop() }
    }

    /// 新引擎的识别流意外结束：短时间内多次失败就停止，否则重新开始
    private func modernEnded(errorText: String?, session id: Int) {
        guard id == session, isListening else { return }
        guard recordFailure(errorText) else { return }
        restart()
    }

    // MARK: 旧引擎

    private func startLegacy(_ localeID: String) async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            errorMessage = "没有语音识别权限。请到「设置 › 隐私与安全性 › 语音识别」中允许“随声提词”。"
            return false
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            errorMessage = "这台设备不支持所选的识别语言。"
            return false
        }
        guard rec.isAvailable else {
            errorMessage = "语音识别暂时不可用。如果设备没有该语言的离线识别模型，需要联网使用。"
            return false
        }
        recognizer = rec
        do {
            try configureAudioSession()
            try startEngine()
        } catch {
            errorMessage = "无法启动麦克风：\(error.localizedDescription)"
            teardownAudio()
            return false
        }
        isListening = true
        engineKind = .legacy(onDevice: rec.supportsOnDeviceRecognition)
        failures.removeAll()
        addObservers()
        startLegacyTask()
        return true
    }

    private func startLegacyTask() {
        guard isListening, let rec = recognizer else { return }
        legacyTask?.cancel()
        session += 1
        let id = session

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = contextualStrings
        let old = legacyRequest
        legacyRequest = req
        router.set { req.append($0) }
        old?.endAudio()
        legacyTask = rec.recognitionTask(with: req, resultHandler: Self.makeLegacyHandler(listener: self, session: id))

        // 联网识别单次最长约 1 分钟，提前换新任务
        rollover?.cancel()
        if !rec.supportsOnDeviceRecognition {
            rollover = Task { [weak self] in
                try? await Task.sleep(for: .seconds(50))
                guard !Task.isCancelled, let self, self.session == id else { return }
                self.startLegacyTask()
            }
        }
    }

    fileprivate func handleLegacy(text: String?, done: Bool, errorText: String?, session id: Int) {
        guard id == session, isListening else { return }
        if let text, !text.isEmpty { onTranscript?(text, id) }
        guard done, recordFailure(errorText) else { return }
        session += 1   // 作废旧任务的后续回调
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.isListening else { return }
            self.startLegacyTask()
        }
    }

    // MARK: 公共

    private func handle(text: String, session id: Int) {
        guard id == session, isListening, !text.isEmpty else { return }
        onTranscript?(text, id)
    }

    /// 记录一次中断；10 秒内超过 6 次就停止并报错。返回 false 表示已停止
    private func recordFailure(_ errorText: String?) -> Bool {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 10 } + [now]
        if failures.count > 6 {
            stop()
            errorMessage = "语音识别连续中断，已暂停跟读。\(errorText.map { "（\($0)）" } ?? "")"
            return false
        }
        return true
    }

    /// 整体重启（插拔耳机、新引擎流意外结束）
    private func restart() {
        let id = localeID, modern = preferModern
        stop()
        Task { [weak self] in
            guard let self else { return }
            await self.start(localeID: id, preferModern: modern)
        }
    }

    private static let noModernError = NSError(domain: "FollowPrompter", code: 3,
                                               userInfo: [NSLocalizedDescriptionKey: "新版识别不可用"])
    private static let noMicError = NSError(domain: "FollowPrompter", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风输入"])

    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try s.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Self.noMicError }
        input.removeTap(onBus: 0)
        let sink: @Sendable (Float) -> Void = { [weak self] v in
            Task { @MainActor in self?.level = v }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(router: router, level: sink))
        engine.prepare()
        try engine.start()
    }

    private func teardownAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func addObservers() {
        removeObservers()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                guard let self, self.isListening else { return }
                self.stop()
                self.errorMessage = "录音被打断（例如来电），已暂停跟读。"
            }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            // 插拔耳机/外接麦克风后输入格式会变，整体重启
            MainActor.assumeIsolated {
                guard let self, self.isListening else { return }
                self.restart()
            }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: 非隔离的回调构造（在音频线程/识别线程上执行）

    nonisolated private static func makeTap(router: AudioRouter,
                                            level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            router.send(buffer)
            level(rms(buffer))
        }
    }

    nonisolated private static func makeLegacyHandler(listener: SpeechListener, session: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak listener] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            let errorText = (error as NSError?)?.localizedDescription
            Task { @MainActor in
                listener?.handleLegacy(text: text, done: done, errorText: errorText, session: session)
            }
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < n { sum += data[i] * data[i]; count += 1; i += 4 }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 55) / 45))
    }
}
