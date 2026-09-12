import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminal.fontSize") private var fontSize: Double = 14
    @AppStorage("terminal.theme") private var theme = "dark"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...32)
                    Text("user@server ~ %")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(theme == "dark" ? .white : .black)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme == "dark" ? Color(white: 0.06) : Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Terminal font preview")
                }
                Section("Using the terminal") {
                    Label("Swipe vertically to browse scrollback.", systemImage: "hand.draw")
                    Label("Long press to select and copy text.", systemImage: "selection.pin.in.out")
                    Label("Use the extra key row for Ctrl, Esc, Tab and arrows.", systemImage: "keyboard")
                }
                .font(.subheadline)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
