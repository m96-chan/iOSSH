import AVFoundation
import AVKit
import CoreVideo
import Metal
import UIKit

/// Keeps the terminal on screen in a Picture in Picture window while the app is not frontmost
/// (#39), which also keeps the app out of suspension and so keeps its SSH session alive (#46).
///
/// PiP was built for video and consumes `CMSampleBuffer`s through an `AVSampleBufferDisplayLayer`.
/// The terminal draws through Metal into an `MTKView`, so the frames it shows have to be produced
/// a second time into a pixel buffer. `MetalRenderer.render(into:background:completion:)` is that
/// second destination; everything here is the plumbing that turns its output into something
/// `AVPictureInPictureController` will accept.
///
/// The window is not interactive. PiP offers its own controls and nothing else, so this is for
/// watching a build finish, not for driving a shell.
@MainActor
public final class TerminalPictureInPicture: NSObject {
    /// Whether PiP is on screen. The renderer and the snapshot loop consult this to decide
    /// whether being in the background means they should stop.
    public private(set) var isActive = false

    /// Whether the window wants this frame.
    ///
    /// While a window is up, every frame: it is what the person is looking at. Before one is, the
    /// controller still needs *something* in its layer or it will never report itself possible
    /// and the system will never start a window — but it does not need a stream to decide that,
    /// so an idle terminal hands it one frame a second rather than every frame. The difference
    /// is a second full-screen render per frame of foreground drawing, which is not worth
    /// spending on a window nobody has opened.
    var needsFrame: Bool {
        if isActive { return true }
        return ContinuousClock.now - lastIdleFrame > .seconds(1)
    }

    private var lastIdleFrame = ContinuousClock.now - .seconds(60)

    /// Sized to the view it draws for, and kept underneath it. PiP will not start automatically
    /// from a layer that is not really on screen, and a one-pixel layer is not.
    public func layoutLayer(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.opacity = 0
        CATransaction.commit()
    }

    /// Called when the window needs another frame.
    public var onFrameNeeded: (@MainActor () -> Void)?
    /// Called as the window appears and disappears. Being in the background normally means
    /// nothing is watching, and the app stops producing frames on that basis; this is the one
    /// case where something is.
    public var onActiveChange: (@MainActor (Bool) -> Void)?

    private let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var pool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    private var poolSize = CGSize.zero
    private var frameIndex: Int64 = 0
    private let device: any MTLDevice

    public init?(device: any MTLDevice, container: CALayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.device = device
        super.init()
        // Transparent, not small and not hidden. A sublayer composites *above* its parent's own
        // contents, and this one's parent is the Metal layer the terminal draws into — so a
        // full-size layer here covers the terminal with its own frames, which is exactly what it
        // did the first time this was tried. Zero opacity keeps it laid out at the size PiP wants
        // to read while showing nothing; `isHidden` would take it out of the hierarchy and PiP
        // will not start from a layer that is not in one.
        layer.opacity = 0
        layer.isOpaque = false
        layer.videoGravity = .resizeAspect
        container.insertSublayer(layer, at: 0)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else { return nil }
        textureCache = cache

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer,
                                                               playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        // Entering automatically is the whole point: a person who presses the home button while
        // watching output should not have to have pressed a button first.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        self.controller = controller
    }

    /// Prepares the audio session PiP requires.
    ///
    /// `AVPictureInPictureController` will not start without an active audio session, which is an
    /// awkward requirement for a terminal that plays nothing. `.mixWithOthers` is what keeps that
    /// from being rude: without it, activating the session pauses whatever the person is
    /// listening to, and an SSH client silencing someone's music to show a window would be
    /// indefensible.
    public func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Nothing to show the person here, and nothing to do about it: PiP simply will not
            // start, and the app behaves as it did before this existed.
        }
    }

    /// Hands the window one frame, rendered at `size` in pixels.
    func present(_ renderer: MetalRenderer, size: CGSize, background: MTLClearColor) {
        guard size.width >= 16, size.height >= 16 else { return }
        guard let buffer = makePixelBuffer(size: size),
              let texture = makeTexture(from: buffer, size: size) else { return }
        // The Metal completion handler runs off the main actor, and `CVPixelBuffer` carries no
        // `Sendable` annotation, so the hand-back needs a box to say what the pool already
        // guarantees: the GPU has finished with this buffer and nothing else holds it.
        let handoff = FrameHandoff(buffer: buffer)
        renderer.render(into: texture, background: background) { [weak self] in
            Task { @MainActor in self?.enqueue(handoff.buffer) }
        }
    }

    /// True once the window is up, so callers can keep feeding it.
    public func startIfPossible() {
        guard let controller, !controller.isPictureInPictureActive,
              controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: - Frame plumbing

    private struct FrameHandoff: @unchecked Sendable { let buffer: CVPixelBuffer }

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func makeTexture(from buffer: CVPixelBuffer, size: CGSize) -> (any MTLTexture)? {
        guard let textureCache else { return nil }
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
                                                        .bgra8Unorm, Int(size.width), Int(size.height), 0,
                                                        &wrapped) == kCVReturnSuccess,
              let wrapped else { return nil }
        return CVMetalTextureGetTexture(wrapped)
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        guard layer.status != .failed else {
            layer.flush()
            return
        }
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return }
        if !isActive { lastIdleFrame = .now }
        frameIndex += 1
        // Thirty frames a second of presentation stamps. The window is showing a terminal, not
        // playing a recording, so nothing seeks and the exact rate only has to be plausible.
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: buffer,
                                                       formatDescription: format,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return }
        layer.enqueue(sample)
    }
}

extension TerminalPictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Nothing to pause: the shell keeps writing whether or not anyone is watching.
    public nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       setPlaying playing: Bool) {}

    /// A live source. `.positiveInfinity` is what tells PiP to draw the live badge and leave out
    /// the scrubber, which is the truth here — there is nothing to seek in.
    public nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    public nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    public nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    public nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       skipByInterval skipInterval: CMTime) async {}
}

extension TerminalPictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
        onActiveChange?(true)
        onFrameNeeded?()
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        onActiveChange?(false)
        layer.flushAndRemoveImage()
    }

    public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                           failedToStartPictureInPictureWithError error: any Error) {
        isActive = false
        onActiveChange?(false)
    }
}

extension CGSize {
    static func * (size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}
