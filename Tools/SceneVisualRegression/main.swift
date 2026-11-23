import CoreGraphics
import CoreText
import Foundation

private struct RankedScene: Encodable {
    let id: String
    let title: String
    let similarity: Double
    let luminanceSSIM: Double
    let rgbMAE: Double
}

private struct SkippedScene: Encodable {
    let id: String
    let title: String
    let reason: String
}

private struct VisualReport: Encodable {
    let renderRunID: UUID
    let time: Float
    let totalScenes: Int
    let ranked: [RankedScene]
    let skipped: [SkippedScene]
}

private enum VisualError: LocalizedError {
    case usage
    case missingRun
    case inputChanged
    case cannotDraw
    case noPairs

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: Tools/test.sh visual [positive N]"
        case .missingRun: "Run Tools/test.sh scenes to generate a set of render and author-preview images first."
        case .inputChanged: "Scene inputs changed during comparison. Run Tools/test.sh visual again after rendering finishes."
        case .cannotDraw: "Could not create the comparison sheet."
        case .noPairs: "No usable render and preview pairs."
        }
    }
}

private func compare(_ run: SceneVisualRun, in directory: URL) -> VisualReport {
    var ranked: [RankedScene] = []
    var skipped: [SkippedScene] = []
    var seen = Set<String>()
    for scene in run.scenes where seen.insert(scene.id).inserted {
        let reason: String
        switch scene.outcome {
        case .renderFailed:
            reason = "renderFailed"
        case .previewUnavailable:
            reason = "previewUnavailable"
        case .ready:
            let metrics = autoreleasepool {
                ImagePair.read(id: scene.id, in: directory)?.compare()
            }
            if let metrics {
                ranked.append(.init(id: scene.id, title: scene.title, similarity: metrics.score,
                                    luminanceSSIM: metrics.luminanceSSIM, rgbMAE: metrics.rgbMAE))
                continue
            }
            reason = "imageMissingOrUnreadable"
        }
        skipped.append(.init(id: scene.id, title: scene.title, reason: reason))
    }
    ranked.sort {
        if $0.similarity == $1.similarity { return $0.id < $1.id }
        return $0.similarity < $1.similarity
    }
    return VisualReport(renderRunID: run.id, time: run.time, totalScenes: seen.count, ranked: ranked, skipped: skipped)
}

private func makeSheet(_ scenes: ArraySlice<RankedScene>, in directory: URL) throws -> CGImage {
    let tile: CGFloat = 200
    let margin: CGFloat = 14
    let rowHeight = tile + 30
    let width = Int(2 * tile + 3 * margin)
    let height = Int(CGFloat(scenes.count) * rowHeight + 56)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: comparisonColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw VisualError.cannotDraw }
    context.setFillColor(gray: 0.96, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high

    let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
    func label(_ text: String, x: CGFloat, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
    func draw(_ image: CGImage, x: CGFloat, y: CGFloat) {
        let scale = min(tile / CGFloat(image.width), tile / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: x, y: y, width: tile, height: tile))
        context.draw(image, in: CGRect(x: x + (tile - w) / 2, y: y + (tile - h) / 2, width: w, height: h))
    }

    let right = 2 * margin + tile
    label("Render (center crop)", x: margin, y: CGFloat(height) - 23)
    label("Author preview", x: right, y: CGFloat(height) - 23)
    for (row, scene) in scenes.enumerated() {
        try autoreleasepool {
            guard let images = ImagePair.read(id: scene.id, in: directory) else { throw VisualError.inputChanged }
            let y = CGFloat(height) - 34 - CGFloat(row + 1) * rowHeight
            label(String(format: "%@   %.1f / 100", scene.id, scene.similarity), x: margin, y: y + tile + 7)
            draw(images.render, x: margin, y: y)
            draw(images.preview, x: right, y: y)
        }
    }
    guard let image = context.makeImage() else { throw VisualError.cannotDraw }
    return image
}

private func run() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let limit = Int(args[3]), limit > 0 else { throw VisualError.usage }
    let scenes = URL(fileURLWithPath: args[1], isDirectory: true)
    let outputRoot = URL(fileURLWithPath: args[2], isDirectory: true)
    let manifest = scenes.appending(path: SceneVisualRun.filename)
    guard FileManager.default.fileExists(atPath: manifest.path) else { throw VisualError.missingRun }

    let manifestData = try Data(contentsOf: manifest)
    let input = try JSONDecoder().decode(SceneVisualRun.self, from: manifestData)
    let report = compare(input, in: scenes)
    let selected = Array(report.ranked.prefix(limit))
    let reportID = UUID().uuidString
    let temporary = outputRoot.appending(path: ".\(reportID)")
    let output = outputRoot.appending(path: reportID)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let perPage = 10
    for start in stride(from: 0, to: selected.count, by: perPage) {
        let page = selected[start..<min(start + perPage, selected.count)]
        try writePNG(makeSheet(page, in: scenes), to: temporary.appending(path: "worst-\(start / perPage + 1).png"))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: temporary.appending(path: "report.json"))
    // A new render invalidates the manifest before replacing any PNGs.
    guard (try? Data(contentsOf: manifest)) == manifestData else { throw VisualError.inputChanged }
    try FileManager.default.moveItem(at: temporary, to: output)

    print("Visual comparison: \(report.ranked.count)/\(report.totalScenes) scored, \(report.skipped.count) skipped")
    for scene in selected {
        let title = scene.title.components(separatedBy: .newlines).joined(separator: " ")
        print(String(format: "%5.1f  %@  %@", scene.similarity, scene.id, title))
    }
    print("Report: \(output.appending(path: "report.json").path)")
    if selected.isEmpty { throw VisualError.noPairs }
    print("Sheets: \(output.path)/worst-*.png")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Visual regression: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
