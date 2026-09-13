import Darwin
import Foundation
import SSHCore
import SwiftData

struct TailscaleDeviceCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let hostname: String
    let addresses: [String]
    let os: String?

    init(id: String, name: String, hostname: String, addresses: [String] = [], os: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.addresses = addresses
        self.os = os
    }
}

struct TailscaleHostImportResult: Equatable, Sendable {
    let added: Int
    let skipped: Int
}

enum TailscaleHostImportError: Error, LocalizedError, Equatable, Sendable {
    case invalidName
    case invalidHostname
    case invalidAddress
    case tooManyHosts
    case inputTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidName: "A selected device has an empty or invalid name."
        case .invalidHostname: "The imported host list contains an invalid DNS name or IP address."
        case .invalidAddress: "A selected device contains an invalid IP address."
        case .tooManyHosts: "Import at most 512 devices at a time."
        case .inputTooLarge: "The device list exceeds 64 KiB."
        }
    }
}

@MainActor
enum TailscaleHostImport {
    /// Accepts Shortcuts' MagicDNS/IP output as separate strings or newline-separated text.
    /// Limits apply to the supplied UTF-8 text and nonempty host entries before deduplication.
    static func candidates(from hostnames: [String]) throws -> [TailscaleDeviceCandidate] {
        var totalBytes = 0
        for value in hostnames {
            let count = value.utf8.count
            guard count <= 65_536 - totalBytes else { throw TailscaleHostImportError.inputTooLarge }
            totalBytes += count
        }
        var candidates: [TailscaleDeviceCandidate] = []
        var represented: Set<String> = []
        var hostCount = 0
        for value in hostnames {
            for line in value.components(separatedBy: .newlines) {
                let hostname = trim(line)
                guard !hostname.isEmpty else { continue }
                hostCount += 1
                guard hostCount <= 512 else { throw TailscaleHostImportError.tooManyHosts }
                guard let identity = hostnameIdentity(hostname), let normalized = normalizedHostname(hostname) else {
                    throw TailscaleHostImportError.invalidHostname
                }
                guard represented.insert(identity).inserted else { continue }
                let isAddress = ipIdentity(normalized) != nil
                let name = isAddress ? normalized : normalized.split(separator: ".").first.map(String.init) ?? normalized
                candidates.append(.init(id: normalized, name: name, hostname: normalized,
                                        addresses: isAddress ? [normalized] : []))
            }
        }
        return candidates
    }

    static func register(_ selected: [TailscaleDeviceCandidate], username: String,
                         in context: ModelContext) throws -> TailscaleHostImportResult {
        try register(selected, username: username, in: context, save: { try $0.save() })
    }

    /// The injected save operation lets tests reproduce a failed persistence operation without
    /// corrupting a real store. Production callers use the overload above.
    static func register(_ selected: [TailscaleDeviceCandidate], username: String,
                         in context: ModelContext, save: (ModelContext) throws -> Void) throws -> TailscaleHostImportResult {
        guard !selected.isEmpty else { return .init(added: 0, skipped: 0) }
        let username = trim(username)

        // Validate the whole selection, including candidates that may later be skipped, before
        // inserting anything into the caller's context.
        let prepared = try selected.map { candidate -> PreparedDevice in
            let name = trim(candidate.name)
            let hostname = trim(candidate.hostname)
            guard !name.isEmpty, name.utf8.count <= 255,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TailscaleHostImportError.invalidName
            }
            guard let hostnameAlias = hostnameIdentity(hostname) else {
                throw TailscaleHostImportError.invalidHostname
            }
            var aliases: Set<String> = [hostnameAlias]
            for address in candidate.addresses {
                guard let alias = ipIdentity(trim(address)) else { throw TailscaleHostImportError.invalidAddress }
                aliases.insert(alias)
            }
            let host = SSHHost(name: name, hostname: hostname, port: 22, username: username,
                               authentication: .tailscale, terminalType: "xterm-256color")
            try host.validate()
            return PreparedDevice(host: host, aliases: aliases)
        }

