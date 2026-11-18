import Foundation

/// 把"刚刚听到的最后若干个字"对齐到稿子上，找出演讲者现在读到哪里。
///
/// 做法：取识别结果末尾 ~12 个字，在当前位置附近的窗口里做局部序列比对
/// （Smith–Waterman 变体，要求比对必须延伸到"最后听到的字"），
/// 匹配分数：字相同 > 读音相同（同音字、平翘舌等）> 不匹配；允许漏读、多读、口头禅。
/// 结果再按与当前位置的距离做惩罚：往前走很便宜，往回跳很贵，避免来回抖动。
struct SpeechAligner {
    let script: [SpeechToken]
    var maxHeard = 12

    static func similarity(_ a: SpeechToken, _ b: SpeechToken) -> Double {
        if a.surface == b.surface { return 2.0 }
        if a.sound == b.sound { return 1.6 }
        let ac = a.surface.utf8.count, bc = b.surface.utf8.count
        if ac >= 4, bc >= 4, a.surface.isASCIIWord, b.surface.isASCIIWord,
           a.surface.prefix(4) == b.surface.prefix(4) {
            return 1.0   // 英文词形变化：present / presenting
        }
        return -1.0
    }

    /// - Parameters:
    ///   - heard: 识别出的文字切分后的 token（只用末尾一段）
    ///   - spoken: 当前已读 token 数
    /// - Returns: 最新读到的 token 下标；无法可靠判断时返回 nil（保持不动）
    func locate(heard allHeard: [SpeechToken], spoken: Int) -> Int? {
        let heard = Array(allHeard.suffix(maxHeard))
        guard heard.count >= 2, !script.isEmpty else { return nil }
        let current = spoken - 1

        let lo = max(0, spoken - 40), hi = min(script.count, spoken + 90)
        if let local = search(heard, lo: lo, hi: hi, current: current),
           accept(local, current: current, heardCount: heard.count) {
            return local.index
        }
        // 窗口内找不到：可能跳读了一大段，用更严格的门槛全文搜索
        if heard.count >= 8, script.count > hi - lo,
           let global = search(heard, lo: 0, hi: script.count, current: current),
           global.score >= 11, abs(global.index - current) > 4 {
            return global.index
        }
        return nil
    }

    private func accept(_ r: (index: Int, score: Double), current: Int, heardCount: Int) -> Bool {
        let minScore = heardCount >= 3 ? 4.6 : 3.6
        guard r.score >= minScore else { return false }
        if r.index < current {
            if current - r.index <= 4 { return false }   // 小幅回退多半是识别结果修正，忽略
            return r.score >= 10                         // 明确在重读前面的内容
        }
        if r.index > current + 45 { return r.score >= 7 }
        return true
    }

    private func search(_ q: [SpeechToken], lo: Int, hi: Int, current: Int) -> (index: Int, score: Double)? {
        let w = hi - lo
        guard w > 0 else { return nil }
        let gapHeard = 0.8    // 听到但稿子里没有（口头禅、识别多出的字）
        let gapScript = 0.6   // 稿子里有但没听到（漏读、识别漏字）

        var prev = [Double](repeating: 0, count: w + 1)
        var cur = prev
        for i in 1...q.count {
            let qi = q[i - 1]
            cur[0] = 0
            for j in 1...w {
                let diag = prev[j - 1] + Self.similarity(qi, script[lo + j - 1])
                let up = prev[j] - gapHeard
                let left = cur[j - 1] - gapScript
                cur[j] = max(0, diag, up, left)
            }
            swap(&prev, &cur)
        }

        var best: (index: Int, score: Double, adjusted: Double)?
        let expected = current + 3
        for j in 1...w where prev[j] > 0 {
            let idx = lo + j - 1
            let d = idx - expected
            let penalty = d >= 0 ? Double(d) * 0.02 : Double(-d) * 0.08
            let adjusted = prev[j] - penalty
            if best == nil || adjusted > best!.adjusted { best = (idx, prev[j], adjusted) }
        }
        return best.map { ($0.index, $0.score) }
    }
}

private extension String {
    var isASCIIWord: Bool { utf8.allSatisfy { $0 < 128 } }
}
