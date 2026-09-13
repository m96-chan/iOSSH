import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import SSHCore

// Test fixtures are used only synchronously on the embedded event loop/main actor.
private final class RequestRecorder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    var requests: [Any] = []
    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        requests.append(event)
        promise?.succeed(())
    }
}

private final class ReadyResult: @unchecked Sendable {
    var result: Result<Void, Error>?
}

struct PTYHandlerTests {
    @Test @MainActor func waitsForPTYAndShellAcknowledgements() throws {
        let channel = EmbeddedChannel()
        let recorder = RequestRecorder()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let result = ReadyResult()
        ready.futureResult.whenComplete { result.result = $0 }
        let handler = PTYHandler(term: "xterm-256color", columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 504, ready: ready)
        try channel.pipeline.addHandlers(recorder, handler).wait()
        channel.pipeline.fireChannelActive()
        #expect(recorder.requests.count == 1)
        // Image tools read the pixel size from the remote tty; zero makes them refuse to draw.
        let request = try #require(recorder.requests.first as? SSHChannelRequestEvent.PseudoTerminalRequest)
        #expect(request.terminalCharacterWidth == 80)
        #expect(request.terminalRowHeight == 24)
        #expect(request.terminalPixelWidth == 800)
        #expect(request.terminalPixelHeight == 504)
        #expect(result.result == nil)
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.last is SSHChannelRequestEvent.ShellRequest)
        #expect(result.result == nil)
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        guard case .success = result.result else { Issue.record("Shell did not become ready"); return }
        _ = try channel.finish()
    }

    @Test @MainActor func rejectedPTYFailsBeforeShell() throws {
        let channel = EmbeddedChannel()
        let recorder = RequestRecorder()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let result = ReadyResult()
        ready.futureResult.whenComplete { result.result = $0 }
        try channel.pipeline.addHandlers(recorder, PTYHandler(term: "xterm", columns: 80, rows: 24,
                                                             pixelWidth: 0, pixelHeight: 0, ready: ready)).wait()
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireUserInboundEventTriggered(ChannelFailureEvent())
        #expect(recorder.requests.count == 1)
        guard case .failure(let error) = result.result else { Issue.record("Rejection was ignored"); return }
        #expect(error as? SSHSessionError == .requestRejected)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    @Test @MainActor func byteStreamPreservesBinaryAndStderrOrdering() async throws {
        let channel = EmbeddedChannel()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let handler = PTYHandler(term: "xterm", columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0, ready: ready)
        try channel.pipeline.syncOperations.addHandlers(RequestRecorder(), handler)
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        let first: [UInt8] = [0, 27, 91, 255, 195]
        let second: [UInt8] = [169, 10]
        _ = try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: first))))
        _ = try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(bytes: second))))
        _ = try channel.finish()
        var received = Data()
        for try await chunk in handler.output { received.append(chunk) }
        #expect(received == Data(first + second))
    }

    /// A burst such as a large directory listing outruns terminal parsing on the main actor. The
    /// unconsumed output must wait for the reader instead of being dropped and closing the shell.
    @Test @MainActor func outputOutrunningTheReaderKeepsTheShellOpen() async throws {
        let channel = EmbeddedChannel()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let handler = PTYHandler(term: "xterm", columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0, ready: ready)
        try channel.pipeline.syncOperations.addHandlers(RequestRecorder(), handler)
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        let chunk = [UInt8](repeating: 0x61, count: 1024)
        for _ in 0..<1024 {
            _ = try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: chunk))))
        }
        // `finish` rejects an already closed channel, so it fails here if the burst closed the shell.
        _ = try channel.finish()
        var received = 0
        for try await data in handler.output { received += data.count }
        #expect(received == chunk.count * 1024)
    }
}
