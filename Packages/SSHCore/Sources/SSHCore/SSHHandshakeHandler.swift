import NIOCore
@preconcurrency import NIOSSH

/// Authentication completion is driven by verified SSH protocol events, never socket connection alone.
/// Mutable state is confined to the channel's event loop.
final class SSHHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let authenticated: EventLoopPromise<Void>
    private let onBanner: @Sendable (String) -> Void
    private var isAuthenticating = true
    private var bannerCount = 0
    private var remainingBannerBytes = 16_384

    init(authenticated: EventLoopPromise<Void>, onBanner: @escaping @Sendable (String) -> Void = { _ in }) {
        self.authenticated = authenticated
        self.onBanner = onBanner
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, isAuthenticating {
            isAuthenticating = false
            authenticated.succeed(())
        } else if let banner = event as? NIOUserAuthBannerEvent, isAuthenticating,
                  bannerCount < 16, remainingBannerBytes > 0 {
            // Limit individual messages and the whole handshake before crossing to the UI.
            // Scalar boundaries preserve valid UTF-8 without allowing huge composed graphemes.
            bannerCount += 1
            let byteLimit = min(4_096, remainingBannerBytes)
            var message = ""
            var usedBytes = 0
            for scalar in banner.message.unicodeScalars {
                let count = scalar.utf8.count
                guard usedBytes + count <= byteLimit else { break }
                message.unicodeScalars.append(scalar)
                usedBytes += count
            }
            remainingBannerBytes -= usedBytes
            if !message.isEmpty { onBanner(message) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        isAuthenticating = false
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        isAuthenticating = false
        authenticated.fail(SSHSessionError.disconnected)
        context.fireChannelInactive()
    }
}
