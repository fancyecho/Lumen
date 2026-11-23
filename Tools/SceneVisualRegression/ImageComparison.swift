import CoreGraphics
import Foundation
import ImageIO

let comparisonColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

struct ImagePair {
    let render: CGImage
    let preview: CGImage

    static func read(id: String, in directory: URL) -> Self? {
        guard let render = readImage(directory.appending(path: "\(id).png")),
              let preview = readImage(directory.appending(path: "\(id)-ref.png")) else { return nil }
        let aspect = Double(preview.width) / Double(preview.height)
        let w = min(render.width, max(1, Int((Double(render.height) * aspect).rounded())))
        let h = min(render.height, max(1, Int((Double(render.width) / aspect).rounded())))
        let crop = CGRect(x: (render.width - w) / 2, y: (render.height - h) / 2, width: w, height: h)
        guard let cropped = render.cropping(to: crop) else { return nil }
        return Self(render: cropped, preview: preview)
    }

    private static func readImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ] as CFDictionary)
    }

    func compare() -> ImageSimilarity? {
        let longestSide = Double(max(preview.width, preview.height))
        let width = max(1, Int((128 * Double(preview.width) / longestSide).rounded()))
        let height = max(1, Int((128 * Double(preview.height) / longestSide).rounded()))
        guard let rendered = rasterize(render, width: width, height: height),
              let reference = rasterize(preview, width: width, height: height) else { return nil }
        return ImageSimilarity(rendered: rendered, reference: reference, width: width, height: height)
    }

    private func rasterize(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer in
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: comparisonColorSpace, bitmapInfo: bitmapInfo)
            else { return false }
            let destination = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(destination)
            context.interpolationQuality = .high
            context.draw(image, in: destination)
            return true
        }
        return drew ? bytes : nil
    }
}

struct ImageSimilarity {
    let luminanceSSIM: Double
    let rgbMAE: Double

    var score: Double { 100 * (0.7 * luminanceSSIM + 0.3 * (1 - rgbMAE)) }

    init(rendered: [UInt8], reference: [UInt8], width: Int, height: Int) {
        if rendered == reference {
            luminanceSSIM = 1
            rgbMAE = 0
            return
        }
        let block = 8
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        var structuralSum = 0.0
        var absoluteColorSum = 0

        for top in stride(from: 0, to: height, by: block) {
            for left in stride(from: 0, to: width, by: block) {
                let bottom = min(top + block, height)
                let right = min(left + block, width)
                var sumX = 0.0, sumY = 0.0, squareX = 0.0, squareY = 0.0, product = 0.0
                for row in top..<bottom {
                    for column in left..<right {
                        let i = (row * width + column) * 4
                        let x = Self.luma(rendered, at: i), y = Self.luma(reference, at: i)
                        sumX += x
                        sumY += y
                        squareX += x * x
                        squareY += y * y
                        product += x * y
                        for channel in i..<(i + 3) {
                            absoluteColorSum += abs(Int(rendered[channel]) - Int(reference[channel]))
                        }
                    }
                }
                let count = Double((bottom - top) * (right - left))
                let meanX = sumX / count, meanY = sumY / count
                let varianceX = max(0, squareX / count - meanX * meanX)
                let varianceY = max(0, squareY / count - meanY * meanY)
                let covariance = product / count - meanX * meanY
                // Local SSIM over uniform windows (Wang et al. 2004).
                let brightness = (2 * meanX * meanY + c1) / (meanX * meanX + meanY * meanY + c1)
                let structure = (2 * covariance + c2) / (varianceX + varianceY + c2)
                structuralSum += min(1, max(0, brightness * structure)) * count
            }
        }
        luminanceSSIM = structuralSum / Double(width * height)
        rgbMAE = Double(absoluteColorSum) / Double(width * height * 3 * 255)
    }

    private static func luma(_ pixels: [UInt8], at index: Int) -> Double {
        (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
    }
}
