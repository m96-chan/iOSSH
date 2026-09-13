import AppIntents
import Foundation
import Observation

struct TailscaleImportRequest: Identifiable {
    let id = UUID()
    let devices: [TailscaleDeviceCandidate]
}

/// Shortcuts only stages a list. Saving hosts always requires selection in the app.
@MainActor @Observable
final class TailscaleImportInbox {
    static let shared = TailscaleImportInbox()
    static let shortcutName = "Import Tailscale Hosts"
    private(set) var request: TailscaleImportRequest?
    var message: String?
    private var callbackID: UUID?
    private var requestIDBeforeFetch: UUID?
    private var presentedRequestID: UUID?

    var needsPresentation: Bool { request != nil && request?.id != presentedRequestID }

    func markPresented() { presentedRequestID = request?.id }

    func receive(hostnames: [String]) throws {
        let devices = try TailscaleHostImport.candidates(from: hostnames)
        request = TailscaleImportRequest(devices: devices)
        message = nil
    }

    func clear() {
        request = nil
        message = nil
        callbackID = nil
        requestIDBeforeFetch = nil
        presentedRequestID = nil
    }

    func shortcutURL() -> URL {
        let id = UUID()
        callbackID = id
        requestIDBeforeFetch = request?.id
        message = nil
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: Self.shortcutName)]
        for (key, path) in [("x-success", "complete"), ("x-error", "error"), ("x-cancel", "cancel")] {
            components.queryItems?.append(URLQueryItem(name: key, value: "iossh://tailscale-import/\(path)?request=\(id.uuidString)"))
        }
        return components.url!
    }

    func handleCallback(_ url: URL) {
        guard url.scheme == "iossh", url.host == "tailscale-import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let callbackID,
              components.queryItems?.first(where: { $0.name == "request" })?.value == callbackID.uuidString else { return }
        switch url.path {
        case "/error": message = "The shortcut couldn’t finish. Check its setup in Shortcuts, then try again."
        case "/cancel": message = "Device retrieval was canceled."
        case "/complete":
            if request == nil || request?.id == requestIDBeforeFetch {
                message = "The shortcut returned no new device list. Add Review Tailscale Hosts as its final action."
            }
        default: return
        }
        self.callbackID = nil
    }
}

struct ReviewTailscaleHostsIntent: AppIntent {
    static var title: LocalizedStringResource { "Review Tailscale Hosts" }
    static var description: IntentDescription { IntentDescription("Open iOSSH to select and register devices from Tailscale’s Find Devices action. Pass their MagicDNS Address or IP address.") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Hostnames", description: "MagicDNS addresses or IP addresses from Tailscale devices.")
    var hostnames: [String]?

    static var parameterSummary: some ParameterSummary { Summary("Review \(\.$hostnames) in iOSSH") }

    @MainActor func perform() async throws -> some IntentResult {
        try TailscaleImportInbox.shared.receive(hostnames: hostnames ?? [])
        return .result()
    }
}
