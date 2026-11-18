import Foundation
import QuartzCore
import Observation

/// 提词进度的唯一数据源：已读到第几个 token、语速估计。
@MainActor @Observable
final class PromptTracker {
    let text: String
    let tokens: [SpeechToken]
    let isMostlyCJK: Bool
    /// 每个句子 / 段落第一个 token 的下标（升序，首元素为 0）
    let sentenceStarts: [Int]
    let paragraphStarts: [Int]

    /// 已读 token 数（0...tokens.count）
    private(set) var spoken = 0
    /// 外部跳转（语音定位、手动拖动、键盘）时递增，文本视图据此滚动
    private(set) var revision = 0
    /// 手动跳转（拖动、双击、键盘、遥控重读）时递增；语音推进不算
    private(set) var jumps = 0
    /// 语速：每分钟 token 数（中文即 字/分钟）
    private(set) var rate: Double = 0

    @ObservationIgnored private let aligner: SpeechAligner
    @ObservationIgnored private var history: [(t: CFTimeInterval, s: Int)] = []
    @ObservationIgnored private var session = -1
    @ObservationIgnored private var baseline = 0
    @ObservationIgnored private var lastTranscriptCount = 0

    init(text: String) {
        self.text = text
        let tokens = Tokenizer.tokenize(text)
        self.tokens = tokens
        self.aligner = SpeechAligner(script: tokens)
        let cjk = tokens.filter { $0.surface.unicodeScalars.first.map { $0.value >= 0x3000 } ?? false }.count
        self.isMostlyCJK = tokens.isEmpty || cjk * 2 >= tokens.count
        (sentenceStarts, paragraphStarts) = Self.boundaries(text: text, tokens: tokens)
    }

    var progress: Double { tokens.isEmpty ? 0 : Double(spoken) / Double(tokens.count) }
    var remainingTokens: Int { tokens.count - spoken }

    /// 接收识别器的（部分）结果。每个识别会话的文字从头累积。
    func ingest(transcript: String, session id: Int) {
        if id != session { session = id; baseline = 0; lastTranscriptCount = 0 }
        let chars = Array(transcript)
        lastTranscriptCount = chars.count
        guard chars.count > baseline else { return }
        let tail = String(chars[max(baseline, chars.count - 64)...])
        let heard = Tokenizer.tokenize(tail)
        guard let idx = aligner.locate(heard: heard, spoken: spoken) else { return }
        let next = min(idx + 1, tokens.count)
        guard next != spoken else { return }
        spoken = next
        revision += 1
    }

    /// 用户手动定位（拖动、双击、键盘）。之前听到的内容不再参与匹配。
    func jump(to s: Int) {
        spoken = min(max(0, s), tokens.count)
        baseline = lastTranscriptCount
        history.removeAll()
        jumps += 1
        revision += 1
    }

    func jump(by delta: Int) { jump(to: spoken + delta) }

    /// 匀速滚动模式下由视图回报的位置（不触发重新定位）
    func setFromAutoScroll(_ s: Int) {
        let c = min(max(0, s), tokens.count)
        if c != spoken { spoken = c }
    }

    /// 运行时定期调用，用最近 15 秒的进度估计语速
    func sampleRate() {
        let now = CACurrentMediaTime()
        history.append((now, spoken))
        history.removeAll { now - $0.t > 15 }
        guard let first = history.first, now - first.t >= 4 else { return }
        let r = Double(spoken - first.s) / (now - first.t) * 60
        rate = max(0, r)
    }

    func resetRate() { history.removeAll(); rate = 0 }

    // MARK: 按句 / 段跳转（重读）

    /// 重读：回到当前句开头。如果刚好就在句首（例如连按重读），再往前退一句。
    func restartSentence() { restartUnit(sentenceStarts) }
    /// 重读：回到当前段开头，规则同上。
    func restartParagraph() { restartUnit(paragraphStarts) }

    func previousSentence() {
        let k = Self.unitIndex(sentenceStarts, containing: cursor)
        jump(to: sentenceStarts[max(0, k - 1)])
    }

    func nextSentence() {
        let k = Self.unitIndex(sentenceStarts, containing: cursor)
        jump(to: k + 1 < sentenceStarts.count ? sentenceStarts[k + 1] : tokens.count)
    }

    /// 当前句（offset 0）或其后第 offset 句的原文
    func sentenceText(offset: Int = 0) -> String {
        guard !tokens.isEmpty else { return "" }
        let k = Self.unitIndex(sentenceStarts, containing: cursor) + offset
        guard k >= 0, k < sentenceStarts.count else { return "" }
        let start = tokens[sentenceStarts[k]].range.location
        let end = k + 1 < sentenceStarts.count ? tokens[sentenceStarts[k + 1]].range.location : (text as NSString).length
        return (text as NSString).substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 下一个要读的 token
    private var cursor: Int { min(spoken, max(tokens.count - 1, 0)) }

    private func restartUnit(_ starts: [Int]) {
        guard !tokens.isEmpty else { return }
        var k = Self.unitIndex(starts, containing: cursor)
        if spoken - starts[k] < 2, k > 0 { k -= 1 }
        jump(to: starts[k])
    }

    /// 最大的 k 使 starts[k] <= t
    static func unitIndex(_ starts: [Int], containing t: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func boundaries(text: String, tokens: [SpeechToken]) -> (sentences: [Int], paragraphs: [Int]) {
        var sentences = [0], paragraphs = [0]
        guard tokens.count > 1 else { return (sentences, paragraphs) }
        let ns = text as NSString
        let enders = CharacterSet(charactersIn: "。！？!?；;…")
        for i in 1..<tokens.count {
            let a = tokens[i - 1].range.upperBound, b = tokens[i].range.location
            guard b > a else { continue }
            let gap = ns.substring(with: NSRange(location: a, length: b - a))
            let newline = gap.rangeOfCharacter(from: .newlines) != nil
            let ender = gap.rangeOfCharacter(from: enders) != nil
                || (gap.contains(".") && gap.rangeOfCharacter(from: .whitespaces) != nil)
            if newline || ender { sentences.append(i) }
            if newline { paragraphs.append(i) }
        }
        return (sentences, paragraphs)
    }
}
