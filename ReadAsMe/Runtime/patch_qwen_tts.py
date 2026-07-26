#!/usr/bin/env python3
from importlib.util import find_spec
from pathlib import Path

package_spec = find_spec("qwen_tts")
if package_spec is None or package_spec.submodule_search_locations is None:
    raise ModuleNotFoundError("qwen_tts package was not found")

package_root = Path(next(iter(package_spec.submodule_search_locations)))
target = package_root / "core/tokenizer_25hz/vq/speech_vq.py"
if not target.is_file():
    raise FileNotFoundError(f"Qwen TTS normalization source was not found: {target}")

text = target.read_text(encoding="utf-8")

old_init = """        self.tfm = sox.Transformer()
        self.tfm.norm(db_level=-6)
"""
new_init = """        self.tfm = None
"""

old_method = """    def sox_norm(self, audio):
        wav_norm = self.tfm.build_array(input_array=audio, sample_rate_in=16000)
        return wav_norm
"""
new_method = """    def sox_norm(self, audio):
        import numpy as np
        audio = np.asarray(audio, dtype=np.float32)
        peak = np.max(np.abs(audio)) if audio.size else 0.0
        if peak <= 0:
            return audio
        target_peak = 10 ** (-6 / 20)
        return audio * (target_peak / peak)
"""

changed = False

if "import sox\n" in text:
    text = text.replace("import sox\n", "", 1)
    changed = True

if old_init in text:
    text = text.replace(old_init, new_init)
    changed = True
elif new_init not in text:
    raise RuntimeError("Qwen TTS normalization initializer has an unexpected format")

if old_method in text:
    text = text.replace(old_method, new_method)
    changed = True
elif new_method not in text:
    raise RuntimeError("Qwen TTS normalization method has an unexpected format")

if changed:
    target.write_text(text, encoding="utf-8")
    print(f"[OK] Patched Qwen TTS SoX normalization: {target}")
else:
    print(f"[OK] Qwen TTS SoX normalization is already patched: {target}")
