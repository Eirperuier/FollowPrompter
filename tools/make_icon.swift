// 生成 1024×1024 应用图标：swift tools/make_icon.swift <输出路径>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = CGFloat(size)

// 背景渐变
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1),
    CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

func bar(_ y: CGFloat, _ x0: CGFloat, _ w: CGFloat, _ alpha: CGFloat) {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    let r = CGRect(x: x0, y: y, width: w, height: 56)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.fillPath()
}

// 文字行（坐标系原点在左下）：上方已读变暗，下方未读明亮
bar(760, 200, 624, 0.22)
bar(650, 200, 520, 0.22)
bar(420, 200, 624, 1.0)
bar(310, 200, 560, 1.0)
bar(200, 200, 420, 1.0)

// 阅读线
let ly: CGFloat = 548
ctx.setFillColor(CGColor(red: 1, green: 0.58, blue: 0.0, alpha: 1))
ctx.fill(CGRect(x: 170, y: ly - 7, width: 684, height: 14))
for (x, dir) in [(CGFloat(110), CGFloat(1)), (CGFloat(914), CGFloat(-1))] {
    ctx.move(to: CGPoint(x: x, y: ly + 46))
    ctx.addLine(to: CGPoint(x: x + 70 * dir, y: ly))
    ctx.addLine(to: CGPoint(x: x, y: ly - 46))
    ctx.closePath()
    ctx.fillPath()
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
