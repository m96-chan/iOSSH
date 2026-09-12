import NIOCore
@preconcurrency import NIOSSH

enum SSHConnectionProbe {
    /// The dependency has no public arbitrary global-request/keepalive API. Opening and
    /// immediately closing an unused channel gets a protocol response without executing a
    /// command, allocating a PTY, or disturbing the existing interactive shell. A refusal
    /// (for example, MaxSessions) also proves the authenticated peer is responding.
    static func start(on transport: Channel) -> EventLoopFuture<Void> {
        transport.eventLoop.flatSubmit {
            guard transport.isActive else { return transport.eventLoop.makeFailedFuture(SSHSessionError.disconnected) }
            let opened = transport.eventLoop.makePromise(of: Channel.self)
            do {
                let ssh = try transport.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                // NIO resolves this promise only after the server's open confirmation.
                ssh.createChannel(opened) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
            } catch { opened.fail(error) }
            return opened.futureResult.map { child in
                child.close(promise: nil)
            }.flatMapErrorThrowing { error in
                guard let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected else { throw error }
            }
        }
    }

    /// Cancel only the observer when the app backgrounds again. The pending open remains
    /// bounded to one per SSHSession and is closed on response or transport shutdown.
    static func wait(for response: EventLoopFuture<Void>, timeout: TimeAmount = .seconds(30)) async throws {
        let completed = response.eventLoop.makePromise(of: Void.self)
        let deadline = response.eventLoop.scheduleTask(in: timeout) {
            completed.fail(SSHSessionError.connectionTimedOut)
        }
        response.cascade(to: completed)
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await completed.futureResult.get()
        } onCancel: {
            completed.fail(CancellationError())
        }
    }
}
