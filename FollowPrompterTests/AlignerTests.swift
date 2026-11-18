import XCTest
@testable import FollowPrompter

final class AlignerTests: XCTestCase {
    let script = """
    大家好，今天我想和大家聊一聊提词器。一个好的提词器应该跟着演讲者的语速移动，说得快它就快，说得慢它就慢，停下来它也停下来。
    为了做到这一点，我们需要实时识别演讲者说的话，然后在稿子里找到对应的位置。识别结果常常会有同音字，比如把“语速”听成“雨速”，所以我们用拼音来比较。
    最后，我们还要处理跳读的情况：演讲者可能突然跳过一整段，直接开始讲后面的内容，系统应该能够重新找到位置，而不是卡在原地不动。
    """

    func testTokenizerMixed() {
        let t = Tokenizer.tokenize("Hello, 世界 2024年! Don't")
        XCTAssertEqual(t.map(\.surface), ["hello", "世", "界", "2024", "年", "dont"])
        let ns = "Hello, 世界 2024年! Don't" as NSString
        XCTAssertEqual(ns.substring(with: t[3].range), "2024")
        XCTAssertEqual(ns.substring(with: t[5].range), "Don't")
    }

    func testFuzzyPinyin() {
        XCTAssertEqual(Tokenizer.sound(of: "语"), Tokenizer.sound(of: "雨"))
        XCTAssertEqual(Tokenizer.sound(of: "是"), Tokenizer.sound(of: "四"))   // 平翘舌
        XCTAssertEqual(Tokenizer.sound(of: "能"), Tokenizer.sound(of: "棱"))   // n/l、前后鼻音
        XCTAssertNotEqual(Tokenizer.sound(of: "大"), Tokenizer.sound(of: "家"))
    }

    /// 模拟识别器逐渐吐出文字，位置应当紧跟
    func testFollowsProgressively() {
        let tokens = Tokenizer.tokenize(script)
        let aligner = SpeechAligner(script: tokens)
        var spoken = 0
        var heard = ""
        for (i, tok) in tokens.enumerated() {
            heard += tok.surface
            guard i % 3 == 2 || i == tokens.count - 1 else { continue }
            if let idx = aligner.locate(heard: Tokenizer.tokenize(heard), spoken: spoken) { spoken = idx + 1 }
            XCTAssertGreaterThanOrEqual(spoken, i + 1 - 2, "落后太多 at \(i)")
            XCTAssertLessThanOrEqual(spoken, i + 1, "超前 at \(i)")
        }
        XCTAssertEqual(spoken, tokens.count)
    }

    /// 同音错字 + 口头禅 + 漏字
    func testNoisyRecognition() {
        let tokens = Tokenizer.tokenize(script)
        let aligner = SpeechAligner(script: tokens)
        let noisy = "大家好嗯今天我象和大家聊聊题词器那个一个好的提词器应该跟着演讲者的雨速移动"
        var spoken = 0
        var heard = ""
        for ch in noisy {
            heard.append(ch)
            if let idx = aligner.locate(heard: Tokenizer.tokenize(heard), spoken: spoken) { spoken = idx + 1 }
        }
        let target = tokens.firstIndex { $0.surface == "动" }!  // “移动”的“动”
        XCTAssertEqual(spoken, target + 1)
    }

    /// 跳过一整段
    func testJumpAhead() {
        let tokens = Tokenizer.tokenize(script)
        let aligner = SpeechAligner(script: tokens)
        let heard = Tokenizer.tokenize("演讲者可能突然跳过一整段直接开始讲后面的内容")
        let idx = aligner.locate(heard: heard, spoken: 10)
        let expected = tokens.indices.first { i in
            tokens[i].surface == "容" && tokens[i - 1].surface == "内"
        }!
        XCTAssertEqual(idx, expected)
    }

    /// 识别结果的小幅回退不应让提词往回跳
    func testSmallBackwardIgnored() {
        let tokens = Tokenizer.tokenize(script)
        let aligner = SpeechAligner(script: tokens)
        let heard = Tokenizer.tokenize("今天我想和大家聊一聊")
        let end = tokens.firstIndex { $0.surface == "器" }!   // 已读到“提词器”
        XCTAssertNil(aligner.locate(heard: heard, spoken: end + 1))
    }

