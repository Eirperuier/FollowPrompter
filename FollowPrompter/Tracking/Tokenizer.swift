import Foundation

/// 一个可用于匹配的"读音单位"：中文/日文是单个字，英文等是一个单词。
struct SpeechToken: Equatable {
    /// 规范化后的字面（小写、去掉变音符、全角转半角）
    let surface: String
    /// 读音键：汉字为模糊拼音（不分平翘舌、前后鼻音、n/l），其它与字面相同
    let sound: String
    /// 在原文中的 UTF-16 范围（与 NSString / TextKit 一致）
    let range: NSRange
}

enum Tokenizer {
    private static let lock = NSLock()
    private static var pinyinCache: [Character: String] = [:]

    static func tokenize(_ text: String) -> [SpeechToken] {
        var tokens: [SpeechToken] = []
        tokens.reserveCapacity(text.utf16.count / 2)
        var offset = 0
        var word = ""
        var wordStart = 0

        func flush(_ end: Int) {
            guard !word.isEmpty else { return }
            let w = normalizeWord(word)
            if !w.isEmpty {
                tokens.append(SpeechToken(surface: w, sound: w,
                                          range: NSRange(location: wordStart, length: end - wordStart)))
            }
            word = ""
        }

        for ch in text {
            let len = ch.utf16.count
            if isIdeographic(ch) {
                flush(offset)
                tokens.append(SpeechToken(surface: String(ch), sound: sound(of: ch),
                                          range: NSRange(location: offset, length: len)))
            } else if ch.isLetter || ch.isNumber || (!word.isEmpty && (ch == "'" || ch == "’")) {
                if word.isEmpty { wordStart = offset }
                word.append(ch)
            } else {
                flush(offset)
            }
            offset += len
        }
        flush(offset)
        return tokens
    }

    /// 轻量统计（不计算拼音），用于编辑页显示字数。
    static func countUnits(_ text: String) -> (count: Int, cjk: Int) {
        var count = 0, cjk = 0, inWord = false
        for ch in text {
            if isIdeographic(ch) {
                count += 1; cjk += 1; inWord = false
            } else if ch.isLetter || ch.isNumber {
                if !inWord { count += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return (count, cjk)
    }

    static func isIdeographic(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return isHan(v) || (0x3040...0x30FF).contains(v)   // 平假名 / 片假名
    }

    private static func isHan(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) ||
        (0x20000...0x2EBEF).contains(v) || (0xF900...0xFAFF).contains(v) || v == 0x3007
    }

    private static func normalizeWord(_ w: String) -> String {
        w.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
    }

    static func sound(of ch: Character) -> String {
        guard let v = ch.unicodeScalars.first?.value, isHan(v) else { return String(ch) }
        lock.lock()
        if let cached = pinyinCache[ch] { lock.unlock(); return cached }
        lock.unlock()

        let m = NSMutableString(string: String(ch))
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let result = fuzzyPinyin(m as String)

        lock.lock(); pinyinCache[ch] = result; lock.unlock()
        return result
    }

    /// 模糊拼音：zh/ch/sh → z/c/s，-ng → -n，n- → l-。容忍口音和识别器的同音字。
    static func fuzzyPinyin(_ raw: String) -> String {
        var p = String(raw.lowercased().filter { $0.isASCII && $0.isLetter })
        guard !p.isEmpty else { return raw }
        if p.hasPrefix("zh") || p.hasPrefix("ch") || p.hasPrefix("sh") {
            p.remove(at: p.index(after: p.startIndex))
        }
        if p.hasPrefix("n"), !p.hasPrefix("ng") { p = "l" + p.dropFirst() }
        if p.hasSuffix("ng"), p.count > 2 { p.removeLast() }
        return p
    }
}
