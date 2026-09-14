import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Mutable protocol state is accessed exclusively by its NIO channel event loop.
///
/// The channel this handler runs on has autoRead disabled, so inbound shell output arrives only
/// after the reader asks for it. `SSHSession` requests the next batch once the terminal has
/// consumed the previous one, which keeps unconsumed output inside the SSH receive window.
final class PTYHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    private enum State { case waitingForPTY, waitingForShell, running, closed }
    private var state = State.waitingForPTY
    private let request: SSHChannelRequestEvent.PseudoTerminalRequest
    private let ready: EventLoopPromise<Void>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    /// Shell output in arrival order. Reading it releases the next batch from the channel.
    let output: AsyncThrowingStream<Data, Error>

    private let environment: [String: String]

    init(term: String, columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int,
         environment: [String: String] = [:], ready: EventLoopPromise<Void>) {
        self.environment = environment
        // Programs that draw images read the pixel size from the remote tty's window size.
        // Reporting zero makes them refuse to draw, so the cell size measured on this device
        // travels with the grid size the shell is started with.
        self.request = .init(wantReply: true, term: term, terminalCharacterWidth: columns,
                             terminalRowHeight: rows, terminalPixelWidth: pixelWidth,
                             terminalPixelHeight: pixelHeight, terminalModes: .init([:]))
        self.ready = ready
        // Reads are demanded one batch at a time, so the stream only holds what the terminal has
        // been handed and has yet to consume. A bounded policy would instead discard bytes of a
        // burst such as a large directory listing and end an otherwise healthy session.
        (self.output, self.continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
    }

    /// `exec` runs its argument through the user's login shell, so this asks that shell to
    /// replace itself with a login shell carrying the variables. Values are single-quoted and
    /// any quote inside is escaped, so a locale string cannot become another command.
    static func loginShellCommand(_ environment: [String: String]) -> String? {
        guard !environment.isEmpty else { return nil }
        let assignments = environment.keys.sorted().map { name in
            let value = (environment[name] ?? "").replacingOccurrences(of: "'", with: "'\\''")
            return "\(name)='\(value)'"
        }
        return "exec env \(assignments.joined(separator: " ")) \"${SHELL:-/bin/sh}\" -l"
    }

    func channelActive(context: ChannelHandlerContext) {
        let written = context.eventLoop.makePromise(of: Void.self)
        written.futureResult.whenFailure { [self] error in finish(error) }
        context.triggerUserOutboundEvent(request, promise: written)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            switch state {
            case .waitingForPTY:
                state = .waitingForShell
                // Environment requests are the polite way to ask, and a server only honours
                // the names its AcceptEnv lists — macOS ships with that line commented out, so
                // LANG is dropped without a word. Sending them anyway costs nothing on a server
                // that does accept them, and the exec below covers the ones that do not.
                for name in environment.keys.sorted() {
                    context.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name,
                                                                  value: environment[name] ?? ""),
                        promise: nil)
                }
                let written = context.eventLoop.makePromise(of: Void.self)
                written.futureResult.whenFailure { [self] error in finish(error) }
                // Starting the login shell through exec puts the variables in its environment
                // directly, which no server configuration can refuse. Only worth the change of
                // mechanism when there is something to set; without it, ask for a shell.
                if let command = Self.loginShellCommand(environment) {
                    context.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                        promise: written)
                } else {
                    context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true),
                                                     promise: written)
                }
            case .waitingForShell:
                state = .running
                ready.succeed(())
            case .running, .closed: break
            }
        } else if event is ChannelFailureEvent {
            finish(SSHSessionError.requestRejected)
            context.close(promise: nil)
        } else if let event = event as? ChannelEvent, event == .inputClosed {
            finish(nil)
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        guard message.type == .channel || message.type == .stdErr else { return }
        switch continuation.yield(Data(buffer.readableBytesView)) {
        case .dropped:
            // Unreachable with an unbounded stream. Silent loss would corrupt the terminal, so a
            // buffering policy that ever discarded output must still end the session loudly.
            finish(SSHSessionError.outputOverflow)
            context.close(promise: nil)
        case .terminated:
            context.close(promise: nil)
        case .enqueued: break
        @unknown default: break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    private func finish(_ error: Error?) {
        guard state != .closed else { return }
        let wasReady = state == .running
        state = .closed
        if !wasReady { ready.fail(error ?? SSHSessionError.disconnected) }
        continuation.finish(throwing: error)
    }
}
