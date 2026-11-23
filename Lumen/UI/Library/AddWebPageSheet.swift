import SwiftUI

/// Adds a web page (any URL) as a wallpaper.
struct AddWebPageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var title = ""

    private var url: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Web Page").font(Theme.TypeScale.sectionTitle)
                    Text(verbatim: "HTML · URL")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Any page can be a wallpaper: a clock, a generative sketch, a dashboard. It runs in its own sandbox and pauses with your other wallpapers.")
                .font(Theme.TypeScale.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Address", text: $address, prompt: Text(verbatim: "https://example.com"))
                TextField("Name", text: $title, prompt: Text("Optional"))
            }
            .formStyle(.columns)
            .padding(Theme.Space.md)
            .lumenSurface(radius: Theme.Radius.lg)
            HStack(spacing: Theme.Space.xs) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button("Add") {
                    if let url { model.addWebPage(url, title: title) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(url == nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .tint(Theme.accent)
    }
}
