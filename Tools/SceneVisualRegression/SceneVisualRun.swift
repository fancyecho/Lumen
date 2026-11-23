import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SceneVisualRun: Codable {
    struct Scene: Codable {
        enum Outcome: String, Codable {
            case ready
            case renderFailed
            case previewUnavailable
        }

        let id: String
        let title: String
        let outcome: Outcome
    }

    static let filename = "visual-inputs.json"

    let id: UUID
    let time: Float
    let scenes: [Scene]
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
    try (data as Data).write(to: url, options: .atomic)
}
