import SwiftUI
import TerminalRender
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminal.fontSize") private var fontSize = Double(TerminalConfiguration.defaultFontSize)
    @AppStorage("terminal.theme") private var theme = "dark"
    @AppStorage(TerminalFontLibrary.selectionKey) private var fontName = TerminalFont.postScriptName
    @State private var fontLibrary = TerminalFontLibrary.shared
    @State private var importingFont = false
    @State private var fontImportInProgress = false
    @State private var fontError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...32)
                    Picker("Font", selection: $fontName) {
                        Text("\(TerminalFont.displayName) (Default)").tag(TerminalFont.postScriptName)
                        ForEach(fontLibrary.fonts) { font in
                            Text(font.displayName).tag(font.postScriptName)
                        }
                    }
                    LabeledContent("Japanese fallback", value: TerminalFont.fallbackDisplayName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\u{f07c} ~/開発  \u{e0a0} main\n\u{276f} echo 日本語")
                        .font(Font(fontLibrary.font(ofSize: fontSize, selection: fontName)))
                        .foregroundStyle(theme == "dark" ? .white : .black)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme == "dark" ? Color(white: 0.06) : Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Terminal font preview")
                    NavigationLink("Font licenses") {
                        ScrollView {
                            Text(TerminalFont.licenseText)
                                .font(.caption)
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle("Font licenses")
                    }
                }
                Section {
                    Button("Import font from Files", systemImage: "square.and.arrow.down") { importingFont = true }
                        .disabled(fontImportInProgress)
                    if fontImportInProgress { ProgressView("Importing font…") }
                    ForEach(fontLibrary.fonts) { font in
                        HStack {
                            Text(font.displayName)
                            Spacer()
                            Button(role: .destructive) {
                                do { try fontLibrary.remove(font) }
                                catch { fontError = error.localizedDescription }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(font.displayName)")
                        }
                    }
                    if let warning = fontLibrary.loadWarning {
                        Text(warning).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Imported fonts")
                } footer: {
                    Text("Use monospaced .ttf or .otf files, up to 32 MB each. Fonts are copied into iOSSH. Missing Japanese glyphs use Noto Sans CJK JP. Removing the selected font restores HackGen Console NF.")
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
            .fileImporter(isPresented: $importingFont,
                          allowedContentTypes: [UTType(filenameExtension: "ttf") ?? .font, UTType(filenameExtension: "otf") ?? .font],
                          allowsMultipleSelection: false) { result in
                do {
                    if let url = try result.get().first {
                        fontImportInProgress = true
                        Task {
                            defer { fontImportInProgress = false }
                            do { try await fontLibrary.importFont(from: url) }
                            catch { fontError = error.localizedDescription }
                        }
                    }
                } catch {
                    if (error as NSError).code != CocoaError.userCancelled.rawValue { fontError = error.localizedDescription }
                }
            }
            .alert("Font could not be changed", isPresented: Binding(get: { fontError != nil }, set: { if !$0 { fontError = nil } })) {
                Button("OK", role: .cancel) { fontError = nil }
            } message: {
                Text(fontError ?? "")
            }
        }
    }
}
