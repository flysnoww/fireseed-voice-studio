export class FifoCache {
  #entries = new Map();

  constructor(capacity, onEvict = () => {}) {
    if (!Number.isInteger(capacity) || capacity < 1) throw new TypeError('capacity must be a positive integer');
    this.capacity = capacity;
    this.onEvict = onEvict;
  }

  put(asset) {
    if (this.#entries.has(asset.id)) this.#entries.delete(asset.id);
    this.#entries.set(asset.id, asset);
    while (this.#entries.size > this.capacity) {
      const [oldestID, oldest] = this.#entries.entries().next().value;
      this.#entries.delete(oldestID);
      this.onEvict(oldest);
    }
    return asset;
  }

  get(id) { return this.#entries.get(id) ?? null; }
  has(id) { return this.#entries.has(id); }
  values() { return [...this.#entries.values()]; }
  get size() { return this.#entries.size; }
}

export class RecordStore {
  constructor(storage = new Map()) { this.storage = storage; }
  saveRecord(record) { this.storage.set(record.id, record); return record; }
  get(id) { return this.storage.get(id) ?? null; }
  has(id) { return this.storage.has(id); }
  values() { return [...this.storage.values()]; }
  get size() { return this.storage.size; }
}

export class VoiceAssetStore extends RecordStore {
  save(voice) { return this.saveRecord(voice); }
}

export class AudioAssetStore extends RecordStore {
  save(cachedAsset) {
    const saved = Object.freeze({ ...cachedAsset, persistenceState: 'saved' });
    return this.saveRecord(saved);
  }
}

export class AudioLifecycle {
  constructor({ persistentStore = new AudioAssetStore() } = {}) {
    this.previewCache = new FifoCache(5);
    this.generatedAudioCache = new FifoCache(2);
    this.persistentStore = persistentStore;
  }

  cache(asset, mode) {
    if (mode === 'preview') return this.previewCache.put(asset);
    if (mode === 'generate') return this.generatedAudioCache.put(asset);
    throw new TypeError('mode must be preview or generate');
  }

  save(assetID, mode) {
    const cache = mode === 'preview' ? this.previewCache : mode === 'generate' ? this.generatedAudioCache : null;
    if (!cache) throw new TypeError('mode must be preview or generate');
    const asset = cache.get(assetID);
    if (!asset) throw new Error(`Audio asset ${assetID} is not in the ${mode} cache`);
    return this.persistentStore.save(asset);
  }
}
