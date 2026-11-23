import SwiftUI

/// Edits a web or scene wallpaper's Wallpaper Engine properties, applied live.
struct PropertiesPanel: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let package: PackageAsset

    var body: some View {
        let values = package.resolvedValues
        let visible = package.properties.filter { $0.isEditable && WEProperty.conditionHolds($0.condition, values: values) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Customize", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !package.values.isEmpty {
                    Button("Reset") { model.resetProperties(for: wallpaper.id) }
                        .buttonStyle(.glass)
                }
            }
            if visible.isEmpty {
                Text("Nothing to customize with the current options.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(visible) { property in
                PropertyRow(property: property, value: values[property.id] ?? property.defaultValue) { newValue in
                    let stored: PropertyValue? = newValue == property.defaultValue ? nil : newValue
                    model.setProperty(stored, key: property.id, for: wallpaper.id)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.surfaceStroke))
    }
}

private struct PropertyRow: View {
    let property: WEProperty
    let value: PropertyValue
    let onChange: (PropertyValue) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(verbatim: property.label)
                .font(.system(size: 13))
                .lineLimit(2)
                .frame(width: 200, alignment: .leading)
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch property.kind {
        case .bool:
            Toggle("", isOn: Binding(get: { value.boolValue }, set: { onChange(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
        case .slider:
            let lower = property.min ?? 0
            let upper = max(property.max ?? 1, lower + 0.0001)
            HStack(spacing: 10) {
                Slider(
                    value: Binding(get: { min(max(value.doubleValue, lower), upper) }, set: { onChange(.number(rounded($0))) }),
                    in: lower...upper
                )
                Text(verbatim: formatted(value.doubleValue))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        case .combo:
            Picker("", selection: Binding(get: { value.stringValue }, set: { onChange(.string($0)) })) {
                ForEach(property.options, id: \.value) { option in
                    Text(verbatim: option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .color:
            ColorPicker("", selection: Binding(get: { Self.color(from: value.stringValue) }, set: { onChange(.string(Self.string(from: $0))) }), supportsOpacity: false)
                .labelsHidden()
        case .textinput:
            TextField("", text: Binding(get: { value.stringValue }, set: { onChange(.string($0)) }))
                .textFieldStyle(.roundedBorder)
        default:
            EmptyView()
        }
    }

    private func rounded(_ number: Double) -> Double {
        if let step = property.step, step > 0 {
            return (number / step).rounded() * step
        }
        let digits = Double(property.precision ?? 2)
        let factor = pow(10, digits)
        return (number * factor).rounded() / factor
    }

    private func formatted(_ number: Double) -> String {
        let digits = property.precision ?? (number.rounded() == number ? 0 : 2)
        return String(format: "%.\(min(max(digits, 0), 4))f", number)
    }

    /// Wallpaper Engine colours are "r g b" with components in 0…1.
    static func color(from string: String) -> Color {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard parts.count >= 3 else { return .white }
        let scale = parts.prefix(3).contains { $0 > 1 } ? 255.0 : 1.0
        return Color(.sRGB, red: parts[0] / scale, green: parts[1] / scale, blue: parts[2] / scale, opacity: 1)
    }

    static func string(from color: Color) -> String {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%.4f %.4f %.4f", resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
    }
}
