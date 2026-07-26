# ReadAsMe

A macOS app for turning EPUB, PDF, or TXT files into audiobooks using your own AI-cloned voice, then auditing and repairing the finished audio locally.

This app was made using [WhiskeyCoder/Qwen3-Audiobook-Converter](https://github.com/WhiskeyCoder/Qwen3-Audiobook-Converter). The converter code is included under `repos/Qwen3-Audiobook-Converter` with its original license.

## Download

Download the latest `ReadAsMe-macOS-arm64.zip` from the GitHub Releases tab, unzip it, and open `ReadAsMe.app`.

The app does not include any voice sample or transcript. Choose your own voice audio file and provide the matching transcript in the app.

## What Happens On First Run

The release app bundles its own Python 3.12 runtime, so users do not need to install Python, Homebrew, SoX, or ffmpeg manually.

On first use, the app creates its runtime folder here:

```text
~/Library/Application Support/ReadAsMe/
```

It then installs the Python packages it needs and downloads Qwen model files as needed. The first run can take a while and requires internet access.
The main voice model is about 3.9 GB, and an interrupted download resumes the next time the voice engine starts.

The first audiobook quality check installs a separate NVIDIA Parakeet V3 environment and downloads about 2.5 GB of model data. Qwen and Parakeet are kept in separate processes and are not loaded together.

## Quality Audit and Repair

- Generated audiobooks are automatically checked after they are saved.
- **Audit Existing** supports WAV, MP3, M4A, M4B, and FLAC.
- Adding the original book or transcript enables missing, extra, repeated, and incorrect-word detection.
- Reports are saved as readable Markdown and versioned JSON.
- Findings include playable timestamps, evidence, confidence, and repair safety.
- **Repair Selected**, **Repair All Safe**, and **Repair All** always create a new output file. The original is never modified.
- Timing and loudness repairs are verified before publishing. Speech errors can be regenerated with Qwen when a clean single-narrator voice reference and matching transcript are available.
- Imported audiobook metadata, artwork, and adjusted chapter times are preserved where the output format supports them.
- The **Natural** profile matches the book's own cadence. **ACX Technical** checks engineering targets only and does not guarantee ACX acceptance or narration eligibility.

The app can automatically select a clean voice reference from a single-narrator audiobook. Use the voice-repair override when the automatic sample is unsuitable. Multi-narrator audio can still be audited and receive timing or loudness repairs, but automatic speech replacement requires an unambiguous voice reference.

## Notes

- Apple Silicon Macs use MPS automatically when available.
- Macs without MPS fall back to CPU, which can be very slow.
- Generated and repaired masters are saved as `.wav`. The app bundles FFmpeg and FFprobe for auditing and optional same-format repaired copies.
- The app is ad-hoc signed for local use, not Apple-notarized.

## License

ReadAsMe is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

The bundled WhiskeyCoder converter remains under its original MIT license notice, which is compatible with GPL-3.0.

## Building From Source

```bash
cd ReadAsMe
./script/build_and_run.sh build
```

The build script uses `uv` to prepare a bundled Python runtime if `ReadAsMe/Vendor/python` is missing.

## Credits

- App wrapper and macOS packaging: this project.
- Audiobook conversion foundation: [WhiskeyCoder/Qwen3-Audiobook-Converter](https://github.com/WhiskeyCoder/Qwen3-Audiobook-Converter).
- Qwen TTS runtime: Alibaba Qwen team packages and models.
