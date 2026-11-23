import Foundation
import XCTest

extension XCTestCase {
    func makeFixtureDirectory(name: String = UUID().uuidString) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "LumenTests-\(UUID())")
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        return directory
    }
}

extension Data {
    mutating func appendLE(_ values: UInt32...) {
        for value in values {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
        }
    }

    mutating func appendCString(_ value: String) {
        append(contentsOf: value.utf8)
        append(0)
    }

    mutating func appendSizedString(_ value: String) {
        appendLE(UInt32(value.utf8.count))
        append(contentsOf: value.utf8)
    }
}
