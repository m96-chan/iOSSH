import Foundation

/// A decoded-image cache budget shared by the terminal sessions in one workspace.
/// It does not retain engines, snapshots or image bytes. Callers must release
/// snapshots when `TerminalEngine.onImageCacheInvalidated` fires so evicted data
/// cannot remain alive in a hidden view's last frame.
@MainActor public final class TerminalImageBudget {
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let imageID: UInt32
    }
    private struct Entry {
        weak var owner: KittyGraphicsStore?
        let bytes: Int
        var tick: UInt64
    }

    public let maximumTotalBytes: Int
    private var entries: [Key: Entry] = [:]
    private var retainedBytes = 0
    private var tick: UInt64 = 0

    public init(maximumTotalBytes: Int = 64 * 1024 * 1024) {
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

    func reserve(bytes: Int, imageID: UInt32, owner: KittyGraphicsStore) -> Bool {
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

    func touch(imageID: UInt32, owner: KittyGraphicsStore) {
        let key = Key(owner: ObjectIdentifier(owner), imageID: imageID)
        guard entries[key] != nil else { return }
        tick &+= 1
        entries[key]?.tick = tick
    }

    func release(imageID: UInt32, owner: KittyGraphicsStore) {
        let key = Key(owner: ObjectIdentifier(owner), imageID: imageID)
        if let entry = entries.removeValue(forKey: key) { retainedBytes -= entry.bytes }
    }

    func releaseAll(owner: KittyGraphicsStore) {
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
        // A store can be deallocated outside MainActor. Weak ownership releases its
        // bytes immediately; reap the metadata before every accounting decision.
        for key in Array(entries.keys) where entries[key]?.owner == nil {
            if let entry = entries.removeValue(forKey: key) { retainedBytes -= entry.bytes }
        }
    }
}
