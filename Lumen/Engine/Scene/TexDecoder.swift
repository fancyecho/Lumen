import Compression
import CoreGraphics
import Foundation
import ImageIO
import Metal

/// A decoded Wallpaper Engine `.tex` texture, ready to upload.
///
/// Layout: `TEXV0005`/`TEXI0001` headers, the format and sizes, a `TEXB000x` container with
/// one or more images (each a mip chain, optionally LZ4-compressed, or an embedded PNG/JPEG),
/// then for animated textures a `TEXS000x` frame table.
struct WETexture {
    enum Format: Int {
        case rgba8888 = 0
        case dxt5 = 4
        case dxt3 = 6
        case dxt1 = 7
        case rg88 = 8
        case r8 = 9

        var pixelFormat: MTLPixelFormat {
            switch self {
            case .rgba8888: .rgba8Unorm
            case .dxt5: .bc3_rgba
            case .dxt3: .bc2_rgba
            case .dxt1: .bc1_rgba
            case .rg88: .rg8Unorm
            case .r8: .r8Unorm
            }
        }

        var isBlockCompressed: Bool { self == .dxt1 || self == .dxt3 || self == .dxt5 }

        func bytesPerRow(width: Int) -> Int {
            switch self {
            case .rgba8888: width * 4
            case .rg88: width * 2
            case .r8: width
            case .dxt1: max(1, (width + 3) / 4) * 8
            case .dxt3, .dxt5: max(1, (width + 3) / 4) * 16
            }
        }

        func byteCount(width: Int, height: Int) -> Int {
            isBlockCompressed ? bytesPerRow(width: width) * max(1, (height + 3) / 4) : bytesPerRow(width: width) * height
        }
    }

    struct Mip {
        let width: Int
        let height: Int
        /// The bytes as stored: LZ4-compressed when `decodedSize` is set. Decoding waits until the
        /// upload so a large sheet (five 8192² images are 1.3 GB) never sits decoded in memory.
        let stored: Data
        let decodedSize: Int?

        init(width: Int, height: Int, data: Data) {
            self.init(width: width, height: height, stored: data, decodedSize: nil)
        }

        init(width: Int, height: Int, stored: Data, decodedSize: Int?) {
            self.width = width
            self.height = height
            self.stored = stored
            self.decodedSize = decodedSize
        }

        /// Size of the pixels once decoded.
        var byteCount: Int { decodedSize ?? stored.count }

        /// The decoded pixels as a new buffer.
        var data: Data {
            guard let decodedSize else { return stored }
            var output = Data(count: decodedSize)
            let written = output.withUnsafeMutableBytes { write(to: $0.baseAddress!, capacity: decodedSize) }
            if written < decodedSize { output.count = written }
            return output
        }

        /// Decodes into `destination` and returns the bytes written (0 if decoding failed).
        func write(to destination: UnsafeMutableRawPointer, capacity: Int) -> Int {
            stored.withUnsafeBytes { source -> Int in
                guard let base = source.baseAddress, capacity > 0 else { return 0 }
                guard decodedSize != nil else {
                    let count = min(capacity, source.count)
                    destination.copyMemory(from: base, byteCount: count)
                    return count
                }
                return compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), capacity,
                                                 base.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
    }

    /// One frame of a sprite-sheet animation, in normalised coordinates of its image.
    struct Frame {
        let image: Int
        let duration: Float
        let origin: SIMD2<Float>
        /// Texture-space vectors for the frame's x and y axes (allow rotated frames).
        let xAxis: SIMD2<Float>
        let yAxis: SIMD2<Float>
    }

    struct Flags: OptionSet {
        let rawValue: Int32
        static let noInterpolation = Flags(rawValue: 1)
        static let clampUVs = Flags(rawValue: 2)
        static let animated = Flags(rawValue: 4)
        static let video = Flags(rawValue: 32)
    }

    let format: Format
    let flags: Flags
    /// Allocated texture size (Wallpaper Engine pads to block or power-of-two sizes).
    let textureSize: SIMD2<Int>
    /// The picture's size inside the texture.
    let imageSize: SIMD2<Int>
    /// Each image is a mip chain, largest first.
    let images: [[Mip]]
    let frames: [Frame]
    /// An MP4 stored in the texture (Wallpaper Engine "video texture"); `images` is empty.
    var video: Data?

    /// Code Wallpaper Engine shaders compare `TEXnFORMAT` against.
    var formatCode: Int { format.rawValue }

    // MARK: Decoding

    enum DecodeError: Error { case unsupported(String) }

