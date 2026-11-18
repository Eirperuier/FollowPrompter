import Foundation
import NaturalLanguage

/// 从稿子里挑出值得提示给识别器的词：英文单词 / 缩写、数字、三个字以上的中文词（含系统词典里没有的新词）。
/// 专有名词、术语往往是识别器最容易认错的，提前告诉它能明显提高命中率。
enum ScriptVocabulary {
    static func terms(from text: String, limit: Int = 100) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        func add(_ word: String, count: Int = 1, at position: Int) {
            counts[word, default: 0] += count
            if firstSeen[word] == nil { firstSeen[word] = position }
        }

        // 系统词典里没有的词（提词器、随声提词）会被拆成单字，而且同一个词在不同上下文里拆法还不一样
        // （随|声|提|词、随|声|提词）。所以先把连续的短中文词（一两个字）拼成片段，再在片段里找重复。
        var runs: [(chars: [Character], position: Int)] = []
        var run: [Character] = []
        var runStart = 0
        var runEnd: String.Index?
        func flushRun() {
            if run.count >= 3 { runs.append((run, runStart)) }
            run = []
            runEnd = nil
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let position = text.distance(from: text.startIndex, to: range.lowerBound)
            let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (1...2).contains(word.count), word.allSatisfy(Tokenizer.isIdeographic) {
                if let end = runEnd, end != range.lowerBound { flushRun() }   // 中间隔了标点
                if run.isEmpty { runStart = position }
                run.append(contentsOf: word)
                runEnd = range.upperBound
            } else {
                flushRun()
                if isUseful(word) { add(word, at: position) }
            }
            return true
        }
        flushRun()

        // 片段里反复出现的 3~5 字组合就是新词；偶然拼在一起的（"器很好"）不会重复
        var grams: [String: Int] = [:]
        var gramStart: [String: Int] = [:]
        for (chars, start) in runs {
            for n in 3...min(5, chars.count) {
                for i in 0...(chars.count - n) {
                    let slice = chars[i..<(i + n)]
                    guard let head = slice.first, let tail = slice.last,
                          !fillers.contains(head), !fillers.contains(tail) else { continue }
                    let gram = String(slice)
                    grams[gram, default: 0] += 1
                    if gramStart[gram] == nil { gramStart[gram] = start + i }
                }
            }
        }
        let repeated = grams.filter { $0.value >= 2 }
        for (gram, count) in repeated {
            // 只保留最长的那个："随声提词" 和 "随声提" 次数一样时只要前者
            let covered = repeated.contains { $0.key.count > gram.count && $0.key.contains(gram) && $0.value >= count }
            if !covered { add(gram, count: count, at: gramStart[gram] ?? 0) }
        }

        // 出现次数多的优先，其次按首次出现顺序
        let ranked = counts.keys.sorted { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            return ca != cb ? ca > cb : (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
        }
        return Array(ranked.prefix(limit))
    }

    /// 虚词：新词不会以它们开头或结尾（"我们的"、"是一个"）
    private static let fillers = Set("的了是在和与及也就都很还又而并或我你他她它们这那个一不有把被从对到着过会能要让给得地吗呢吧啊")

    static func isUseful(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= 20 else { return false }
        let hasLatin = word.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
        let hasDigit = word.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let cjkCount = word.filter { Tokenizer.isIdeographic($0) }.count
        if hasLatin { return word.count >= 2 }          // iPad、AI、Kimi
        if hasDigit { return word.count >= 2 }            // 2024、5G
        return cjkCount >= 3                              // 供应链
    }
}
