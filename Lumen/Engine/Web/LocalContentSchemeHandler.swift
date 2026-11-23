import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves a wallpaper's folder to its web view as `lumen-web://<id>/…`.
///
/// A real origin (instead of `file://`) lets pages `fetch` their own JSON, models and
/// textures, which Live2D and three.js wallpapers depend on, and keeps each wallpaper
/// sandboxed to its own folder. Range requests are honoured so `<video>` can seek.
final class LocalContentSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lumen-web"

    private let root: URL
    private let queue = DispatchQueue(label: "app.lumen.web-files", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    static func url(for id: UUID, entry: String) -> URL? {
        let path = entry.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
        return URL(string: "\(scheme)://\(id.uuidString.lowercased())/\(path.joined(separator: "/"))")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        active.insert(key)
        let request = task.request
        let root = self.root
        queue.async { [weak self] in
            let response = Self.respond(to: request, root: root)
            DispatchQueue.main.async {
                guard let self, self.active.remove(key) != nil else { return }
                switch response {
                case .success(let (urlResponse, body)):
                    task.didReceive(urlResponse)
                    task.didReceive(body)
                    task.didFinish()
                case .failure(let error):
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private static func respond(to request: URLRequest, root: URL) -> Result<(URLResponse, Data), Error> {
        guard let url = request.url else { return .failure(URLError(.badURL)) }
        let relative = (url.path(percentEncoded: false)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let file = root.appending(path: relative.isEmpty ? "index.html" : relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") || file.path == root.path else {
            return .failure(URLError(.noPermissionsToReadFile))
        }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/plain", "Access-Control-Allow-Origin": "*",
            ])!
            return .success((response, Data()))
        }

        let mime = UTType(filenameExtension: file.pathExtension.lowercased())?.preferredMIMEType ?? mimeFallback(file.pathExtension)
        var headers = [
            "Content-Type": mime,
            "Access-Control-Allow-Origin": "*",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
        ]
        if let range = request.value(forHTTPHeaderField: "Range"), let bounds = parseRange(range, length: data.count) {
            headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(data.count)"
            headers["Content-Length"] = String(bounds.count)
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return .success((response, data.subdata(in: bounds)))
        }
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        return .success((response, data))
    }

    private static func parseRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]) {
            let start = max(0, length - suffix)
            return start..<length
        }
        guard let start = Int(parts[0]), start < length else { return nil }
        let end = Int(parts[1]).map { min($0, length - 1) } ?? (length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    private static func mimeFallback(_ ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": "text/javascript"
        case "json", "map": "application/json"
        case "wasm": "application/wasm"
        case "moc3", "bin", "dat": "application/octet-stream"
        case "glsl", "vert", "frag", "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
