import SwiftUI
import UIKit

struct PrompterStyle: Equatable {
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var sideMargin: CGFloat
    var dimRead: Bool
}

/// 提词正文。用 TextKit 1 精确算出"第 N 个字"在屏幕上的位置，
/// 再用 CADisplayLink 把滚动位置平滑地追向目标，读到一行中间时也会按比例连续滚动。
struct PrompterTextView: UIViewRepresentable {
    var text: String
    var tokens: [SpeechToken]
    var spoken: Int
    var revision: Int
    var style: PrompterStyle
    /// 阅读线位置（占视图高度比例）
    var readingLine: CGFloat
    var mirrorH: Bool
    var mirrorV: Bool
    /// 匀速模式下的滚动速度（点/秒），非匀速时为 nil
    var autoSpeed: CGFloat?
    /// 跟读模式：识别结果一批一批到达，显示时按语速逐字点亮，而不是整批跳过去
    var smoothReveal: Bool = false
    /// 手动跳转计数，变化时直接到位、不逐字
    var jumps: Int = 0
    /// 当前语速（token/分钟），0 表示还没估出来
    var paceRate: Double = 0
    var onUserMove: (Int) -> Void
    var onAutoProgress: (Int) -> Void
    var onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PrompterContainerView {
        let view = PrompterContainerView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PrompterContainerView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: PrompterContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

/// 外层容器：镜像变换作用在内部 UITextView 上，避免和 SwiftUI 布局的 frame 冲突。
final class PrompterContainerView: UIView {
    let textView = UITextView(usingTextLayoutManager: false)
    var onSizeChange: (() -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.bounds = CGRect(origin: textView.bounds.origin, size: bounds.size)
        textView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if bounds.size != lastSize {
            lastSize = bounds.size
            onSizeChange?()
        }
    }
}

private final class DisplayLinkProxy: NSObject {
    weak var owner: PrompterTextView.Coordinator?
    init(_ owner: PrompterTextView.Coordinator) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

extension PrompterTextView {
    final class Coordinator: NSObject, UITextViewDelegate {
        private weak var container: PrompterContainerView?
        private var textView: UITextView? { container?.textView }
        private var config: PrompterTextView?
        private var link: CADisplayLink?
        private var lastTick: CFTimeInterval = 0
        private var lastAutoReport: CFTimeInterval = 0
        private var targetOffset: CGFloat?
        private var appliedText: String?
        private var appliedStyle: PrompterStyle?
        private var appliedRevision = Int.min
        private var appliedReadingLine: CGFloat = -1
        private var dimEnd = 0
        private var isDragging = false
        /// 屏幕上显示到的位置（可带小数）。跟读时逐字追赶 config.spoken
        private var shown: Double = 0
        private var appliedJumps = 0

        private let normalColor = UIColor.white
        private var dimColor: UIColor {
            (config?.style.dimRead ?? true) ? UIColor(white: 1, alpha: 0.3) : normalColor
        }

        // MARK: 生命周期

        func attach(to view: PrompterContainerView) {
            container = view
            let tv = view.textView
            tv.isEditable = false
            tv.isSelectable = false
            tv.backgroundColor = .black
            tv.showsVerticalScrollIndicator = false
            tv.contentInsetAdjustmentBehavior = .never
            tv.alwaysBounceVertical = true
            tv.delegate = self
            tv.layoutManager.allowsNonContiguousLayout = false
            tv.textContainer.lineFragmentPadding = 0

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            tv.addGestureRecognizer(doubleTap)
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.require(toFail: doubleTap)
            tv.addGestureRecognizer(singleTap)

            view.onSizeChange = { [weak self] in self?.sizeChanged() }

            let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func detach() {
            link?.invalidate()
            link = nil
        }

        func update(_ cfg: PrompterTextView) {
            config = cfg
            guard let tv = textView else { return }

            var needsSnap = false
            if cfg.text != appliedText || cfg.style != appliedStyle {
                applyText(cfg, to: tv)
                needsSnap = true
            }

            let t = CGAffineTransform(scaleX: cfg.mirrorH ? -1 : 1, y: cfg.mirrorV ? -1 : 1)
            if tv.transform != t { tv.transform = t }

            var needsRetarget = false
            if cfg.readingLine != appliedReadingLine {
                appliedReadingLine = cfg.readingLine
                updateInsets()
                needsRetarget = true
            }

            if needsSnap {
                snap()
                return
            }
            let target = Double(cfg.spoken)
            let gap = target - shown
            // 不逐字的情况：非跟读模式、往回跳（重读、拖动）、一下跳很远（下一段、全文找回）
            let jumped = cfg.jumps != appliedJumps
            appliedJumps = cfg.jumps
            if !cfg.smoothReveal || jumped || gap < 0 || gap > 24 {
                shown = target
                applyDim(cfg.spoken)
            }
            if cfg.revision != appliedRevision || needsRetarget {
                appliedRevision = cfg.revision
                targetOffset = offset(forShown: shown)
            }
        }

        // MARK: 文本与样式

        private func applyText(_ cfg: PrompterTextView, to tv: UITextView) {
            let style = cfg.style
            let para = NSMutableParagraphStyle()
            para.lineSpacing = max(0, style.fontSize * (style.lineSpacing - 1))
            para.paragraphSpacing = style.fontSize * 0.6
            let font = UIFont.systemFont(ofSize: style.fontSize, weight: .semibold)
            tv.attributedText = NSAttributedString(string: cfg.text, attributes: [
                .font: font,
                .foregroundColor: normalColor,
                .paragraphStyle: para,
            ])
            tv.textContainerInset = UIEdgeInsets(top: 0, left: style.sideMargin, bottom: 0, right: style.sideMargin)
            dimEnd = 0
            appliedText = cfg.text
            appliedStyle = style
            tv.layoutManager.ensureLayout(for: tv.textContainer)
        }

        private func applyDim(_ spoken: Int) {
            guard let tv = textView, let tokens = config?.tokens else { return }
            let length = tv.textStorage.length
            let end = spoken <= 0 || tokens.isEmpty ? 0
                : min(tokens[min(spoken, tokens.count) - 1].range.upperBound, length)
            guard end != dimEnd else { return }
            let storage = tv.textStorage
            storage.beginEditing()
            if end > dimEnd {
                storage.addAttribute(.foregroundColor, value: dimColor, range: NSRange(location: dimEnd, length: end - dimEnd))
            } else {
                storage.addAttribute(.foregroundColor, value: normalColor, range: NSRange(location: end, length: dimEnd - end))
            }
            storage.endEditing()
            dimEnd = end
        }

        // MARK: 几何

        private var readingY: CGFloat {
            guard let tv = textView else { return 0 }
            return tv.bounds.height * (config?.readingLine ?? 0.35)
        }

        private func updateInsets() {
            guard let tv = textView else { return }
            let h = tv.bounds.height
            let r = config?.readingLine ?? 0.35
            tv.contentInset = UIEdgeInsets(top: h * r, left: 0, bottom: h * (1 - r), right: 0)
        }

        private func sizeChanged() {
            guard let tv = textView, tv.bounds.height > 0 else { return }
            updateInsets()
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            snap()
        }

        private func snap() {
            guard let tv = textView, let cfg = config, tv.bounds.height > 0 else { return }
            appliedRevision = cfg.revision
            shown = Double(cfg.spoken)
            applyDim(cfg.spoken)
            let o = offset(forSpoken: cfg.spoken)
            targetOffset = o
            tv.contentOffset = CGPoint(x: tv.contentOffset.x, y: o)
        }

        private var contentHeight: CGFloat {
            guard let tv = textView else { return 0 }
            return tv.layoutManager.usedRect(for: tv.textContainer).height + tv.textContainerInset.top + tv.textContainerInset.bottom
        }

        private func clampOffset(_ y: CGFloat) -> CGFloat {
            guard let tv = textView else { return y }
            let minY = -tv.contentInset.top
            let maxY = max(minY, contentHeight + tv.contentInset.bottom - tv.bounds.height)
            return min(max(y, minY), maxY)
        }

        /// 让"刚读完的位置"落在阅读线上所需的 contentOffset.y
        private func offset(forSpoken s: Int) -> CGFloat {
            clampOffset(contentY(forSpoken: s) - readingY)
        }

        /// 带小数的位置：在第 i 和 i+1 个字之间按比例插值
        private func offset(forShown s: Double) -> CGFloat {
            let i = Int(s.rounded(.down))
            let f = CGFloat(s - Double(i))
            let y0 = contentY(forSpoken: i)
            guard f > 0.01, let n = config?.tokens.count, i < n else { return clampOffset(y0 - readingY) }
            let y1 = contentY(forSpoken: i + 1)
            return clampOffset(y0 + (y1 - y0) * f - readingY)
        }

        private func contentY(forSpoken s: Int) -> CGFloat {
            guard let tv = textView, let tokens = config?.tokens, !tokens.isEmpty else { return 0 }
            let lm = tv.layoutManager, tc = tv.textContainer
            guard lm.numberOfGlyphs > 0 else { return 0 }
            let inset = tv.textContainerInset.top
            if s <= 0 {
                let g = lm.glyphIndexForCharacter(at: tokens[0].range.location)
                return inset + lm.lineFragmentRect(forGlyphAt: min(g, lm.numberOfGlyphs - 1), effectiveRange: nil).minY
            }
            let tok = tokens[min(s, tokens.count) - 1]
            let gr = lm.glyphRange(forCharacterRange: tok.range, actualCharacterRange: nil)
            guard gr.location < lm.numberOfGlyphs else { return contentHeight }
            let line = lm.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let used = lm.lineFragmentUsedRect(forGlyphAt: gr.location, effectiveRange: nil)
            let glyph = lm.boundingRect(forGlyphRange: gr, in: tc)
            let frac = used.width > 1 ? min(max((glyph.maxX - used.minX) / used.width, 0), 1) : 1
            return inset + line.minY + frac * line.height
        }

        /// contentY(forSpoken:) 的反函数：阅读线处对应已读多少 token
        private func spoken(atContentY y: CGFloat) -> Int {
            guard let tv = textView else { return 0 }
            let lm = tv.layoutManager, tc = tv.textContainer
            guard lm.numberOfGlyphs > 0 else { return 0 }
            let cy = y - tv.textContainerInset.top
            if cy <= 0 { return 0 }
            if cy >= lm.usedRect(for: tc).maxY { return config?.tokens.count ?? 0 }
            let g0 = lm.glyphIndex(for: CGPoint(x: 1, y: cy), in: tc)
            let line = lm.lineFragmentRect(forGlyphAt: g0, effectiveRange: nil)
            let used = lm.lineFragmentUsedRect(forGlyphAt: g0, effectiveRange: nil)
            let frac = line.height > 0 ? min(max((cy - line.minY) / line.height, 0), 1) : 0
            let x = used.minX + frac * used.width
            return spoken(atContainerPoint: CGPoint(x: x, y: line.midY))
        }

        private func spoken(atContainerPoint p: CGPoint) -> Int {
            guard let tv = textView, let tokens = config?.tokens, !tokens.isEmpty else { return 0 }
            let lm = tv.layoutManager
            let g = lm.glyphIndex(for: p, in: tv.textContainer)
            let ch = lm.characterIndexForGlyph(at: g)
            // 第一个"结束位置在 ch 之后"的 token 即为将要读的字
            var lo = 0, hi = tokens.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tokens[mid].range.upperBound <= ch { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        // MARK: 动画

        func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            let dt = lastTick == 0 ? 1.0 / 60 : min(max(now - lastTick, 0), 0.1)
            lastTick = now
            guard let tv = textView, let cfg = config, tv.bounds.height > 0,
                  !isDragging, !tv.isDecelerating else { return }

            if let speed = cfg.autoSpeed, speed > 0 {
                let base = targetOffset ?? tv.contentOffset.y
                let next = clampOffset(base + speed * CGFloat(dt))
                targetOffset = next
                tv.contentOffset = CGPoint(x: tv.contentOffset.x, y: next)
                if now - lastAutoReport > 0.2 {
                    lastAutoReport = now
                    cfg.onAutoProgress(spoken(atContentY: next + readingY))
                }
                return
            }

            // 逐字追赶：平时按语速前进；落后越多走得越快，所以不会越积越多
            let goal = Double(cfg.spoken)
            if cfg.smoothReveal, shown < goal {
                let base = max(cfg.paceRate / 60, 3)          // 还没估出语速时按每秒 3 个字
                let speed = base * (1 + max(0, goal - shown - 1.5) * 0.6)
                shown = min(goal, shown + speed * dt)
                applyDim(Int(shown.rounded(.down)))
                targetOffset = offset(forShown: shown)
            }

            guard let target = targetOffset else { return }
            let cur = tv.contentOffset.y
            let diff = target - cur
            if abs(diff) < 0.25 {
                if diff != 0 { tv.contentOffset = CGPoint(x: tv.contentOffset.x, y: target) }
                return
            }
            // 指数缓动：跟得上语速，又不会一跳一跳
            let tau = abs(diff) > tv.bounds.height ? 0.18 : (cfg.smoothReveal ? 0.15 : 0.32)
            let k = CGFloat(1 - exp(-dt / tau))
            tv.contentOffset = CGPoint(x: tv.contentOffset.x, y: cur + diff * k)
        }

        // MARK: 交互

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isDragging = true
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishUserScroll() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll()
        }

        private func finishUserScroll() {
            guard let tv = textView, let cfg = config else { return }
            isDragging = false
            targetOffset = tv.contentOffset.y
            cfg.onUserMove(spoken(atContentY: tv.contentOffset.y + readingY))
        }

        @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
            config?.onSingleTap()
        }

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let tv = textView, let cfg = config else { return }
            let p = g.location(in: tv)
            let s = spoken(atContainerPoint: CGPoint(x: p.x - tv.textContainerInset.left,
                                                     y: p.y - tv.textContainerInset.top))
            cfg.onUserMove(s)
        }
    }
}
