import AppKit
import CoreGraphics
import CoreText

// 生成 Amoo Bridge 应用图标：渐变圆角方底 + Mac/手机线稿 + 中间的桥接弧线 + 底部 AMOO 字样。
// 主体按 macOS 规范缩在 1024 画布的 824×824 内（四周各留 100px 透明边），
// 保证在 Dock / Finder 中与系统其它 App 图标视觉大小一致。
// 每个尺寸独立按矢量比例绘制，避免位图缩放发虚。
// 用法：make_icon <输出 iconset 目录>

func render(size: CGFloat) -> CGImage? {
    // macOS 图标规范：1024 画布内主体只占 824×824，四周各留 100px 透明边。
    // 铺满画布会在 Dock / Finder 里比系统其它 App 的图标大一号。
    let contentScale: CGFloat = 824.0 / 1024.0
    let inset = size * (1 - contentScale) / 2
    let s = (size * contentScale) / 1024
    let side = 1024 * s
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.translateBy(x: inset, y: inset)

    // macOS 风格圆角外形，四角透明
    let outer = CGRect(x: 0, y: 0, width: side, height: side)
    let radius: CGFloat = 230 * s
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    // 蓝紫对角渐变
    let colors = [
        CGColor(red: 0.13, green: 0.40, blue: 0.95, alpha: 1),
        CGColor(red: 0.47, green: 0.25, blue: 0.88, alpha: 1)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: side),
                               end: CGPoint(x: side, y: 0),
                               options: [])
    }

    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.setStrokeColor(white)
    ctx.setFillColor(white)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(34 * s)

    func strokeRound(_ r: CGRect, _ corner: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner * s,
                           cornerHeight: corner * s, transform: nil))
        ctx.strokePath()
    }
    func fillRound(_ r: CGRect, _ corner: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner * s,
                           cornerHeight: corner * s, transform: nil))
        ctx.fillPath()
    }

    // 左：Mac 显示器
    strokeRound(CGRect(x: 150 * s, y: 500 * s, width: 250 * s, height: 200 * s), 24)
    // 支架与底座
    fillRound(CGRect(x: 255 * s, y: 455 * s, width: 40 * s, height: 48 * s), 8)
    fillRound(CGRect(x: 210 * s, y: 440 * s, width: 130 * s, height: 18 * s), 9)

    // 右：手机
    strokeRound(CGRect(x: 624 * s, y: 390 * s, width: 170 * s, height: 330 * s), 32)
    fillRound(CGRect(x: 685 * s, y: 412 * s, width: 48 * s, height: 12 * s), 6)

    // 中间：向上拱起的桥接线
    ctx.setLineWidth(30 * s)
    ctx.move(to: CGPoint(x: 400 * s, y: 548 * s))
    ctx.addQuadCurve(to: CGPoint(x: 624 * s, y: 548 * s),
                     control: CGPoint(x: 512 * s, y: 636 * s))
    ctx.strokePath()

    // 两端连接点
    for x in [400, 624] as [CGFloat] {
        ctx.fillEllipse(in: CGRect(x: (x - 20) * s, y: 528 * s,
                                   width: 40 * s, height: 40 * s))
    }

    // 底部 AMOO 字样（白色粗体、略拉字距、水平居中）
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 118 * s, nil)
    let tracking: CGFloat = 18 * s
    let textAttrs = [kCTFontAttributeName as String: font,
                     kCTForegroundColorAttributeName as String: white,
                     kCTKernAttributeName as String: tracking] as CFDictionary
    if let text = CFAttributedStringCreate(kCFAllocatorDefault, "AMOO" as CFString, textAttrs) {
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        // 字距会计入末尾一份，居中时补回半个字距
        let x = (side - bounds.width) / 2 - bounds.origin.x + tracking / 2
        ctx.textPosition = CGPoint(x: x, y: 168 * s)
        CTLineDraw(line, ctx)
    }

    return ctx.makeImage()
}

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("用法：make_icon <输出 iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for item in sizes {
    guard let image = render(size: item.px) else {
        FileHandle.standardError.write("渲染失败：\(item.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG 编码失败：\(item.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(item.name))
}
print("已生成 \(sizes.count) 个尺寸的图标到 \(outDir.path)")