    /// 明确地重读前面一段，应当回去
    func testDeliberateReread() {
        let tokens = Tokenizer.tokenize(script)
        let aligner = SpeechAligner(script: tokens)
        let heard = Tokenizer.tokenize("说得快它就快说得慢它就慢")
        let idx = aligner.locate(heard: heard, spoken: 120)
        let expected = tokens.indices.first { i in
            i > 0 && tokens[i].surface == "慢" && tokens[i - 1].surface == "就"
        }!
        XCTAssertEqual(idx, expected)
    }

    func testEnglishScript() {
        let text = "Good morning everyone. Today I want to talk about how a teleprompter can follow the speaker's pace."
        let tokens = Tokenizer.tokenize(text)
        let aligner = SpeechAligner(script: tokens)
        let idx = aligner.locate(heard: Tokenizer.tokenize("today I want to talk about how a teleprompter"), spoken: 3)
        XCTAssertEqual(idx.map { tokens[$0].surface }, "teleprompter")
    }

    func testSilenceDoesNotMove() {
        let tokens = Tokenizer.tokenize(script)
        let aligner = SpeechAligner(script: tokens)
        XCTAssertNil(aligner.locate(heard: Tokenizer.tokenize("嗯"), spoken: 5))
        XCTAssertNil(aligner.locate(heard: Tokenizer.tokenize("今天天气不错啊"), spoken: 5))
    }
}

@MainActor
final class NavigationTests: XCTestCase {
    let text = "第一句话在这里。第二句话也在这里！第三句。\n第二段第一句。第二段第二句？"

    func testBoundaries() {
        let t = PromptTracker(text: text)
        XCTAssertEqual(t.sentenceStarts.count, 5)
        XCTAssertEqual(t.paragraphStarts.count, 2)
        XCTAssertEqual(t.sentenceText(), "第一句话在这里。")
        XCTAssertEqual(t.sentenceText(offset: 1), "第二句话也在这里！")
    }

    func testRereadSentenceAndRepeatedPresses() {
        let t = PromptTracker(text: text)
        let s2 = t.sentenceStarts[1]
        t.jump(to: s2 + 4)                 // 读到第二句中间
        t.restartSentence()
        XCTAssertEqual(t.spoken, s2)       // 回到第二句开头
        t.restartSentence()
        XCTAssertEqual(t.spoken, 0)        // 连按：再退一句
        t.restartSentence()
        XCTAssertEqual(t.spoken, 0)        // 已在开头，不再变化
    }

    func testRereadParagraph() {
        let t = PromptTracker(text: text)
        let p2 = t.paragraphStarts[1]
        t.jump(to: t.sentenceStarts[4] + 2)
        t.restartParagraph()
        XCTAssertEqual(t.spoken, p2)
    }

    func testPrevNextSentence() {
        let t = PromptTracker(text: text)
        t.nextSentence()
        XCTAssertEqual(t.spoken, t.sentenceStarts[1])
        t.nextSentence(); t.nextSentence()
        XCTAssertEqual(t.spoken, t.sentenceStarts[3])
        XCTAssertEqual(t.sentenceText(), "第二段第一句。")
        t.previousSentence()
        XCTAssertEqual(t.spoken, t.sentenceStarts[2])
    }

    func testRemoteMessageRoundTrip() throws {
        let status = RemoteStatus(title: "稿", mode: "voice", running: true, countdown: nil, listening: true,
                                  progress: 0.5, elapsed: 61, current: "当前句", next: "下一句", rereadCount: 2, autoSpeed: 60)
        for msg in [RemoteMessage.command(.rereadSentence), .status(status)] {
            let data = try JSONEncoder().encode(msg)
            XCTAssertEqual(try JSONDecoder().decode(RemoteMessage.self, from: data), msg)
        }
    }
}

final class FeishuTests: XCTestCase {
    func testParseLinks() {
        let docx = FeishuClient.parse("https://abc.feishu.cn/docx/AbCdEf1234567890xyz?from=from_copylink")
        XCTAssertEqual(docx, .init(apiBase: "https://open.feishu.cn", kind: .docx, token: "AbCdEf1234567890xyz"))

        let wiki = FeishuClient.parse("  https://abc.feishu.cn/wiki/Wk12345678ABCDEFG  ")
        XCTAssertEqual(wiki?.kind, .wiki)
        XCTAssertEqual(wiki?.token, "Wk12345678ABCDEFG")

        let lark = FeishuClient.parse("https://xyz.larksuite.com/docx/LarkToken123456")
        XCTAssertEqual(lark?.apiBase, "https://open.larksuite.com")

        XCTAssertEqual(FeishuClient.parse("https://abc.feishu.cn/docs/doccnABCDEFGH123")?.kind, .legacyDoc)
        XCTAssertNil(FeishuClient.parse("https://abc.feishu.cn/drive/home/"))
        XCTAssertNil(FeishuClient.parse("随便一段文字"))
    }