        let existing = try context.fetch(FetchDescriptor<HostRecord>())
        var represented = Set(existing.compactMap { record -> String? in
            guard record.port == 22, trim(record.username) == username else { return nil }
            return hostnameIdentity(trim(record.hostname))
        })

        // IP aliases also connect repeated entries within the selection. Merging these groups
        // first makes the result independent of whether a shared alias appears earlier or later.
        let groups = aliasGroups(prepared)
        var pending: [SSHHost] = []
        for (index, device) in prepared.enumerated() {
            let aliases = groups[index]
            if aliases.isDisjoint(with: represented) { pending.append(device.host) }
            represented.formUnion(aliases)
        }

        guard !pending.isEmpty else { return .init(added: 0, skipped: selected.count) }
        var inserted: [HostRecord] = []
        do {
            for host in pending {
                let record = HostRecord(id: host.id, name: host.name, hostname: host.hostname, port: host.port,
                                        username: host.username, authentication: host.authentication.rawValue,
                                        terminalType: host.terminalType)
                context.insert(record)
                inserted.append(record)
            }
            try save(context)
        } catch {
            // rollback() would also discard unrelated edits, pending inserts, and deletions.
            // Only undo the records inserted by this invocation; leave all other work intact.
            for record in inserted { context.delete(record) }
            throw error
        }
        return .init(added: inserted.count, skipped: selected.count - inserted.count)
    }

    private struct PreparedDevice {
        let host: SSHHost
        let aliases: Set<String>
    }

    private static func aliasGroups(_ devices: [PreparedDevice]) -> [Set<String>] {
        var parents = Array(devices.indices)
        var owner: [String: Int] = [:]
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current { current = parents[current] }
            return current
        }
        for (index, device) in devices.enumerated() {
            for alias in device.aliases {
                if let previous = owner[alias] { parents[root(index)] = root(previous) }
                else { owner[alias] = index }
            }
        }
        var aliasesByRoot: [Int: Set<String>] = [:]
        for (index, device) in devices.enumerated() {
            aliasesByRoot[root(index), default: []].formUnion(device.aliases)
        }
        return devices.indices.map { aliasesByRoot[root($0), default: []] }
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hostnameIdentity(_ value: String) -> String? {
        if let ip = ipIdentity(value) { return ip }
        var dns = value.lowercased()
        if dns.hasSuffix(".") { dns.removeLast() }
        guard !dns.isEmpty, dns.utf8.count <= 253 else { return nil }
        // Do not let invalid IPv4 notation fall through as an apparently valid numeric DNS name.
        guard !dns.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        for label in dns.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63, bytes.first != 45, bytes.last != 45,
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                return nil
            }
        }
        return "dns:" + dns
    }

    private static func ipIdentity(_ value: String) -> String? {
        // Darwin's inet_pton accepts some noncanonical forms, including scope suffixes and
        // zero-prefixed IPv4 components. Apply a strict textual check before asking it to parse.
        guard !value.isEmpty, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46
        }) else { return nil }
        if !value.contains(":") {
            guard isStrictIPv4(value) else { return nil }
        } else if value.contains(".") {
            guard let suffix = value.split(separator: ":", omittingEmptySubsequences: false).last,
                  isStrictIPv4(String(suffix)) else { return nil }
        }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return "ipv4:" + withUnsafeBytes(of: ipv4) { Data($0).base64EncodedString() }
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return "ipv4:" + Data(bytes.suffix(4)).base64EncodedString()
            }
            return "ipv6:" + Data(bytes).base64EncodedString()
        }
        return nil
    }

    private static func isStrictIPv4(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            let bytes = Array(component.utf8)
            guard (1...3).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0) }),
                  bytes.count == 1 || bytes.first != 48,
                  let number = Int(component), number <= 255 else { return false }
            return true
        }
    }

    private static func normalizedHostname(_ value: String) -> String? {
        guard let identity = hostnameIdentity(value) else { return nil }
        if identity.hasPrefix("dns:") { return String(identity.dropFirst(4)) }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }
}
