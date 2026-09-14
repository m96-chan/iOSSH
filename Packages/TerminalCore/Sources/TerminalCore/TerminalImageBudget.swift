import Foundation

/// A holder of decoded image pixels whose bytes are accounted against a `TerminalImageBudget`.
///
/// The budget started out reaching into `KittyGraphicsStore` directly, which is where
/// `SwiftTermEngine` keeps its pixels. It is not where every engine keeps them: the
/// libghostty-vt engine decodes the library's images into a cache of its own and is not a
/// graphics store. Naming the one thing the budget actually needs — somewhere to send an
/// eviction — lets both account through the same ceiling, so a memory warning and a
/// cross-session eviction reach either engine's pixels the same way (#26).
///
/// Conformers are held weakly and their entries reaped once they are gone, so nothing here has
/// to be unregistered from a deinit that cannot hop back to the parser's isolation.
@TerminalParserActor public protocol TerminalImageBudgetOwner: AnyObject {
    /// Drop the decoded pixels for this image. The budget has already removed its own
    /// accounting entry before calling, so releasing the same id again from here would
    /// subtract bytes twice.
    func evictImage(_ id: UInt32)
}

/// A decoded-image cache budget shared by the terminal sessions in one workspace.
/// It does not retain engines, snapshots or image bytes. Callers must release
/// snapshots when `TerminalEngine.onImageCacheInvalidated` fires so evicted data
/// cannot remain alive in a hidden view's last frame.
@TerminalParserActor public final class TerminalImageBudget {
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let imageID: UInt32
    }
    private struct Entry {
        weak var owner: (any TerminalImageBudgetOwner)?
        let bytes: Int
        var tick: UInt64
    }

    public let maximumTotalBytes: Int
    private var entries: [Key: Entry] = [:]
    private var retainedBytes = 0
    private var tick: UInt64 = 0

    /// The budget is created by the UI that owns a workspace, before it can await the
    /// parser; only its contents are parser state.
    public nonisolated init(maximumTotalBytes: Int = 64 * 1024 * 1024) {
        self.maximumTotalBytes = min(256 * 1024 * 1024, max(4, maximumTotalBytes))
    }

    /// Bytes owned by live stores; immutable snapshots can temporarily share them.
    public var totalBytes: Int {
        removeExpiredOwners()
        return retainedBytes
    }

    /// Release cached images from all sessions after a memory warning. Terminal
    /// cells, scrollback, cursor state and connections are unaffected.
    public func removeAll() {
        for key in Array(entries.keys) { evict(key) }
    }

    /// Account `bytes` for one image, evicting the least recently used entries of any session
    /// in the workspace until it fits. False means the image is larger than the whole ceiling
    /// and the caller should not decode it at all.
    ///
    /// Eviction runs before this returns and can reach back into the calling owner, so a
    /// caller must reserve before it stores the pixels rather than after.
    @discardableResult
    public func reserve(bytes: Int, imageID: UInt32, owner: any TerminalImageBudgetOwner) -> Bool {
        guard bytes > 0, bytes <= maximumTotalBytes else { return false }
        removeExpiredOwners()
        let key = Key(owner: ObjectIdentifier(owner), imageID: imageID)
        release(imageID: imageID, owner: owner)
        while retainedBytes + bytes > maximumTotalBytes {
            guard let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key else { return false }
            evict(oldest)
        }
        tick &+= 1
        entries[key] = Entry(owner: owner, bytes: bytes, tick: tick)
        retainedBytes += bytes
        return true
    }

    /// Marks an image as used, so the oldest entry the next eviction picks is the one nothing
    /// has drawn for the longest.
    public func touch(imageID: UInt32, owner: any TerminalImageBudgetOwner) {
        let key = Key(owner: ObjectIdentifier(owner), imageID: imageID)
        guard entries[key] != nil else { return }
        tick &+= 1
        entries[key]?.tick = tick
    }

    /// Gives back one image's bytes without calling the owner back, for an owner that has
    /// already dropped the pixels itself.
    public func release(imageID: UInt32, owner: any TerminalImageBudgetOwner) {
        let key = Key(owner: ObjectIdentifier(owner), imageID: imageID)
        if let entry = entries.removeValue(forKey: key) { retainedBytes -= entry.bytes }
    }

    /// Gives back every image one owner holds, for a reset that clears its cache wholesale.
    public func releaseAll(owner: any TerminalImageBudgetOwner) {
        let ownerID = ObjectIdentifier(owner)
        for key in Array(entries.keys) where key.owner == ownerID {
            if let entry = entries.removeValue(forKey: key) { retainedBytes -= entry.bytes }
        }
    }

    private func evict(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        retainedBytes -= entry.bytes
        entry.owner?.evictImage(key.imageID)
    }

    private func removeExpiredOwners() {
        // An owner can be deallocated outside MainActor. Weak ownership releases its
        // bytes immediately; reap the metadata before every accounting decision.
        for key in Array(entries.keys) where entries[key]?.owner == nil {
            if let entry = entries.removeValue(forKey: key) { retainedBytes -= entry.bytes }
        }
    }
}