    /// - Parameters:
    ///   - maxDimension: hard cap; larger images are decoded at a smaller mip (or scaled).
    ///   - detail: share of the full resolution the scene can show (its render scale with some
    ///     headroom). Mips are skipped only while the next one still has that much detail, so a
    ///     scene rendered below its canvas size never magnifies a halved texture.
    static func decode(_ data: Data, maxDimension: Int = 8192, detail: Float = 1) throws -> WETexture {
        var reader = ByteReader(data: data)
        let magic = try reader.cString(maxLength: 16)
        guard magic.hasPrefix("TEXV") else { throw DecodeError.unsupported(magic) }
        _ = try reader.cString(maxLength: 16)
        let rawFormat = Int(try reader.int32())
        let flags = Flags(rawValue: try reader.int32())
        let textureWidth = Int(try reader.int32())
        let textureHeight = Int(try reader.int32())
        let imageWidth = Int(try reader.int32())
        let imageHeight = Int(try reader.int32())
        _ = try reader.uint32()

        let container = try reader.cString(maxLength: 16)
        guard container.hasPrefix("TEXB") else { throw DecodeError.unsupported(container) }
        let version = Int(container.dropFirst(4)) ?? 1
        let imageCount = Int(try reader.int32())
        var freeImageFormat: Int32 = -1
        if version >= 3 { freeImageFormat = try reader.int32() }
        if version >= 4 { _ = try reader.int32() }
        guard imageCount > 0, imageCount < 256 else { throw DecodeError.unsupported("images \(imageCount)") }

        var format = Format(rawValue: rawFormat) ?? .rgba8888
        var images: [[Mip]] = []
        /// Each image's full size before any mip was skipped; sprite frames are in these pixels.
        var originalSizes: [SIMD2<Float>] = []
        var texture = SIMD2(textureWidth, textureHeight)
        var image = SIMD2(imageWidth, imageHeight)

        if flags.contains(.video) {
            // One "mip" whose bytes are an MP4 file.
            _ = try reader.int32()
            _ = try reader.int32()
            _ = try reader.int32()
            if version >= 2 {
                _ = try reader.int32()
                _ = try reader.int32()
            }
            let size = Int(try reader.int32())
            let movie = try reader.bytes(min(size, reader.remaining))
            return WETexture(format: .rgba8888, flags: flags, textureSize: SIMD2(textureWidth, textureHeight),
                             imageSize: SIMD2(imageWidth, imageHeight), images: [], frames: [], video: movie)
        }

        for _ in 0..<imageCount {
            let mipCount = Int(try reader.int32())
            guard mipCount > 0, mipCount < 20 else { throw DecodeError.unsupported("mips \(mipCount)") }
            var raw: [(Int, Int, Data, Bool, Int)] = []
            for _ in 0..<mipCount {
                let width = Int(try reader.int32())
                let height = Int(try reader.int32())
                var compressed = false
                var decompressedSize = 0
                if version >= 2 {
                    compressed = try reader.int32() == 1
                    decompressedSize = Int(try reader.int32())
                }
                let size = Int(try reader.int32())
                raw.append((width, height, try reader.bytes(size), compressed, decompressedSize))
            }

            if let first = raw.first { originalSizes.append(SIMD2(Float(max(first.0, 1)), Float(max(first.1, 1)))) }
            if freeImageFormat != -1 {
                // An ordinary image file (PNG, JPEG…) stored inside the texture.
                guard let first = raw.first else { continue }
                let bytes = first.3 ? try lz4(first.2, size: first.4) : first.2
                let decoded = try decodeImage(bytes, maxDimension: maxDimension, detail: detail)
                format = .rgba8888
                images.append([decoded.mip])
                // The stored file has no padding; Wallpaper Engine's header still describes
                // the padded size, so keep the image/texture ratio from the header.
                texture = SIMD2(decoded.mip.width, decoded.mip.height)
                image = SIMD2(decoded.mip.width, decoded.mip.height)
                if textureWidth > 0, textureHeight > 0, imageWidth < textureWidth || imageHeight < textureHeight,
                   first.0 == textureWidth, first.1 == textureHeight {
                    image = SIMD2(
                        Int((Double(decoded.mip.width) * Double(imageWidth) / Double(textureWidth)).rounded()),
                        Int((Double(decoded.mip.height) * Double(imageHeight) / Double(textureHeight)).rounded())
                    )
                }
                continue
            }

            // Skip mips larger than needed; keep the rest of the chain.
            var startIndex = 0
            let neededWidth = Int((Float(raw.first?.0 ?? 0) * min(detail, 1)).rounded(.up))
            let neededHeight = Int((Float(raw.first?.1 ?? 0) * min(detail, 1)).rounded(.up))
            while startIndex + 1 < raw.count,
                  max(raw[startIndex].0, raw[startIndex].1) > maxDimension
                    || (raw[startIndex + 1].0 >= neededWidth && raw[startIndex + 1].1 >= neededHeight) {
                startIndex += 1
            }
            var mips: [Mip] = []
            for (index, entry) in raw.enumerated() where index >= startIndex {
                let expected = format.byteCount(width: entry.0, height: entry.1)
                let size = entry.3 ? entry.4 : entry.2.count
                guard size >= expected, entry.0 > 0, entry.1 > 0 else { break }
                mips.append(Mip(width: entry.0, height: entry.1, stored: entry.2, decodedSize: entry.3 ? entry.4 : nil))
            }
            guard let first = mips.first else { throw DecodeError.unsupported("empty mip chain") }
            if images.isEmpty, startIndex > 0, raw[0].0 > 0 {
                let scale = Double(first.width) / Double(raw[0].0)
                texture = SIMD2(first.width, first.height)
                image = SIMD2(max(1, Int(Double(imageWidth) * scale)), max(1, Int(Double(imageHeight) * scale)))
            } else if images.isEmpty {
                texture = SIMD2(first.width, first.height)
                if textureWidth > 0, first.width != textureWidth {
                    let scale = Double(first.width) / Double(textureWidth)
                    image = SIMD2(max(1, Int(Double(imageWidth) * scale)), max(1, Int(Double(imageHeight) * scale)))
                }
            }
            images.append(mips)
        }

        var frames: [Frame] = []
        if flags.contains(.animated), reader.remaining > 12 {
            frames = (try? readFrames(&reader, imageSizes: originalSizes)) ?? []
        }
        if image.x <= 0 || image.y <= 0 { image = texture }
        return WETexture(format: format, flags: flags, textureSize: texture, imageSize: image, images: images, frames: frames)
    }

