import NIOCore
@preconcurrency import NIOSSH

/// Authentication completion is driven by verified SSH protocol events, never socket connection alone.
final class SSHHandshakeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) { self.authenticated = authenticated }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(SSHSessionError.disconnected)
        context.fireChannelInactive()
    }
}
