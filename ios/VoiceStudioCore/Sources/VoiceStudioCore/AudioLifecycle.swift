import Foundation

/// Small ordered cache. Reinserting an ID makes it the newest FIFO entry.
public struct FIFOAudioCache: Sendable {
    public let capacity: Int
    private var order: [UUID] = []
    private var assets: [UUID: AudioAsset] = [:]

    public init(capacity: Int) {
        precondition(capacity > 0, "Cache capacity must be positive")
        self.capacity = capacity
    }

    public var count: Int { order.count }
    public func asset(for id: UUID) -> AudioAsset? { assets[id] }
    public var values: [AudioAsset] { order.compactMap { assets[$0] } }

    @discardableResult
    public mutating func insert(_ asset: AudioAsset) -> [AudioAsset] {
        if assets[asset.id] != nil { order.removeAll { $0 == asset.id } }
        assets[asset.id] = asset
        order.append(asset.id)
        var evicted: [AudioAsset] = []
        while order.count > capacity {
            let id = order.removeFirst()
            if let removed = assets.removeValue(forKey: id) { evicted.append(removed) }
        }
        return evicted
    }

    public mutating func replace(_ asset: AudioAsset) {
        guard assets[asset.id] != nil else { return }
        assets[asset.id] = asset
    }
}

/// Applies separate Preview/Generate FIFO policies and delegates file cleanup to the store.
public final class AudioLifecycle {
    public let fileStore: AudioFileStore
    private var previewCache = FIFOAudioCache(capacity: 5)
    private var generatedCache = FIFOAudioCache(capacity: 2)

    public init(fileStore: AudioFileStore) { self.fileStore = fileStore }

    public func cache(_ asset: AudioAsset, as kind: AudioCacheKind) throws {
        let evicted = insert(asset, as: kind)
        for item in evicted { try fileStore.removeTemporaryAudio(item) }
    }

    public func cachedAsset(id: UUID, as kind: AudioCacheKind) -> AudioAsset? {
        cacheValue(kind).asset(for: id)
    }

    public func cachedAssets(as kind: AudioCacheKind) -> [AudioAsset] { cacheValue(kind).values }

    public func save(id: UUID, from kind: AudioCacheKind) throws -> AudioAsset? {
        guard let cached = cachedAsset(id: id, as: kind) else { return nil }
        let saved = try fileStore.promoteToPersistent(cached)
        replace(saved, as: kind)
        return saved
    }

    private func cacheValue(_ kind: AudioCacheKind) -> FIFOAudioCache {
        kind == .preview ? previewCache : generatedCache
    }

    private func insert(_ asset: AudioAsset, as kind: AudioCacheKind) -> [AudioAsset] {
        if kind == .preview { return previewCache.insert(asset) }
        return generatedCache.insert(asset)
    }

    private func replace(_ asset: AudioAsset, as kind: AudioCacheKind) {
        if kind == .preview { previewCache.replace(asset) } else { generatedCache.replace(asset) }
    }
}