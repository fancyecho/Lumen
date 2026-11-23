import CryptoKit
import Foundation
import MetricKit

/// Persists crash and hang reports delivered by MetricKit to this Mac.
final class LocalDiagnostics: NSObject, MXMetricManagerSubscriber {
    private static let queue = DispatchQueue(label: "app.lumen.diagnostics", qos: .utility)
    private let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Lumen")) {
        self.directory = directory
    }

    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        didReceive(manager.pastDiagnosticPayloads)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.filter {
            $0.crashDiagnostics?.isEmpty == false || $0.hangDiagnostics?.isEmpty == false
        }.map { $0.jsonRepresentation() }
        guard !reports.isEmpty else { return }
        let directory = directory
        Self.queue.async {
            do {
                try Self.save(reports, in: directory)
            } catch {
                Log.engine.error("Could not save MetricKit reports: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func save(_ reports: [Data], in directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        for report in reports {
            let object = try JSONSerialization.jsonObject(with: report)
            let json = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
            let path = directory.appending(path: "diagnostic-\(digest).json")
            if !files.fileExists(atPath: path.path) {
                try json.write(to: path, options: .atomic)
            }
        }

        let saved = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("diagnostic-") && $0.pathExtension == "json" }
        let sorted = saved.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (path, _) in sorted.dropFirst(30) { try files.removeItem(at: path) }
    }
}
