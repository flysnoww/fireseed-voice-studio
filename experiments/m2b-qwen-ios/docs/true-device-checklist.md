# True-device checklist

1. On a Mac with Xcode, open `ios/QwenRuntimeSpike.xcodeproj`.
2. Select the actual iPhone, set a signing team, build and install.
3. Put both prepared F16 GGUF files into a local Files folder on the iPhone.
4. In the spike, select that model folder; record a 5–30 s reference WAV or select a WAV file. Confirm playback before embedding.
5. Enter the transcript for notes only; the pinned C++ runtime does not consume it.
6. Enter new text, load, prepare reference, generate, and play.
7. Record load/prepare/generation time, output duration, RTF, backend, physical footprint, and memory-warning count.
8. Repeat with CPU and Auto; verify actual backend and compare output and timing.
9. Observe termination and thermal behavior; note intelligibility and speaker similarity.
10. Enable Airplane Mode and repeat after confirming both model files are local.

Record device model, iOS version, model file hashes, actual run commit, and results. A Metal/CPU smoke test is not the official ref-audio-plus-ref-text cloning gate.
