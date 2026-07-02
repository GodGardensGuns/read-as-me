# Qwen Audiobook Maker

A small macOS app for turning EPUB, PDF, or TXT files into audiobooks with Qwen3 TTS voice cloning.

This app was made using [WhiskeyCoder/Qwen3-Audiobook-Converter](https://github.com/WhiskeyCoder/Qwen3-Audiobook-Converter). The converter code is included under `repos/Qwen3-Audiobook-Converter` with its original license.

## Download

Download the latest `QwenAudiobookMaker-macOS-arm64.zip` from the GitHub Releases tab, unzip it, and open `QwenAudiobookMaker.app`.

The app does not include any voice sample or transcript. Choose your own voice audio file and provide the matching transcript in the app.

## What Happens On First Run

The release app bundles its own Python 3.12 runtime, so users do not need to install Python, Homebrew, SoX, or ffmpeg manually.

On first use, the app creates its runtime folder here:

```text
~/Library/Application Support/Qwen Audiobook Maker/
```

It then installs the Python packages it needs and downloads Qwen model files as needed. The first run can take a while and requires internet access.

## Notes

- Apple Silicon Macs use MPS automatically when available.
- Macs without MPS fall back to CPU, which can be very slow.
- Output is saved as `.wav` to avoid requiring ffmpeg.
- The app is ad-hoc signed for local use, not Apple-notarized.

## License

Qwen Audiobook Maker is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

The bundled WhiskeyCoder converter remains under its original MIT license notice, which is compatible with GPL-3.0.

## Building From Source

```bash
cd QwenAudiobookMaker
./script/build_and_run.sh build
```

The build script uses `uv` to prepare a bundled Python runtime if `QwenAudiobookMaker/Vendor/python` is missing.

## Credits

- App wrapper and macOS packaging: this project.
- Audiobook conversion foundation: [WhiskeyCoder/Qwen3-Audiobook-Converter](https://github.com/WhiskeyCoder/Qwen3-Audiobook-Converter).
- Qwen TTS runtime: Alibaba Qwen team packages and models.
