import { CapabilityStatus } from './domain.js';

export class RendererAdapter {
  constructor(capabilities) { this.capabilities = Object.freeze({ ...capabilities }); }

  async loadVoice(voice) { return { status: 'loaded', voiceID: voice.id }; }

  capabilityResult(capability) {
    const status = this.capabilities[capability] ?? CapabilityStatus.UNSUPPORTED;
    if (status === CapabilityStatus.UNSUPPORTED) return { status, capability, message: `${capability} is not supported by this renderer` };
    return { status, capability, ...(status === CapabilityStatus.APPROXIMATE ? { approximation: `${capability} is approximated by this renderer` } : {}) };
  }

  async synthesize(request) {
    throw new Error('RendererAdapter.synthesize must be implemented');
  }

  async saveVoice(voice) { return { status: 'saved', voiceID: voice.id }; }
}

// This adapter proves data flow only. It does not generate or play audio.
export class MockRenderer extends RendererAdapter {
  constructor() {
    super({ local: CapabilityStatus.SUPPORTED, streaming: CapabilityStatus.UNSUPPORTED, referenceVoice: CapabilityStatus.UNSUPPORTED, voiceClone: CapabilityStatus.UNSUPPORTED, accentControl: CapabilityStatus.UNSUPPORTED, attributeControl: CapabilityStatus.UNSUPPORTED });
  }

  async synthesize(request) {
    const { createAudioAsset } = await import('./domain.js');
    const capability = this.capabilityResult('voiceClone');
    return {
      status: 'mock',
      capability,
      asset: createAudioAsset({ fileURL: `mock://audio/${crypto.randomUUID()}`, sourceVoiceID: request.voice.id, text: request.text, mock: true }),
      playable: false,
      notice: 'Mock output contains no playable audio.',
    };
  }
}
