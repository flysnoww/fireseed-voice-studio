# Voice-centered Mobile Voice Engine (M2-C2.1)

## Product state and routes

```text
Home voice entries → CurrentVoiceSelection (one, persisted)
  ├ Saved Voice → usable system speech → OpenVoice conversion → Speed/Pitch → AudioAsset
  ├ System / Apple Personal Voice → system speech → Speed/Pitch → AudioAsset
  ├ installed local English voice → Kitten → Speed/Pitch → AudioAsset
  └ explicitly opted-in advanced Saved Voice → legacy Qwen → Speed/Pitch → AudioAsset
```

A completed library selection is immediately current. Saving Record/Import selects the new durable Voice. Relaunch restores the selection; missing/unusable entries fall back to the newest Saved Voice, then a probed usable system voice. There is no Confirm, Prepare, Use or Apply user step. Automatic Saved Voice generation never requires a manually selected system source or precomputed target embedding. Missing optional conversion data is reported truthfully; system generation works without any downloaded models.

## Persistence and migration

`VoiceAsset.profile` is model-neutral: speed, pitch, language, accent, rendering preference. Decoding earlier metadata supplies neutral speed/pitch and the existing language/accent hints. Rename/favorite/profile updates preserve reference identity and bytes. `voice-selection.json` separately stores one selection and system/local profiles keyed by stable identifiers. Apple voices are never copied into Saved Voice assets.

Preview cache remains FIFO 5; unsaved Generate cache remains FIFO 2. Only explicit Save promotes output. Sharing works from managed cached or durable files. Canonical references stay durable; embeddings and compiled models are disposable. Removing a pack cannot delete VoiceAsset/reference/audio metadata.

## Native presentation

`StudioFloatingCard` uses SwiftUI sheets, native NavigationStack, medium/large detents, drag indicator, common material/corners and Done. Libraries, system language/voice choices, Shaping, language/accent and Settings children use this treatment. Generated Audio is an editable object card. Background replacement and skin persistence remain independent.

## Usable system voices

The OS catalog supplies identifiers, names, locale, gender and quality; no private Siri identifiers are assumed. Base-language groups are unique. Device language is first, English second without duplication, then a small documented static language order and localized alphabetical fallback. Within a language, authorized Personal Voice precedes Premium, Enhanced, Default, then locale/name/id ties. The UI initially probes eight candidates and offers more.

`SystemVoiceAvailabilityCache` asynchronously calls `AVSpeechSynthesizer.write` with a short native phrase. Only a nonempty valid PCM buffer makes a voice usable. Failure is diagnostic-only; unusable voices never appear as selectable rows. Tasks support cancellation and timeout; identifier results are reused until Apple's available-voices notification invalidates them. Personal Voices are hidden unless enumerated and authorized through Apple's official permission flow. Voice availability is device-dependent.

## Shaping and providers

Production controls are native rate 0.5–2 and pitch ±1200 cents, applied once in shared offline AVAudioEngine DSP. Brightness/clarity/softness are absent from production capability/UI; their old experimental DSP tests remain. Expression contract remains unsupported and has no controls. No emotion claim is made.

Saved automatic routing uses language/accent and the usable catalog to choose system source speech. OpenVoice lazily creates/reuses target embeddings keyed by Voice ID + reference ID + pinned converter revision. System speech and optional Kitten work with NO QWEN MODEL. Qwen packs/runtime remain compatible but are never restored by default; only advanced preference may load them. Kitten is an optional installed local English fixed voice, not a cloning provider.

OpenVoice is optional, outside the IPA, with exact upstream revision `3a72f7931fce14857c34a15b2d83ffbcaa755e16` and converter revision `b0f10347769c88bb6df26e268d4b84bc7237fdeb`. Its six immutable payload files total 66,024,655 bytes. Existing manifest/hash/model-feature validation is preserved. No new model architecture is introduced.

## Verification and diagnostics

Unit tests cover migration, independent profiles, selection, restoration, save auto-selection, usable-probe cache/invalidation/cancellation, capabilities and asset lifetimes. Simulator UI regression seeds explicitly synthetic reference/output assets in isolated storage, imports the same hash-verified existing optional pack, uses real system synthesis/Core ML conversion, and attaches flow screenshots. This checks plumbing, not cloning similarity or iPhone latency.

Build 4 diagnostics include source, identifier, quality, language/accent, route, synthesis/DSP stage time, OpenVoice load/embedding/conversion time, output duration, RTF and actual process physical footprint. No reference audio or user text is logged. iPhone listening/performance remains a user hardware gate. No MOSS, cloud, account, training, new model or next milestone is part of this change.
