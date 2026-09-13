import AppIntents
import Foundation
import Testing
@testable import iOSSH

@MainActor
struct TailscaleImportInboxTests {
    @Test func receivedListsArePresentedOnceAndInvalidInputPreservesTheCurrentList() throws {
        let inbox = TailscaleImportInbox()
        #expect(!inbox.needsPresentation)
        try inbox.receive(hostnames: ["Atlas.tail-example.ts.net.", "100.64.0.23"])
        let firstID = inbox.request?.id
        #expect(inbox.request?.devices.map(\.hostname) == ["atlas.tail-example.ts.net", "100.64.0.23"])
        #expect(inbox.needsPresentation)
        inbox.markPresented()
        #expect(!inbox.needsPresentation)
        #expect(throws: (any Error).self) { try inbox.receive(hostnames: ["https://invalid.example/path"]) }
        #expect(inbox.request?.id == firstID)
        #expect(!inbox.needsPresentation)
        try inbox.receive(hostnames: ["zephyr.tail-example.ts.net"])
        #expect(inbox.request?.id != firstID)
        #expect(inbox.needsPresentation)
        inbox.clear()
        #expect(inbox.request == nil)
        #expect(!inbox.needsPresentation)
    }

    @Test func onlyTheLatestShortcutCallbackIsAcceptedAndReportsTheActualError() throws {
        let inbox = TailscaleImportInbox()
        let first = try callback("x-error", in: inbox.shortcutURL())
        let current = try callback("x-error", in: inbox.shortcutURL())
        inbox.handleCallback(first)
        #expect(inbox.message == nil)
        var untrusted = try #require(URLComponents(url: current, resolvingAgainstBaseURL: false))
        untrusted.queryItems?.append(URLQueryItem(name: "errorMessage", value: "ショートカットが見つかりません。"))
        inbox.handleCallback(try #require(untrusted.url))
        #expect(inbox.message?.hasPrefix("Shortcuts reported:\nショートカットが見つかりません。") == true)
        #expect(inbox.message?.contains("Open Shortcuts") == true)
        inbox.message = nil
        inbox.handleCallback(current)
        #expect(inbox.message == nil, "Callbacks must be consumed once")
    }

    @Test func errorDetailsAreBoundedAndMissingDetailsOfferDirectTroubleshooting() throws {
        let inbox = TailscaleImportInbox()
        var url = try #require(URLComponents(url: callback("x-error", in: inbox.shortcutURL()), resolvingAgainstBaseURL: false))
        url.queryItems?.append(URLQueryItem(name: "errorMessage", value: "\u{0}" + String(repeating: "x", count: 2_000)))
        inbox.handleCallback(try #require(url.url))
        #expect(inbox.message?.contains("\u{0}") == false)
        #expect(inbox.message?.filter({ $0 == "x" }).count == 1_000)
        inbox.handleCallback(try callback("x-error", in: inbox.shortcutURL()))
        #expect(inbox.message?.contains("run Import Tailscale Hosts directly") == true)
    }

    @Test func successfulCallbackRequiresANewListAndCancellationPreservesCandidates() throws {
        let inbox = TailscaleImportInbox()
        try inbox.receive(hostnames: ["atlas.tail-example.ts.net"])
        let oldID = inbox.request?.id
        let noList = try callback("x-success", in: inbox.shortcutURL())
        inbox.handleCallback(noList)
        #expect(inbox.message?.contains("no new device list") == true)
        #expect(inbox.request?.id == oldID)
        let success = try callback("x-success", in: inbox.shortcutURL())
        try inbox.receive(hostnames: ["zephyr.tail-example.ts.net"])
        inbox.handleCallback(success)
        #expect(inbox.message == nil)
        #expect(inbox.request?.devices.first?.name == "zephyr")
        let cancel = try callback("x-cancel", in: inbox.shortcutURL())
        inbox.handleCallback(cancel)
        #expect(inbox.message?.contains("canceled") == true)
        #expect(inbox.request?.devices.first?.name == "zephyr")
    }

    @Test func clearingAnImportInvalidatesPendingCallbacks() throws {
        let inbox = TailscaleImportInbox()
        let cancel = try callback("x-cancel", in: inbox.shortcutURL())
        inbox.clear()
        inbox.handleCallback(cancel)
        #expect(inbox.message == nil)
        #expect(inbox.request == nil)
    }

    @Test func shortcutIntentStagesNormalizedCandidatesForReview() async throws {
        let inbox = TailscaleImportInbox.shared
        inbox.clear()
        defer { inbox.clear() }
        let intent = ReviewTailscaleHostsIntent()
        intent.hostnames = ["Atlas.tail-example.ts.net.", "", "atlas.tail-example.ts.net"]
        _ = try await intent.perform()
        #expect(inbox.request?.devices.map(\.hostname) == ["atlas.tail-example.ts.net"])
        #expect(inbox.needsPresentation)
        intent.hostnames = nil
        _ = try await intent.perform()
        #expect(inbox.request?.devices.isEmpty == true)
    }

    private func callback(_ name: String, in shortcutURL: URL) throws -> URL {
        let components = try #require(URLComponents(url: shortcutURL, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "shortcuts")
        #expect(components.host == "x-callback-url")
        #expect(components.path == "/run-shortcut")
        #expect(components.queryItems?.first(where: { $0.name == "name" })?.value == "Import Tailscale Hosts")
        let value = try #require(components.queryItems?.first(where: { $0.name == name })?.value)
        return try #require(URL(string: value))
    }
}
