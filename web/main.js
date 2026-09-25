import { createVoiceAsset, createVoiceRequest } from '../src/domain.js';
import { AudioAssetStore, AudioLifecycle, VoiceAssetStore } from '../src/cache.js';
import { MockRenderer } from '../src/renderer.js';

const byID = (id) => document.getElementById(id);
const localStore = (key) => ({
  get: (id) => JSON.parse(localStorage.getItem(`${key}:${id}`) ?? 'null'),
  has: (id) => localStorage.getItem(`${key}:${id}`) !== null,
  set: (id, item) => localStorage.setItem(`${key}:${id}`, JSON.stringify(item)),
  values: () => Object.keys(localStorage).filter((item) => item.startsWith(`${key}:`)).map((item) => JSON.parse(localStorage.getItem(item))),
  get size() { return Object.keys(localStorage).filter((item) => item.startsWith(`${key}:`)).length; },
});
const savedAudio = new AudioAssetStore(localStore('saved-audio'));
const savedVoices = new VoiceAssetStore(localStore('voice'));
const lifecycle = new AudioLifecycle({ persistentStore: savedAudio });
const renderer = new MockRenderer();
let voice = null;

function renderSavedAssets() {
  const list = byID('saved-list');
  list.replaceChildren();
  for (const asset of savedAudio.values()) {
    const item = document.createElement('li');
    item.textContent = `${asset.text} — saved mock asset`;
    list.prepend(item);
  }
  if (list.childElementCount === 0) list.innerHTML = '<li class="muted">Nothing saved yet.</li>';
}

const latestVoice = savedVoices.values().at(-1);
if (latestVoice) {
  voice = latestVoice;
  byID('voice-name').value = voice.name;
  byID('source').value = voice.sourceType;
  byID('voice-status').textContent = `${voice.name} restored from local storage.`;
  byID('preview').disabled = false;
  byID('generate').disabled = false;
  byID('render-status').textContent = 'The mock renderer will return a data-only placeholder.';
}
renderSavedAssets();

byID('create-voice').addEventListener('click', async () => {
  const file = byID('reference').files[0];
  voice = createVoiceAsset({ name: byID('voice-name').value.trim() || 'My voice', sourceType: byID('source').value, referenceAudio: file ? { name: file.name, type: file.type, size: file.size } : null });
  await renderer.loadVoice(voice);
  savedVoices.save(voice);
  byID('voice-status').textContent = `${voice.name} saved locally. ${file ? `Reference selected: ${file.name}.` : 'No reference audio selected.'}`;
  byID('preview').disabled = false;
  byID('generate').disabled = false;
  byID('render-status').textContent = 'The mock renderer will return a data-only placeholder.';
});

async function render(mode) {
  if (!voice) return;
  const request = createVoiceRequest({ text: byID('text').value, voice, language: voice.languageHint, accent: voice.defaultAccent, attributes: voice.defaultAttributes, renderMode: mode });
  const result = await renderer.synthesize(request);
  lifecycle.cache(result.asset, mode);
  byID('render-status').textContent = `${mode === 'preview' ? 'Preview' : 'Generation'} created in the ${mode} cache. ${result.notice} Voice clone capability: ${result.capability.status}.`;
  if (mode === 'generate') {
    const saveButton = document.createElement('button');
    saveButton.className = 'secondary';
    saveButton.textContent = 'Save latest generated item';
    saveButton.addEventListener('click', () => {
      const saved = lifecycle.save(result.asset.id, 'generate');
      renderSavedAssets();
      saveButton.disabled = true;
      saveButton.textContent = 'Saved';
    }, { once: true });
    byID('render-status').append(' ');
    byID('render-status').append(saveButton);
  }
}

byID('preview').addEventListener('click', () => render('preview'));
byID('generate').addEventListener('click', () => render('generate'));
