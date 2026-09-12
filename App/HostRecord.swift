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
    var createdAt: Date

    init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22,
         username: String, authentication: String = "password",
         terminalType: String = "xterm-256color") {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authentication = authentication
        self.terminalType = terminalType
        self.createdAt = Date()
    }

    var sshHost: SSHHost {
        SSHHost(id: id, name: name, hostname: hostname, port: port, username: username,
                authentication: authentication == "privateKey" ? .privateKey : .password,
                terminalType: terminalType)
    }
}
