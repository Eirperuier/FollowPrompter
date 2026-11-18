import Foundation
import NaturalLanguage

struct SpeechLanguage: Identifiable {
    let id: String
    let name: String

    /// 设置里的"自动"：跟随稿件语言
    static let automatic = "auto"

    static let all: [SpeechLanguage] = [
        .init(id: "zh-CN", name: "普通话（中国大陆）"),
        .init(id: "zh-TW", name: "國語（台灣）"),
        .init(id: "zh-HK", name: "粵語（香港）"),
        .init(id: "en-US", name: "English (US)"),
        .init(id: "en-GB", name: "English (UK)"),
        .init(id: "ja-JP", name: "日本語"),
    ]

    static func name(of id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }

    static func shortName(of id: String) -> String {
        switch id {
        case "zh-CN": "普通话"
        case "zh-TW": "國語"
        case "zh-HK": "粵語"
        case "en-GB": "English UK"
        case "ja-JP": "日本語"
        default: id.hasPrefix("en") ? "English" : id
        }
    }

    /// 设置值 → 实际使用的识别语言
    static func resolve(_ setting: String, text: String) -> String {
        setting == automatic ? detect(text) : setting
    }

    /// 根据稿件文字判断朗读语言。
    /// 演讲者念的就是稿子，所以稿子的语言就是要识别的语言；中英混排以占多数的为准。
    static func detect(_ text: String) -> String {
        let sample = String(text.prefix(4000))
        // 有假名就是日文（日文汉字多时 NLLanguageRecognizer 偶尔会判成中文）
        let kana = sample.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) }.count
        if kana >= 5 { return "ja-JP" }

        // 按念出来的时长比较：一个汉字约一个音节，一个英文单词约一个半音节。
        // （NLLanguageRecognizer 遇到中英混排容易被英文单词带偏，只用它分简繁）
        let cjk = sample.filter { Tokenizer.isIdeographic($0) }.count
        let latinWords = sample.split { !($0.isASCII && $0.isLetter) }.count
        if cjk == 0 && latinWords == 0 { return fallback }
        if Double(cjk) < Double(latinWords) * 1.5 {
            return Locale.current.region?.identifier == "GB" ? "en-GB" : "en-US"
        }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        r.processString(sample)
        return r.dominantLanguage == .traditionalChinese ? "zh-TW" : "zh-CN"
    }

    /// 稿子是空的或判断不出来时，按系统语言
    private static var fallback: String {
        let preferred = Locale.preferredLanguages.first ?? "zh-CN"
        if preferred.hasPrefix("zh-Hant") { return "zh-TW" }
        if preferred.hasPrefix("zh") { return "zh-CN" }
        if preferred.hasPrefix("ja") { return "ja-JP" }
        if preferred.hasPrefix("en") { return "en-US" }
        return "zh-CN"
    }
}