    func testCleanContent() {
        let raw = "\n开场稿\n大家好。\n\n\n\n今天聊提词器。\n\n"
        XCTAssertEqual(FeishuClient.clean(raw, title: "开场稿"), "大家好。\n\n今天聊提词器。")
        XCTAssertEqual(FeishuClient.clean("第一段\n第二段", title: "别的标题"), "第一段\n第二段")
        XCTAssertEqual(FeishuClient.clean("说明\nimage.png\n\n下一段\n截图 2024.PNG\nv1.5", title: ""),
                       "说明\n\n下一段\n截图 2024.PNG\nv1.5")
    }

    func testOldScriptsStillDecode() throws {
        let old = #"[{"id":"7F0E1D2C-3B4A-5968-7766-554433221100","title":"旧稿","body":"内容","updatedAt":700000000}]"#
        let scripts = try JSONDecoder().decode([Script].self, from: Data(old.utf8))
        XCTAssertEqual(scripts.first?.title, "旧稿")
        XCTAssertFalse(scripts.first!.isLinked)
    }
}

final class FeishuScopeTests: XCTestCase {
    func testJWTScopeParsing() {
        let payload = #"{"scope":"docx:document:readonly search:docs:read","exp":1}"#
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(FeishuAccount.jwtScope("eyJhbGciOiJIUzI1NiJ9.\(b64).sig"), "docx:document:readonly search:docs:read")
        XCTAssertNil(FeishuAccount.jwtScope("not-a-jwt"))
    }
}

final class FeishuLogoTests: XCTestCase {
    func testLogoAssetLoadsAndMenuIconRenders() {
        XCTAssertNotNil(UIImage(named: "FeishuLogo"))
        let icon = UIImage.feishuMenuIcon
        XCTAssertEqual(icon.size, CGSize(width: 22, height: 22))
        XCTAssertEqual(icon.renderingMode, .alwaysOriginal)
    }
}

final class VocabularyTests: XCTestCase {
    func testTermsPickProperNounsAndLongWords() {
        let terms = ScriptVocabulary.terms(from: "今天用 iPad 演示随声提词。提词器会跟着语速走，2024年发布，支持 AI。提词器很好用。随声提词免费。")
        XCTAssertTrue(terms.contains("iPad"))
        XCTAssertTrue(terms.contains("AI"))
        XCTAssertTrue(terms.contains("提词器"))      // 系统分词拆成了单字，靠重复出现拼回来
        XCTAssertTrue(terms.contains("随声提词"))
        XCTAssertFalse(terms.contains("随声提"))     // 只保留最长的
        XCTAssertFalse(terms.contains("器很好"))     // 偶然拼在一起的不算
        XCTAssertFalse(terms.contains("今天"))       // 两个字的常用词不提示
        XCTAssertEqual(Array(terms.prefix(2)), ["随声提词", "提词器"])   // 出现次数多的排前面
    }
}

final class LanguageDetectionTests: XCTestCase {
    func testDetectsScriptLanguage() {
        XCTAssertEqual(SpeechLanguage.detect("大家好，今天给大家介绍一下我们新做的提词器，它会跟着你的语速滚动。"), "zh-CN")
        XCTAssertEqual(SpeechLanguage.detect("大家好，今天給大家介紹一下我們新做的提詞器，它會跟著你的語速滾動。"), "zh-TW")
        XCTAssertEqual(SpeechLanguage.detect("みなさん、こんにちは。今日は新しいプロンプターを紹介します。"), "ja-JP")
        XCTAssertTrue(SpeechLanguage.detect("Hello everyone, today I want to show you a teleprompter that follows your voice.").hasPrefix("en"))
        // 中文为主、夹英文词
        XCTAssertEqual(SpeechLanguage.detect("今天用 iPad 和 AirPods 演示一下，Apple Intelligence 的新功能非常好用，大家可以试试看。"), "zh-CN")
    }

    func testAutomaticResolvesFromTextManualKeepsSetting() {
        XCTAssertEqual(SpeechLanguage.resolve("auto", text: "Good morning and welcome to the show."), SpeechLanguage.detect("Good morning and welcome to the show."))
        XCTAssertEqual(SpeechLanguage.resolve("zh-HK", text: "Good morning"), "zh-HK")
    }
}
