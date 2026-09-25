import test from 'node:test';
import assert from 'node:assert/strict';
import { AudioLifecycle, FifoCache, VoiceAssetStore } from '../src/cache.js';
import { createAudioAsset, createVoiceAsset, createVoiceRequest, validateVoiceRequest } from '../src/domain.js';
import { MockRenderer } from '../src/renderer.js';

const makeVoice = () => createVoiceAsset({ id: 'voice-1', name: 'Test voice', sourceType: 'import' });
const makeAudio = (id, voiceID = 'voice-1') => createAudioAsset({ id, fileURL: `mock://${id}`, sourceVoiceID: voiceID, text: `text ${id}`, mock: true });

test('preview cache evicts the oldest item on the sixth preview', () => {
  const cache = new AudioLifecycle().previewCache;
  for (let i = 1; i <= 6; i++) cache.put(makeAudio(`p${i}`));
  assert.equal(cache.size, 5);
  assert.equal(cache.has('p1'), false);
  assert.equal(cache.has('p2'), true);
});

test('generated cache evicts the oldest item on the third generation', () => {
  const cache = new AudioLifecycle().generatedAudioCache;
  for (let i = 1; i <= 3; i++) cache.put(makeAudio(`g${i}`));
  assert.equal(cache.size, 2);
  assert.equal(cache.has('g1'), false);
  assert.equal(cache.has('g2'), true);
});

test('saving promotes an asset to persistence and later eviction leaves it intact', () => {
  const lifecycle = new AudioLifecycle();
  const first = makeAudio('saved-1');
  lifecycle.cache(first, 'generate');
  const saved = lifecycle.save(first.id, 'generate');
  lifecycle.cache(makeAudio('g2'), 'generate');
  lifecycle.cache(makeAudio('g3'), 'generate');
  assert.equal(lifecycle.generatedAudioCache.has(first.id), false);
  assert.equal(lifecycle.persistentStore.get(first.id), saved);
  assert.equal(saved.persistenceState, 'saved');
});

test('unsupported renderer capability is reported without claiming support', async () => {
  const renderer = new MockRenderer();
  const capability = renderer.capabilityResult('voiceClone');
  assert.equal(capability.status, 'unsupported');
  const result = await renderer.synthesize(createVoiceRequest({ text: 'Hello', voice: makeVoice(), renderMode: 'preview' }));
  assert.equal(result.capability.status, 'unsupported');
  assert.equal(result.playable, false);
  assert.equal(result.asset.mock, true);
});

test('canonical request rejects renderer-specific fields', () => {
  const voice = makeVoice();
  const request = createVoiceRequest({ text: 'Hello', voice, renderMode: 'generate' });
  assert.equal(validateVoiceRequest(request), true);
  assert.equal('seed' in request, false);
  assert.throws(() => validateVoiceRequest({ ...request, temperature: 0.7 }), /Unknown canonical VoiceRequest field/);
});

test('saved voice assets remain available through the configured local store', () => {
  const backingStore = new Map();
  const voice = makeVoice();
  new VoiceAssetStore(backingStore).save(voice);
  const reopenedStore = new VoiceAssetStore(backingStore);
  assert.deepEqual(reopenedStore.get(voice.id), voice);
});

test('FIFO cache updates order when an existing ID is reinserted', () => {
  const cache = new FifoCache(2);
  cache.put(makeAudio('a'));
  cache.put(makeAudio('b'));
  cache.put(makeAudio('a'));
  cache.put(makeAudio('c'));
  assert.equal(cache.has('a'), true);
  assert.equal(cache.has('b'), false);
});