    /// Frame rectangles are in pixels of their (padded) image, so they normalise by its size.
    private static func readFrames(_ reader: inout ByteReader, imageSizes: [SIMD2<Float>]) throws -> [Frame] {
        let tag = try reader.cString(maxLength: 16)
        guard tag.hasPrefix("TEXS") else { return [] }
        let version = Int(tag.dropFirst(4)) ?? 1
        let count = Int(try reader.int32())
        guard count > 0, count < 100_000 else { return [] }
        if version >= 3 { try reader.skip(8) }
        var frames: [Frame] = []
        for _ in 0..<count {
            let image = Int(try reader.int32())
            let duration = try reader.float()
            var values: [Float] = []
            for _ in 0..<6 {
                values.append(version == 1 ? Float(try reader.int32()) : try reader.float())
            }
            let index = min(max(image, 0), max(imageSizes.count - 1, 0))
            let size = imageSizes[safe: index] ?? SIMD2(1, 1)
            // x, y, width, widthY, heightX, height in pixels of the sheet.
            frames.append(Frame(
                image: index,
                duration: duration,
                origin: SIMD2(values[0], values[1]) / size,
                xAxis: SIMD2(values[2], values[3]) / size,
                yAxis: SIMD2(values[4], values[5]) / size
            ))
        }
        return frames
    }

    private static func lz4(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return data }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written > 0 else { throw DecodeError.unsupported("lz4") }
        if written < size { output.count = written }
        return output
    }

    private static func decodeImage(_ data: Data, maxDimension cap: Int, detail: Float) throws -> (mip: Mip, Void) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw DecodeError.unsupported("image") }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxDimension = min(cap, max(1, Int((Float(max(width, height)) * min(detail, 1)).rounded(.up))))
        let image: CGImage?
        if max(width, height) > maxDimension {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { throw DecodeError.unsupported("image") }
        return (rgba(image), ())
    }

    /// Straight (non-premultiplied) RGBA8, as Wallpaper Engine's shaders expect.
    static func rgba(_ image: CGImage) -> Mip {
        let width = image.width, height = image.height
        // Ask ImageIO for unpremultiplied pixels by drawing into a vImage-free buffer.
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            pixels.withUnsafeMutableBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                var index = 0
                while index < bytes.count {
                    let alpha = Int(bytes[index + 3])
                    if alpha > 0 && alpha < 255 {
                        bytes[index] = UInt8(min(255, Int(bytes[index]) * 255 / alpha))
                        bytes[index + 1] = UInt8(min(255, Int(bytes[index + 1]) * 255 / alpha))
                        bytes[index + 2] = UInt8(min(255, Int(bytes[index + 2]) * 255 / alpha))
                    }
                    index += 4
                }
            }
        }
        return Mip(width: width, height: height, data: pixels)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
