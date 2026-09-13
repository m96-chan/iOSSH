import Foundation
import SSHCore
import SwiftData
import Testing
@testable import iOSSH

@MainActor
struct TailscaleHostImportTests {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: HostRecord.self, configurations: configuration)
    }

    private func device(_ id: String = "device", name: String = "Server", hostname: String = "server.tailnet.ts.net",
                        addresses: [String] = []) -> TailscaleDeviceCandidate {
        .init(id: id, name: name, hostname: hostname, addresses: addresses)
    }

    @Test func importsTrimmedHostsWithTailscaleDefaults() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let result = try TailscaleHostImport.register([
            device("one", name: "  My server  ", hostname: " Server.tailnet.ts.net. "),
            device("two", hostname: "100.64.0.2")
        ], username: " alice \n", in: context)
        #expect(result == .init(added: 2, skipped: 0))
        let fresh = ModelContext(container)
        let hosts = try fresh.fetch(FetchDescriptor<HostRecord>())
        #expect(hosts.count == 2)
        #expect(hosts.contains { $0.name == "My server" && $0.hostname == "Server.tailnet.ts.net." })
        #expect(hosts.allSatisfy { $0.username == "alice" && $0.port == 22 && $0.authentication == "tailscale"
            && $0.terminalType == "xterm-256color" })
    }

    @Test func existingDNSAndCandidateIPAliasesAreSkippedWithoutChangingRecords() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let dns = HostRecord(name: "Keep this name", hostname: "SERVER.tailnet.ts.net.", username: "alice",
                             authentication: "privateKey", terminalType: "vt100")
        let ipv4 = HostRecord(name: "IPv4", hostname: "100.64.0.2", username: "alice")
        let ipv6 = HostRecord(name: "IPv6", hostname: "fd7a:115c:a1e0:0:0:0:0:3", username: "alice")
        [dns, ipv4, ipv6].forEach { context.insert($0) }
        try context.save()
        let id = dns.id
        let createdAt = dns.createdAt
        let result = try TailscaleHostImport.register([
            device("dns"),
            device("ipv4", hostname: "other.tailnet.ts.net", addresses: [" 100.64.0.2 "]),
            device("ipv6", hostname: "third.tailnet.ts.net", addresses: ["fd7a:115c:a1e0::3"])
        ], username: "alice", in: context)
        #expect(result == .init(added: 0, skipped: 3))
        #expect(dns.id == id && dns.createdAt == createdAt && dns.name == "Keep this name")
        #expect(dns.authentication == "privateKey" && dns.terminalType == "vt100")
        #expect(try context.fetchCount(FetchDescriptor<HostRecord>()) == 3)
    }

    @Test func differentSSHUsersAndPortsRemainDistinct() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(HostRecord(name: "Other user", hostname: "100.64.0.1", username: "bob"))
        context.insert(HostRecord(name: "Other port", hostname: "100.64.0.1", port: 2222, username: "alice"))
        try context.save()
        let result = try TailscaleHostImport.register([device(addresses: ["100.64.0.1"])], username: "alice", in: context)
        #expect(result == .init(added: 1, skipped: 0))
        #expect(try context.fetchCount(FetchDescriptor<HostRecord>()) == 3)
    }

    @Test func repeatedSelectionsAndBridgedIPAliasesAreDeduplicated() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let result = try TailscaleHostImport.register([
            device("first", name: "Keep first", hostname: "first", addresses: ["100.64.0.1"]),
            device("second", hostname: "second", addresses: ["100.64.0.2"]),
            device("bridge", hostname: "third", addresses: ["100.64.0.1", "100.64.0.2"]),
            device("case", hostname: "FIRST.")
        ], username: "alice", in: context)
        #expect(result == .init(added: 1, skipped: 3))
        let records = try context.fetch(FetchDescriptor<HostRecord>())
        #expect(records.first?.name == "Keep first")
    }

    @Test func laterAliasCanMatchAnExistingHostForTheWholeSelectionGroup() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(HostRecord(name: "Existing", hostname: "100.64.0.2", username: "alice"))
        try context.save()
        let result = try TailscaleHostImport.register([
            device("first", hostname: "first", addresses: ["100.64.0.1"]),
            device("bridge", hostname: "second", addresses: ["100.64.0.1", "100.64.0.2"])
        ], username: "alice", in: context)
        #expect(result == .init(added: 0, skipped: 2))
        #expect(try context.fetchCount(FetchDescriptor<HostRecord>()) == 1)
    }

    @Test(arguments: ["ssh://server", "server:22", "server/path", "user@server", "server?x=1", "server#fragment",
                      "server name", "server\nname", "server\0.example", "-server", "server-", "a..b", "999.1.1.1",
                      "100.064.0.1", "[fd7a:115c:a1e0::1]", "fd7a:115c:a1e0::1%en0", ""])
    func unsafeHostnamesRejectTheWholeBatch(_ hostname: String) throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        #expect(throws: TailscaleHostImportError.invalidHostname) {
            try TailscaleHostImport.register([device("valid"), device("invalid", hostname: hostname)], username: "alice", in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<HostRecord>()) == 0)
        #expect(context.insertedModelsArray.isEmpty)
    }

    @Test func invalidAddressNameOrUsernameDoesNotSaveOtherPendingChanges() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let existing = HostRecord(name: "Original", hostname: "existing", username: "alice")
        context.insert(existing)
        try context.save()
        existing.name = "Unsaved edit"
        #expect(throws: TailscaleHostImportError.invalidAddress) {
            try TailscaleHostImport.register([device(addresses: ["server/path"])], username: "alice", in: context)
        }
        #expect(throws: TailscaleHostImportError.invalidName) {
            try TailscaleHostImport.register([device(name: " \n")], username: "alice", in: context)
        }
        #expect(throws: SSHSessionError.invalidConfiguration) {
            try TailscaleHostImport.register([device()], username: " \n", in: context)
        }
        #expect(existing.name == "Unsaved edit")
        #expect(context.hasChanges)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<HostRecord>()).first?.name == "Original")
    }

    @Test func failedSaveRemovesOnlyThisImportsInsertions() throws {
        enum SaveError: Error, Equatable { case failed }
        let container = try makeContainer()
        let context = ModelContext(container)
        let edited = HostRecord(name: "Original", hostname: "existing", username: "alice")
        let deleted = HostRecord(name: "Delete me", hostname: "deleted", username: "alice")
        context.insert(edited)
        context.insert(deleted)
        try context.save()
        edited.name = "Pending edit"
        context.delete(deleted)
        let unrelated = HostRecord(name: "Unrelated insert", hostname: "unrelated", username: "alice")
        context.insert(unrelated)
        #expect(throws: SaveError.failed) {
            try TailscaleHostImport.register([device()], username: "alice", in: context) { _ in throw SaveError.failed }
        }
        #expect(edited.name == "Pending edit")
        #expect(context.hasChanges)
        #expect(context.deletedModelsArray.contains { $0.persistentModelID == deleted.persistentModelID })
        #expect(context.insertedModelsArray.contains { $0.persistentModelID == unrelated.persistentModelID })
        try context.save()
        let fresh = ModelContext(container)
        let records = try fresh.fetch(FetchDescriptor<HostRecord>())
        #expect(Set(records.map(\.hostname)) == ["existing", "unrelated"])
        #expect(records.first(where: { $0.hostname == "existing" })?.name == "Pending edit")
    }

    @Test func noChangesNeverSavesTheCallersOtherEdits() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(HostRecord(name: "Pending", hostname: "server.tailnet.ts.net", username: "alice"))
        let save: (ModelContext) throws -> Void = { _ in Issue.record("An empty import must not save unrelated changes") }
        #expect(try TailscaleHostImport.register([], username: "alice", in: context, save: save) == .init(added: 0, skipped: 0))
        #expect(try TailscaleHostImport.register([device()], username: "alice", in: context, save: save) == .init(added: 0, skipped: 1))
        #expect(context.hasChanges)
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<HostRecord>()) == 0)
    }

    @Test func shortcutTextNormalizesNamesAddressesAndDuplicates() throws {
        let result = try TailscaleHostImport.candidates(from: [
            "  SERVER.Tailnet.ts.net. \r\n\nserver.tailnet.ts.net\n  laptop  ",
            "100.64.0.1\n FD7A:115C:A1E0:0:0:0:0:2 \nfd7a:115c:a1e0::2"
        ])
        #expect(result.map(\.id) == ["server.tailnet.ts.net", "laptop", "100.64.0.1", "fd7a:115c:a1e0::2"])
        #expect(result.map(\.name) == ["server", "laptop", "100.64.0.1", "fd7a:115c:a1e0::2"])
        #expect(result.map(\.hostname) == result.map(\.id))
        #expect(result.map(\.addresses) == [[], [], ["100.64.0.1"], ["fd7a:115c:a1e0::2"]])
        #expect(result.allSatisfy { $0.os == nil })
    }

    @Test func shortcutTextRejectsAnyInvalidEntryWithoutReturningPartialResults() {
        #expect(throws: TailscaleHostImportError.invalidHostname) {
            try TailscaleHostImport.candidates(from: ["good.tailnet.ts.net", "ssh://bad", "another"])
        }
        #expect(throws: TailscaleHostImportError.invalidHostname) {
            try TailscaleHostImport.candidates(from: ["good.tailnet.ts.net\n100.64.0.1:22"])
        }
    }

    @Test func emptyShortcutTextProducesNoCandidates() throws {
        #expect(try TailscaleHostImport.candidates(from: []).isEmpty)
        #expect(try TailscaleHostImport.candidates(from: ["", " \n\r\n\t "]).isEmpty)
    }

    @Test func shortcutHostCountIsLimitedTo512NonemptyEntries() throws {
        let hosts = (0..<512).map { "host-\($0)" }
        #expect(try TailscaleHostImport.candidates(from: hosts).count == 512)
        #expect(throws: TailscaleHostImportError.tooManyHosts) {
            try TailscaleHostImport.candidates(from: hosts + ["one-more"])
        }
        #expect(throws: TailscaleHostImportError.tooManyHosts) {
            try TailscaleHostImport.candidates(from: [Array(repeating: "same-host", count: 513).joined(separator: "\n")])
        }
    }

    @Test func shortcutUTF8InputLimitIncludesTrimmedWhitespace() throws {
        let boundary = "host" + String(repeating: " ", count: 65_532)
        #expect(try TailscaleHostImport.candidates(from: [boundary]).map(\.hostname) == ["host"])
        #expect(throws: TailscaleHostImportError.inputTooLarge) {
            try TailscaleHostImport.candidates(from: [boundary, " "])
        }
        #expect(throws: TailscaleHostImportError.inputTooLarge) {
            try TailscaleHostImport.candidates(from: [String(repeating: "あ", count: 21_846)])
        }
    }
}
