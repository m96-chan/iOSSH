import Foundation
import SSHCore
import SwiftData

@Model
final class HostRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authentication: String
    var terminalType: String
    /// Sent as `LANG`; empty sends nothing. Defaulted so records saved before this existed
    /// keep the behaviour they had.
    var locale: String = ""
    var createdAt: Date

    init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22,
         username: String, authentication: String = "password",
         terminalType: String = "xterm-256color", locale: String = "") {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authentication = authentication
        self.terminalType = terminalType
        self.locale = locale
        self.createdAt = Date()
    }

    var sshHost: SSHHost {
        SSHHost(id: id, name: name, hostname: hostname, port: port, username: username,
                authentication: SSHAuthentication(rawValue: authentication) ?? .password,
                terminalType: terminalType, locale: locale)
    }
}
