import AVFoundation
import Speech

/// iOS 26+ 新版语音识别（SpeechAnalyzer + SpeechTranscriber）。
/// - 专为长时间连续语音设计，没有 1 分钟上限，不需要断开重连
/// - volatileResults + fastResults：先给出低延迟的"草稿"结果，再给出确认结果
/// - 完全在设备上运行，模型由系统管理（首次使用某语言需要下载）
///
/// 结果是一段一段给的：确认结果追加到 finalized，草稿结果只保留最新一段。
/// 两者拼起来交给跟踪器，和旧引擎的"整段文字"格式一致。
@available(iOS 26, *)
final class ModernTranscription: @unchecked Sendable {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat?

    // 以下在 start() 之后只在音频线程读取
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // MARK: 语言与模型

    static func resolveLocale(_ id: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    /// 模型已安装返回 nil，否则返回下载请求
    static func installRequest(for locale: Locale) async throws -> AssetInstallationRequest? {
        try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale)])
    }

    // MARK: 生命周期

    init(locale: Locale) async {
        transcriber = Self.makeTranscriber(locale)
        analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .userInitiated, modelRetention: .lingering))
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    /// - Parameters:
    ///   - inputFormat: 麦克风输出格式（会转换成识别模型需要的格式）
    ///   - onText: 当前完整文字（确认部分 + 最新草稿）
    ///   - onEnd: 识别流结束（nil 表示正常结束）
    func start(inputFormat: AVAudioFormat, contextualStrings: [String],
               onText: @escaping @Sendable (String) -> Void,
               onEnd: @escaping @Sendable (Error?) -> Void) async throws {
        if let analyzerFormat, analyzerFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuation = cont

        let transcriber = self.transcriber
        resultsTask = Task {
            var finalized = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onText(finalized + volatile)
                }
                onEnd(nil)
            } catch is CancellationError {
                // 主动停止
            } catch {
                onEnd(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// 在音频线程调用
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        guard let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let analyzerFormat else { return buffer }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}
