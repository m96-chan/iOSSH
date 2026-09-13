import SwiftData
import SwiftUI

@main
struct iOSSHApp: App {
    private let container: Result<ModelContainer, Error>

    init() {
        do {
            let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            if testing, ProcessInfo.processInfo.arguments.contains("--ui-testing-tailscale-import") {
                try TailscaleImportInbox.shared.receive(hostnames: ["atlas.tail-example.ts.net", "zephyr.tail-example.ts.net", "100.64.0.23"])
            }
            if !testing {
                _ = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            }
            let configuration = ModelConfiguration(isStoredInMemoryOnly: testing)
            container = .success(try ModelContainer(for: HostRecord.self, configurations: configuration))
        } catch {
            container = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch container {
            case .success(let container):
                HostListView()
                    .modelContainer(container)
                    .tint(.mint)
                    .onOpenURL { TailscaleImportInbox.shared.handleCallback($0) }
            case .failure(let error):
                ContentUnavailableView("Couldn’t open your hosts", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}
