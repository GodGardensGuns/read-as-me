# ReadAsMe

A macOS app for turning EPUB, PDF, or TXT files into audiobooks using your own AI-cloned voice.

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

Completed audio chunks are cached while a book is being generated. If a slow chunk
times out after its retries, start the same conversion again and ReadAsMe resumes
from the completed chunks instead of regenerating the whole book.

## Notes

- Apple Silicon Macs use MPS automatically when available.
- Macs without MPS fall back to CPU, which can be very slow.
- Generated audiobooks are saved as `.wav`.
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
