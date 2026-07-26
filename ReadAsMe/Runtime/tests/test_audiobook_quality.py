import json
import math
import os
import struct
import tempfile
import unittest
import wave
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import audiobook_quality as quality


def write_fixture(path: Path) -> None:
    rate = 16000
    with wave.open(str(path), "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(rate)
        for seconds, amplitude in ((1.0, 8000), (3.0, 0), (1.0, 8000)):
            values = [
                int(amplitude * math.sin(2 * math.pi * 220 * index / rate))
                for index in range(int(rate * seconds))
            ]
            target.writeframes(struct.pack(f"<{len(values)}h", *values))


class AudiobookQualityTests(unittest.TestCase):
    def test_parakeet_cache_message_reports_download_and_cached_model(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            model_cache = root / "hub" / "models--nvidia--parakeet-tdt-0.6b-v3"
            blobs = model_cache / "blobs"
            blobs.mkdir(parents=True)
            incomplete = blobs / "weights.incomplete"
            incomplete.write_bytes(b"x" * 1024)
            previous = os.environ.get("HF_HOME")
            os.environ["HF_HOME"] = str(root)
            try:
                self.assertIn("Downloading NVIDIA Parakeet V3", quality.parakeet_cache_message())
                incomplete.unlink()
                snapshot = model_cache / "snapshots" / "revision"
                snapshot.mkdir(parents=True)
                (snapshot / "model.safetensors").touch()
                self.assertIn("Loading the downloaded", quality.parakeet_cache_message())
            finally:
                if previous is None:
                    os.environ.pop("HF_HOME", None)
                else:
                    os.environ["HF_HOME"] = previous

    def test_parakeet_subword_timestamps_become_timestamped_words(self):
        tokens = [
            {"token": " Dor", "start": 0.24, "end": 0.40},
            {"token": "othy", "start": 0.40, "end": 0.72},
            {"token": " liv", "start": 0.88, "end": 1.04},
            {"token": "ed", "start": 1.04, "end": 1.20},
            {"token": ".", "start": 1.20, "end": 1.20},
        ]
        words = quality.token_timestamps_to_words(tokens, offset=10.0)
        self.assertEqual([word["text"] for word in words], ["Dorothy", "lived."])
        self.assertAlmostEqual(words[0]["start"], 10.24)
        self.assertAlmostEqual(words[1]["end"], 11.20)

    def test_detects_long_internal_pause(self):
        with tempfile.TemporaryDirectory() as folder:
            audio = Path(folder) / "fixture.wav"
            write_fixture(audio)
            analysis = quality.analyze_wave(audio)
            findings = quality.waveform_findings(analysis, "Natural")
            pauses = [item for item in findings if item["type"] == "long_pause"]
            self.assertEqual(len(pauses), 1)
            self.assertGreater(pauses[0]["time_range"]["end"] - pauses[0]["time_range"]["start"], 2.5)
            self.assertEqual(pauses[0]["repair_safety"], "safe")

    def test_source_review_offsets_use_utf16(self):
        text = "🎧 This is is ready..."
        suggestions = quality.source_suggestions(text)
        repeated = next(item for item in suggestions if item["kind"] == "repeated_word")
        self.assertEqual(repeated["offset"], 8)
        self.assertEqual(repeated["replacement"], "is")

    def test_filter_timeline_does_not_duplicate_audio_around_insert(self):
        graph, timeline, replacements = quality.make_filter_complex(
            10.0,
            16000,
            "mono",
            [{"type": "insert", "at": 5.0, "amount": 0.4}],
            "Natural",
        )
        self.assertEqual(replacements, [])
        self.assertEqual(timeline[0]["original_start"], 0)
        self.assertEqual(timeline[0]["original_end"], 5)
        self.assertEqual(timeline[1]["original_start"], 5)
        self.assertEqual(timeline[1]["original_end"], 10)
        self.assertIn("anullsrc", graph)

    def test_audit_and_safe_repair_keep_original_unchanged(self):
        ffmpeg = Path("/opt/homebrew/bin/ffmpeg")
        ffprobe = Path("/opt/homebrew/bin/ffprobe")
        if not ffmpeg.exists() or not ffprobe.exists():
            self.skipTest("ffmpeg development fixture is unavailable")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            audio = root / "fixture.wav"
            write_fixture(audio)
            original = audio.read_bytes()
            manifest = {
                "schema_version": 1,
                "session_id": "test-session",
                "input_audio": str(audio),
                "expected_text": None,
                "generated_chunks": None,
                "voice_reference": None,
                "voice_transcript": None,
                "quality_profile": "Natural",
                "language": "auto",
                "output_directory": str(root),
                "output_same_format": False,
                "ffmpeg": str(ffmpeg),
                "ffprobe": str(ffprobe),
                "qwen_python": None,
                "converter": None,
                "repair_finding_ids": None,
                "repair_mode": None,
                "report_path": None,
            }
            manifest_path = root / "audit-manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            previous = os.environ.get("READASME_SKIP_ASR")
            os.environ["READASME_SKIP_ASR"] = "1"
            try:
                report, report_path, _ = quality.audit(manifest_path)
                self.assertEqual(report["summary"]["finding_count"], 1)
                manifest["repair_mode"] = "all_safe"
                manifest["report_path"] = str(report_path)
                repair_manifest = root / "repair-manifest.json"
                repair_manifest.write_text(json.dumps(manifest), encoding="utf-8")
                repaired_report, repaired = quality.repair(repair_manifest)
            finally:
                if previous is None:
                    os.environ.pop("READASME_SKIP_ASR", None)
                else:
                    os.environ["READASME_SKIP_ASR"] = previous
            self.assertTrue(repaired.exists())
            self.assertEqual(audio.read_bytes(), original)
            self.assertEqual(repaired_report["summary"]["repaired_count"], 1)
            self.assertLess(quality.analyze_wave(repaired).duration, 4.0)


if __name__ == "__main__":
    unittest.main()
