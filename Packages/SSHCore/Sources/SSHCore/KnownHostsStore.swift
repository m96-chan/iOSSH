import Foundation
import Crypto

public struct HostKeyChallenge: Sendable, Equatable {
    public let hostname: String
    public let port: Int
    public let algorithm: String
    public let fingerprint: String
}

public enum HostKeyError: Error, LocalizedError, Equatable, Sendable {
    case rejected
    case changed(hostname: String, port: Int, expected: String, received: String)
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .rejected: "The server host key was not trusted."
        case .invalidKey: "The server provided an invalid host key."
        case let .changed(hostname, port, expected, received):
            "HOST KEY CHANGED for \(hostname):\(port). Connection blocked. Expected \(expected); received \(received). Verify the change with the server administrator before removing the stored key."
        }
    }
}

/// Persistent TOFU trust. Corrupt/unreadable stores fail closed, and changed keys never prompt for trust.
public actor KnownHostsStore {
    private struct Record: Codable {
        let algorithm: String
        let key: Data
    }

    private let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("iOSSH", isDirectory: true)
            .appendingPathComponent("known-hosts.json")
    }

    public static func fingerprint(of key: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public func verify(hostname: String, port: Int, algorithm: String, key: Data,
                       confirm: @Sendable (HostKeyChallenge) async -> Bool) async throws {
        guard !algorithm.isEmpty, !key.isEmpty else { throw HostKeyError.invalidKey }
        let identity = Self.identity(hostname: hostname, port: port)
        let challenge = HostKeyChallenge(hostname: hostname, port: port, algorithm: algorithm,
                                         fingerprint: Self.fingerprint(of: key))
        if let stored = try read()[identity] {
            try check(stored, challenge: challenge, key: key)
            return
        }
        guard await confirm(challenge) else { throw HostKeyError.rejected }
        try Task.checkCancellation()
        // The actor can reenter while the confirmation UI is visible. Recheck before writing.
        var records = try read()
        if let stored = records[identity] {
            try check(stored, challenge: challenge, key: key)
            return
        }
        records[identity] = Record(algorithm: algorithm, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Only call after independently verifying a legitimate server key replacement.
    public func remove(hostname: String, port: Int) throws {
        var records = try read()
        records.removeValue(forKey: Self.identity(hostname: hostname, port: port))
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    private func check(_ stored: Record, challenge: HostKeyChallenge, key: Data) throws {
        guard stored.algorithm == challenge.algorithm, stored.key == key else {
            throw HostKeyError.changed(hostname: challenge.hostname, port: challenge.port,
                                      expected: Self.fingerprint(of: stored.key), received: challenge.fingerprint)
        }
    }

    private func read() throws -> [String: Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: url))
    }

    private static func identity(hostname: String, port: Int) -> String {
        var name = hostname.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        return "[\(name)]:\(port)"
    }
}
