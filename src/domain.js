const requiredString = (value, field) => {
  if (typeof value !== 'string' || value.trim() === '') throw new TypeError(`${field} must be a non-empty string`);
};

export function createVoiceAsset({
  id = crypto.randomUUID(), name, sourceType, referenceAudio = null, languageHint = null,
  defaultAccent = null, defaultAttributes = {}, rendererCaches = [], createdAt = new Date().toISOString(), updatedAt = createdAt,
}) {
  requiredString(id, 'id');
  requiredString(name, 'name');
  if (!['random', 'record', 'import', 'builtin'].includes(sourceType)) throw new TypeError('sourceType is invalid');
  return Object.freeze({ id, name, sourceType, referenceAudio, languageHint, defaultAccent, defaultAttributes: structuredClone(defaultAttributes), rendererCaches: [...rendererCaches], createdAt, updatedAt });
}

export function createAudioAsset({
  id = crypto.randomUUID(), fileURL, duration = null, createdAt = new Date().toISOString(),
  sourceVoiceID, text, persistenceState = 'cached', mock = false,
}) {
  requiredString(id, 'id');
  requiredString(fileURL, 'fileURL');
  requiredString(sourceVoiceID, 'sourceVoiceID');
  requiredString(text, 'text');
  if (!['cached', 'saved'].includes(persistenceState)) throw new TypeError('persistenceState is invalid');
  return Object.freeze({ id, fileURL, duration, createdAt, sourceVoiceID, text, persistenceState, mock });
}

export function createVoiceRequest({ text, voice, language = null, accent = null, attributes = {}, renderMode }) {
  requiredString(text, 'text');
  if (!voice || typeof voice.id !== 'string') throw new TypeError('voice must be a VoiceAsset');
  if (!['preview', 'generate'].includes(renderMode)) throw new TypeError('renderMode must be preview or generate');
  return Object.freeze({ text, voice, language, accent, attributes: structuredClone(attributes), renderMode });
}

export const CapabilityStatus = Object.freeze({ SUPPORTED: 'supported', APPROXIMATE: 'approximate', UNSUPPORTED: 'unsupported' });

export function validateVoiceRequest(request) {
  const allowed = new Set(['text', 'voice', 'language', 'accent', 'attributes', 'renderMode']);
  for (const key of Object.keys(request)) if (!allowed.has(key)) throw new TypeError(`Unknown canonical VoiceRequest field: ${key}`);
  createVoiceRequest(request);
  return true;
}
