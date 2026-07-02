#!/usr/bin/env python3
from pathlib import Path
import qwen_tts

target = Path(qwen_tts.__file__).parent / "core/tokenizer_25hz/vq/speech_vq.py"
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

if old_init in text:
    text = text.replace(old_init, new_init)

if old_method in text:
    text = text.replace(old_method, new_method)

target.write_text(text, encoding="utf-8")
print(f"[OK] Patched Qwen TTS SoX normalization: {target}")
