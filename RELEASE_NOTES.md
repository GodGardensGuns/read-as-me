# ReadAsMe v0.1.0

Initial public release.

- macOS app wrapper for local AI voice-cloned audiobook generation.
- Bundled Python 3.12 runtime in the downloadable app.
- First-run setup installs required Qwen/converter packages automatically.
- No bundled voice sample or transcript; users choose their own files.
- Uses WAV output to avoid ffmpeg.
- Uses MPS automatically when available, with CPU fallback.
- Licensed under GPL-3.0.

Built using [WhiskeyCoder/Qwen3-Audiobook-Converter](https://github.com/WhiskeyCoder/Qwen3-Audiobook-Converter).
