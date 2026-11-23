import Foundation
import XCTest

final class TexDecoderTests: XCTestCase {
    func testReadsPaddedRGBATextureAndMipChain() throws {
        let topMip = Data(0..<32)
        let bottomMip = Data([32, 33, 34, 35, 36, 37, 38, 39])
        var fixture = textureHeader(size: (4, 2), imageSize: (3, 2))
        fixture.appendLE(2) // Mip count.
        fixture.appendLE(4, 2, UInt32(topMip.count))
        fixture.append(topMip)
        fixture.appendLE(2, 1, UInt32(bottomMip.count))
        fixture.append(bottomMip)

        let texture = try WETexture.decode(fixture)

        XCTAssertEqual(texture.format, .rgba8888)
        XCTAssertEqual(texture.textureSize, SIMD2(4, 2))
        XCTAssertEqual(texture.imageSize, SIMD2(3, 2))
        XCTAssertEqual(texture.images.count, 1)
        XCTAssertEqual(texture.images.first?.map(\.width), [4, 2])
        XCTAssertEqual(texture.images.first?.map(\.height), [2, 1])
        XCTAssertEqual(texture.images.first?.map(\.data), [topMip, bottomMip])
    }

    func testDecodesRawLZ4Mip() throws {
        var fixture = textureHeader(size: (1, 1), imageSize: (1, 1), container: "TEXB0002")
        fixture.appendLE(1) // Mip count.
        fixture.appendLE(1, 1, 1, 4, 5) // Dimensions, compressed flag, decoded and stored lengths.
        fixture.append(contentsOf: [0x40, 17, 34, 51, 255]) // LZ4 block with four literals.

        let texture = try WETexture.decode(fixture)

        XCTAssertEqual(texture.images.first?.first?.data, Data([17, 34, 51, 255]))
    }

    func testSpriteCoordinatesStayNormalisedToOriginalImageWhenTopMipIsSkipped() throws {
        var fixture = textureHeader(
            size: (4, 4), imageSize: (4, 4), format: 9, flags: 4
        )
        fixture.appendLE(2)
        fixture.appendLE(4, 4, 16)
        fixture.append(Data(repeating: 10, count: 16))
        fixture.appendLE(2, 2, 4)
        fixture.append(Data(repeating: 20, count: 4))
        fixture.appendCString("TEXS0002")
        fixture.appendLE(1, 0, Float(0.25).bitPattern) // One frame, image zero, duration.
        fixture.appendLE(Float(2).bitPattern, Float(1).bitPattern) // Pixel origin.
        fixture.appendLE(Float(0).bitPattern, Float(2).bitPattern) // Rotated x axis.
        fixture.appendLE(Float(-2).bitPattern, Float(0).bitPattern) // Rotated y axis.

        let texture = try WETexture.decode(fixture, maxDimension: 2)
        let frame = try XCTUnwrap(texture.frames.first)

        XCTAssertEqual(texture.format, .r8)
        XCTAssertTrue(texture.flags.contains(.animated))
        XCTAssertEqual(texture.textureSize, SIMD2(2, 2))
        XCTAssertEqual(texture.images.first?.map(\.data), [Data(repeating: 20, count: 4)])
        XCTAssertEqual(texture.frames.count, 1)
        XCTAssertEqual(frame.image, 0)
        XCTAssertEqual(frame.duration, 0.25)
        XCTAssertEqual(frame.origin, SIMD2(0.5, 0.25))
        XCTAssertEqual(frame.xAxis, SIMD2(0, 0.5))
        XCTAssertEqual(frame.yAxis, SIMD2(-0.5, 0))
    }

    func testTruncatedMipPayloadThrows() {
        var fixture = textureHeader(size: (1, 1), imageSize: (1, 1))
        fixture.appendLE(1, 1, 1, 4)
        fixture.append(contentsOf: [17, 34, 51])

        XCTAssertThrowsError(try WETexture.decode(fixture)) { error in
            guard case .corruptPackage? = error as? SceneLoadError else {
                return XCTFail("Expected corruptPackage, got \(error)")
            }
        }
    }

    private func textureHeader(
        size: (UInt32, UInt32),
        imageSize: (UInt32, UInt32),
        format: UInt32 = 0,
        flags: UInt32 = 0,
        container: String = "TEXB0001"
    ) -> Data {
        var data = Data()
        data.appendCString("TEXV0005")
        data.appendCString("TEXI0001")
        data.appendLE(format, flags, size.0, size.1, imageSize.0, imageSize.1, 0)
        data.appendCString(container)
        data.appendLE(1) // Image count.
        return data
    }
}
