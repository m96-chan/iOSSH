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

    init(term: String, columns: Int, rows: Int, ready: EventLoopPromise<Void>) {
        self.request = .init(wantReply: true, term: term, terminalCharacterWidth: columns,
                             terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                             terminalModes: .init([:]))
        self.ready = ready
        // Reads are demanded one batch at a time, so the stream only holds what the terminal has
        // been handed and has yet to consume. A bounded policy would instead discard bytes of a
        // burst such as a large directory listing and end an otherwise healthy session.
        (self.output, self.continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
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
                let written = context.eventLoop.makePromise(of: Void.self)
                written.futureResult.whenFailure { [self] error in finish(error) }
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: written)
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
