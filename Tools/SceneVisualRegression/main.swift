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

private struct ChangedScene: Encodable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let changedPixels: Int
    let changedPixelPercent: Double
    let meanRGBDifference: Double
}

private struct RenderDiffReport: Encodable {
    let beforeRunID: UUID
    let afterRunID: UUID
    let time: Float
    let totalScenes: Int
    let ranked: [ChangedScene]
    let skipped: [SkippedScene]
}

private struct RunInput {
    let directory: URL
    let manifest: URL
    let data: Data
    let run: SceneVisualRun

    init(_ path: String) throws {
        directory = URL(fileURLWithPath: path, isDirectory: true)
        manifest = directory.appending(path: SceneVisualRun.filename)
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw VisualError.missingRun }
        data = try Data(contentsOf: manifest)
        run = try JSONDecoder().decode(SceneVisualRun.self, from: data)
    }

    func checkUnchanged() throws {
        // A new render invalidates the manifest before replacing any PNGs.
        guard (try? Data(contentsOf: manifest)) == data else { throw VisualError.inputChanged }
    }
}

private enum VisualError: LocalizedError {
    case usage
    case missingRun
    case inputChanged
    case cannotDraw
    case differentRenderTimes
    case noPairs

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: Tools/test.sh visual [positive N] | visual diff <before-scenes> <after-scenes> [positive N]"
        case .missingRun: "Each input must be a saved Tools/test.sh scenes output directory containing visual-inputs.json."
        case .inputChanged: "Scene inputs changed during comparison. Run Tools/test.sh visual again after rendering finishes."
        case .cannotDraw: "Could not create the comparison sheet."
        case .noPairs: "No usable image pairs."
        case .differentRenderTimes: "The render batches use different scene times. Render both at the same time before comparing."
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

private func compareRenders(before: RunInput, after: RunInput) -> RenderDiffReport {
    let first = Dictionary(before.run.scenes.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
    let second = Dictionary(after.run.scenes.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
    let ids = Set(first.keys).union(second.keys)
    var ranked: [ChangedScene] = []
    var skipped: [SkippedScene] = []
    for id in ids.sorted() {
        let title = second[id]?.title ?? first[id]?.title ?? id
        let reason: String? = autoreleasepool {
            guard let beforeScene = first[id] else { return "missingBefore" }
            guard let afterScene = second[id] else { return "missingAfter" }
            guard beforeScene.outcome != .renderFailed else { return "beforeRenderFailed" }
            guard afterScene.outcome != .renderFailed else { return "afterRenderFailed" }
            guard let a = readSceneImage(id, in: before.directory),
                  let b = readSceneImage(id, in: after.directory) else { return "imageMissingOrUnreadable" }
            guard a.width == b.width, a.height == b.height else { return "imageSizeMismatch" }
            guard let difference = RenderDifference(before: a, after: b) else { return "imageMissingOrUnreadable" }
            ranked.append(.init(id: id, title: title, width: difference.width, height: difference.height,
                                changedPixels: difference.changedPixels, changedPixelPercent: difference.changedPixelPercent,
                                meanRGBDifference: difference.meanRGBDifference))
            return nil
        }
        if let reason { skipped.append(.init(id: id, title: title, reason: reason)) }
    }
    ranked.sort {
        if $0.meanRGBDifference == $1.meanRGBDifference { return $0.id < $1.id }
        return $0.meanRGBDifference > $1.meanRGBDifference
    }
    return RenderDiffReport(beforeRunID: before.run.id, afterRunID: after.run.id, time: after.run.time,
                            totalScenes: ids.count, ranked: ranked, skipped: skipped)
}

private func makeSheet<Row>(_ rows: ArraySlice<Row>, headings: (String, String),
                            read: (Row) throws -> (label: String, left: CGImage, right: CGImage)) throws -> CGImage {
    let tile: CGFloat = 200
    let margin: CGFloat = 14
    let rowHeight = tile + 30
    let width = Int(2 * tile + 3 * margin)
    let height = Int(CGFloat(rows.count) * rowHeight + 56)
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
    label(headings.0, x: margin, y: CGFloat(height) - 23)
    label(headings.1, x: right, y: CGFloat(height) - 23)
    for (row, entry) in rows.enumerated() {
        try autoreleasepool {
            let images = try read(entry)
            let y = CGFloat(height) - 34 - CGFloat(row + 1) * rowHeight
            label(images.label, x: margin, y: y + tile + 7)
            draw(images.left, x: margin, y: y)
            draw(images.right, x: right, y: y)
        }
    }
    guard let image = context.makeImage() else { throw VisualError.cannotDraw }
    return image
}

private func export<Report: Encodable, Row>(_ report: Report, rows: [Row], inputs: [RunInput],
                                            to outputRoot: URL, prefix: String, headings: (String, String),
                                            read: (Row) throws -> (label: String, left: CGImage, right: CGImage)) throws -> URL {
    let reportID = UUID().uuidString
    let temporary = outputRoot.appending(path: ".\(reportID)")
    let output = outputRoot.appending(path: reportID)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let perPage = 10
    for start in stride(from: 0, to: rows.count, by: perPage) {
        let page = rows[start..<min(start + perPage, rows.count)]
        let sheet = try makeSheet(page, headings: headings, read: read)
        try writePNG(sheet, to: temporary.appending(path: "\(prefix)-\(start / perPage + 1).png"))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: temporary.appending(path: "report.json"))
    for input in inputs { try input.checkUnchanged() }
    try FileManager.default.moveItem(at: temporary, to: output)
    return output
}

private func titleOnOneLine(_ title: String) -> String {
    title.components(separatedBy: .newlines).joined(separator: " ")
}

private func run() throws {
    let args = CommandLine.arguments
    if args.count == 6, args[1] == "diff", let limit = Int(args[5]), limit > 0 {
        let before = try RunInput(args[2]), after = try RunInput(args[3])
        guard before.run.time == after.run.time else { throw VisualError.differentRenderTimes }
        let outputRoot = URL(fileURLWithPath: args[4], isDirectory: true)
        let report = compareRenders(before: before, after: after)
        let changed = report.ranked.prefix { $0.changedPixels > 0 }
        let selected = Array(changed.prefix(limit))
        let output = try export(report, rows: selected, inputs: [before, after], to: outputRoot,
                                prefix: "changed", headings: ("Before", "After")) { scene in
            guard let a = readSceneImage(scene.id, in: before.directory, maxSize: 1024),
                  let b = readSceneImage(scene.id, in: after.directory, maxSize: 1024) else {
                throw VisualError.inputChanged
            }
            let label = String(format: "%@   MAE %.2f   %.2f%% changed", scene.id,
                               scene.meanRGBDifference, scene.changedPixelPercent)
            return (label, a, b)
        }
        print("Render comparison: \(report.ranked.count)/\(report.totalScenes) compared, \(changed.count) changed, \(report.skipped.count) skipped")
        for scene in selected {
            print(String(format: "%7.3f  %6.2f%%  %@  %@", scene.meanRGBDifference, scene.changedPixelPercent,
                         scene.id, titleOnOneLine(scene.title)))
        }
        print("Report: \(output.appending(path: "report.json").path)")
        if report.ranked.isEmpty { throw VisualError.noPairs }
        if !selected.isEmpty { print("Sheets: \(output.path)/changed-*.png") }
        return
    }

    guard args.count == 4, let limit = Int(args[3]), limit > 0 else { throw VisualError.usage }
    let input = try RunInput(args[1])
    let outputRoot = URL(fileURLWithPath: args[2], isDirectory: true)
    let report = compare(input.run, in: input.directory)
    let selected = Array(report.ranked.prefix(limit))
    let output = try export(report, rows: selected, inputs: [input], to: outputRoot,
                            prefix: "worst", headings: ("Render (center crop)", "Author preview")) { scene in
        guard let images = ImagePair.read(id: scene.id, in: input.directory) else { throw VisualError.inputChanged }
        return (String(format: "%@   %.1f / 100", scene.id, scene.similarity), images.render, images.preview)
    }
    print("Visual comparison: \(report.ranked.count)/\(report.totalScenes) scored, \(report.skipped.count) skipped")
    for scene in selected {
        print(String(format: "%5.1f  %@  %@", scene.similarity, scene.id, titleOnOneLine(scene.title)))
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
