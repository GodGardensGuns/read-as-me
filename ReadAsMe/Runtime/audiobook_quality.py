#!/usr/bin/env python3
"""Local audiobook quality audit and non-destructive repair engine for ReadAsMe."""

from __future__ import annotations

import argparse
import array
import contextlib
import dataclasses
import datetime as dt
import difflib
import hashlib
import html
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import wave
import zipfile
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Sequence

SCHEMA_VERSION = 1
MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
SUPPORTED_AUDIO = {".wav", ".mp3", ".m4a", ".m4b", ".flac"}
WORD_RE = re.compile(r"\b[\w’'-]+\b", re.UNICODE)


def emit(event: str, **payload: Any) -> None:
    print(json.dumps({"event": event, **payload}, ensure_ascii=False), flush=True)


def fail(message: str, code: int = 2) -> "NoReturn":
    emit("error", phase="failed", progress=1.0, message=message)
    raise SystemExit(code)


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("manifest must contain a JSON object")
    return data


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def run(command: Sequence[str], *, check: bool = True, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(
        list(command),
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and process.returncode:
        detail = process.stderr.strip().splitlines()[-1] if process.stderr.strip() else f"exit {process.returncode}"
        raise RuntimeError(f"{Path(command[0]).name} failed: {detail}")
    return process


def unique_path(folder: Path, stem: str, suffix: str) -> Path:
    candidate = folder / f"{stem}{suffix}"
    number = 2
    while candidate.exists():
        candidate = folder / f"{stem}-{number}{suffix}"
        number += 1
    return candidate


def validate_manifest(data: dict[str, Any]) -> tuple[Path, Path, Path]:
    if int(data.get("schema_version", 0)) != SCHEMA_VERSION:
        raise ValueError(f"unsupported manifest schema: {data.get('schema_version')}")
    audio = Path(str(data.get("input_audio", ""))).expanduser()
    if not audio.is_file():
        raise ValueError(f"audio file was not found: {audio}")
    if audio.suffix.lower() not in SUPPORTED_AUDIO:
        raise ValueError(f"unsupported audio format: {audio.suffix or '(none)'}")
    output = Path(str(data.get("output_directory", ""))).expanduser()
    output.mkdir(parents=True, exist_ok=True)
    ffmpeg = Path(str(data.get("ffmpeg", "")))
    ffprobe = Path(str(data.get("ffprobe", "")))
    if not ffmpeg.is_file() or not os.access(ffmpeg, os.X_OK):
        raise ValueError("the bundled ffmpeg executable is missing")
    if not ffprobe.is_file() or not os.access(ffprobe, os.X_OK):
        raise ValueError("the bundled ffprobe executable is missing")
    return audio, ffmpeg, ffprobe


def probe_audio(audio: Path, ffprobe: Path) -> dict[str, Any]:
    process = run(
        [
            str(ffprobe),
            "-v",
            "error",
            "-show_entries",
            "format=duration,format_name,bit_rate:stream=index,codec_name,codec_type,sample_rate,channels,channel_layout:chapter",
            "-show_chapters",
            "-of",
            "json",
            str(audio),
        ]
    )
    payload = json.loads(process.stdout or "{}")
    streams = payload.get("streams", [])
    audio_streams = [item for item in streams if item.get("codec_type") == "audio"]
    if not audio_streams:
        raise ValueError("the selected file contains no readable audio stream")
    codec = str(audio_streams[0].get("codec_name", "")).lower()
    if codec in {"aac_latm", "drms"} or "encrypted" in json.dumps(payload).lower():
        raise ValueError("encrypted or DRM-protected audio cannot be audited")
    return payload


def decode_proxy(audio: Path, ffmpeg: Path, destination: Path, sample_rate: int = 16000) -> Path:
    run(
        [
            str(ffmpeg),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(audio),
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-c:a",
            "pcm_s16le",
            str(destination),
        ]
    )
    return destination


@dataclasses.dataclass
class AudioWindow:
    start: float
    end: float
    rms_db: float
    peak_db: float
    clipped_fraction: float


@dataclasses.dataclass
class AudioAnalysis:
    duration: float
    sample_rate: int
    windows: list[AudioWindow]
    silence_ranges: list[tuple[float, float]]
    integrated_rms_db: float
    peak_db: float
    clipped_fraction: float
    noise_floor_db: float


def dbfs(value: float, floor: float = -120.0) -> float:
    return max(floor, 20.0 * math.log10(max(value, 1e-12)))


def percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        return -120.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return ordered[index]


def analyze_wave(path: Path, window_seconds: float = 0.25) -> AudioAnalysis:
    windows: list[AudioWindow] = []
    with contextlib.closing(wave.open(str(path), "rb")) as source:
        channels = source.getnchannels()
        width = source.getsampwidth()
        rate = source.getframerate()
        frames = source.getnframes()
        if width != 2:
            raise ValueError("analysis proxy must be 16-bit PCM")
        window_frames = max(1, int(rate * window_seconds))
        total_square = 0.0
        total_samples = 0
        global_peak = 0
        global_clipped = 0
        frame_cursor = 0
        while frame_cursor < frames:
            raw = source.readframes(min(window_frames, frames - frame_cursor))
            values = array.array("h")
            values.frombytes(raw)
            if sys.byteorder != "little":
                values.byteswap()
            if not values:
                break
            absolute = [abs(value) for value in values]
            squares = sum(float(value) * float(value) for value in values)
            rms = math.sqrt(squares / len(values)) / 32768.0
            peak = max(absolute) / 32768.0
            clipped = sum(1 for value in absolute if value >= 32760)
            start = frame_cursor / rate
            frame_count = len(values) // channels
            end = (frame_cursor + frame_count) / rate
            windows.append(AudioWindow(start, end, dbfs(rms), dbfs(peak), clipped / len(values)))
            total_square += squares
            total_samples += len(values)
            global_peak = max(global_peak, max(absolute))
            global_clipped += clipped
            frame_cursor += frame_count

    duration = frames / rate if rate else 0.0
    rms = math.sqrt(total_square / max(total_samples, 1)) / 32768.0
    noise_floor = percentile([window.rms_db for window in windows], 0.10)
    speech_values = [window.rms_db for window in windows if window.rms_db > max(-55.0, noise_floor + 8.0)]
    speech_median = statistics.median(speech_values) if speech_values else -35.0
    silence_threshold = min(-42.0, max(-60.0, speech_median - 24.0))

    silence_ranges: list[tuple[float, float]] = []
    silence_start: float | None = None
    for window in windows:
        if window.rms_db <= silence_threshold:
            silence_start = window.start if silence_start is None else silence_start
        elif silence_start is not None:
            silence_ranges.append((silence_start, window.start))
            silence_start = None
    if silence_start is not None:
        silence_ranges.append((silence_start, duration))

    return AudioAnalysis(
        duration=duration,
        sample_rate=rate,
        windows=windows,
        silence_ranges=silence_ranges,
        integrated_rms_db=dbfs(rms),
        peak_db=dbfs(global_peak / 32768.0),
        clipped_fraction=global_clipped / max(total_samples, 1),
        noise_floor_db=noise_floor,
    )


def extract_expected_text(path_value: str | None) -> str:
    if not path_value:
        return ""
    path = Path(path_value)
    if not path.is_file():
        raise ValueError(f"expected text source was not found: {path}")
    suffix = path.suffix.lower()
    if suffix in {".txt", ".md"}:
        for encoding in ("utf-8", "utf-16", "cp1252", "latin-1"):
            try:
                return path.read_text(encoding=encoding)
            except UnicodeDecodeError:
                continue
    if suffix == ".pdf":
        import PyPDF2

        with path.open("rb") as handle:
            return "\n\n".join(page.extract_text() or "" for page in PyPDF2.PdfReader(handle).pages)
    if suffix == ".epub":
        from bs4 import BeautifulSoup
        from ebooklib import ITEM_DOCUMENT, epub

        book = epub.read_epub(str(path))
        return "\n\n".join(
            BeautifulSoup(item.get_content(), "html.parser").get_text(" ", strip=True)
            for item in book.get_items_of_type(ITEM_DOCUMENT)
        )
    raise ValueError(f"unsupported expected-text format: {suffix}")


def normalize_words(text: str) -> list[str]:
    return [match.group(0).replace("’", "'").casefold() for match in WORD_RE.finditer(text)]


def source_suggestions(text: str) -> list[dict[str, Any]]:
    suggestions: list[dict[str, Any]] = []
    def utf16_range(start: int, end: int) -> tuple[int, int]:
        location = len(text[:start].encode("utf-16-le")) // 2
        length = len(text[start:end].encode("utf-16-le")) // 2
        return location, length

    for index, match in enumerate(re.finditer(r"\b([\w’'-]+)(\s+)\1\b", text, flags=re.IGNORECASE)):
        location, length = utf16_range(match.start(), match.end())
        suggestions.append(
            {
                "id": f"repeated-{index}-{location}",
                "kind": "repeated_word",
                "offset": location,
                "length": length,
                "original": match.group(0),
                "replacement": match.group(1),
                "message": f'“{match.group(1)}” appears twice in a row.',
                "accepted": False,
            }
        )
    punctuation_patterns = [
        (r"([!?.,])\1{2,}", r"\1", "Repeated punctuation"),
        (r"\s+([,.;:!?])", r"\1", "Space before punctuation"),
    ]
    offset = len(suggestions)
    for pattern, replacement, message in punctuation_patterns:
        for index, match in enumerate(re.finditer(pattern, text)):
            location, length = utf16_range(match.start(), match.end())
            suggestions.append(
                {
                    "id": f"punctuation-{offset + index}-{location}",
                    "kind": "punctuation",
                    "offset": location,
                    "length": length,
                    "original": match.group(0),
                    "replacement": re.sub(pattern, replacement, match.group(0)),
                    "message": message,
                    "accepted": False,
                }
            )
        offset = len(suggestions)
    return suggestions


def parakeet_cache_message() -> str:
    hf_home = Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser()
    model_cache = hf_home / "hub" / "models--nvidia--parakeet-tdt-0.6b-v3"
    incomplete = list((model_cache / "blobs").glob("*.incomplete"))
    if incomplete:
        received = sum(path.stat().st_size for path in incomplete if path.is_file())
        return f"Downloading NVIDIA Parakeet V3: {received / 1_000_000_000:.2f} GB received (first use only)."
    if any((model_cache / "snapshots").glob("*/model.safetensors")):
        return "Loading the downloaded NVIDIA Parakeet V3 model into memory."
    return "Downloading NVIDIA Parakeet V3 for the first quality check."


def progress_heartbeat(
    stop: threading.Event,
    *,
    progress: float,
    message_factory: Callable[[], str],
    interval: float = 10.0,
) -> None:
    while not stop.wait(interval):
        emit("progress", phase="transcribing", progress=progress, message=message_factory())


def token_timestamps_to_words(
    tokens: Sequence[dict[str, Any]],
    *,
    offset: float = 0.0,
) -> list[dict[str, Any]]:
    """Join Parakeet's subword timestamps into readable, timestamped words."""
    words: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for item in tokens:
        token = str(item.get("token", ""))
        if not token or token == "<blank>":
            continue
        starts_word = token[:1].isspace()
        fragment = token.strip() if starts_word else token
        if not fragment:
            continue
        start = offset + float(item.get("start", 0.0))
        end = offset + float(item.get("end", item.get("start", 0.0)))
        if starts_word or current is None:
            if current is not None:
                words.append(current)
            current = {"text": fragment, "start": start, "end": end, "confidence": 0.85}
        else:
            current["text"] += fragment
            current["end"] = max(float(current["end"]), end)
    if current is not None:
        words.append(current)
    return words


def transcribe(proxy: Path) -> tuple[str, list[dict[str, Any]], str]:
    if os.environ.get("READASME_SKIP_ASR") == "1":
        return "", [], "disabled"
    emit("progress", phase="transcribing", progress=0.32, message=parakeet_cache_message())
    try:
        import numpy as np
        import torch
        from transformers import AutoModelForTDT, AutoProcessor
    except ImportError as error:
        raise RuntimeError("Parakeet runtime is not installed. Reopen the audit to finish setup.") from error

    if torch.backends.mps.is_available():
        device = "mps"
    else:
        device = "cpu"
    load_stop = threading.Event()
    load_thread = threading.Thread(
        target=progress_heartbeat,
        kwargs={
            "stop": load_stop,
            "progress": 0.32,
            "message_factory": parakeet_cache_message,
        },
        daemon=True,
    )
    load_thread.start()
    try:
        processor = AutoProcessor.from_pretrained(MODEL_ID)
        model = AutoModelForTDT.from_pretrained(MODEL_ID).to(device)
        model.eval()
    finally:
        load_stop.set()
        load_thread.join(timeout=1)

    transcription_started = time.monotonic()

    def transcription_message() -> str:
        elapsed = max(1, int((time.monotonic() - transcription_started) / 60))
        unit = "minute" if elapsed == 1 else "minutes"
        return f"Transcribing with NVIDIA Parakeet V3 ({elapsed} {unit} elapsed)."

    emit("progress", phase="transcribing", progress=0.40, message="Transcribing with NVIDIA Parakeet V3.")
    transcribe_stop = threading.Event()
    transcribe_thread = threading.Thread(
        target=progress_heartbeat,
        kwargs={
            "stop": transcribe_stop,
            "progress": 0.40,
            "message_factory": transcription_message,
        },
        daemon=True,
    )
    transcribe_thread.start()
    try:
        with contextlib.closing(wave.open(str(proxy), "rb")) as source:
            if source.getnchannels() != 1 or source.getsampwidth() != 2:
                raise ValueError("Parakeet analysis input must be mono 16-bit PCM")
            sample_rate = source.getframerate()
            raw = source.readframes(source.getnframes())
        samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
        chunk_samples = max(1, int(sample_rate * 240))
        overlap_samples = max(1, int(sample_rate * 1.5))
        words: list[dict[str, Any]] = []
        cursor = 0
        total = max(1, len(samples))
        while cursor < len(samples):
            end = min(len(samples), cursor + chunk_samples)
            model_inputs = processor(
                samples[cursor:end],
                sampling_rate=sample_rate,
                return_tensors="pt",
            )
            model_inputs = {key: value.to(device) for key, value in model_inputs.items()}
            with torch.inference_mode():
                generated = model.generate(**model_inputs)
            _, timestamp_batches = processor.decode(
                generated.sequences,
                durations=generated.durations,
            )
            token_timestamps = timestamp_batches[0] if timestamp_batches else []
            chunk_words = token_timestamps_to_words(token_timestamps, offset=cursor / sample_rate)
            if end < len(samples):
                commit_before = (end - overlap_samples / 2) / sample_rate
                chunk_words = [word for word in chunk_words if float(word["end"]) <= commit_before]
            if words:
                committed_until = float(words[-1]["end"])
                chunk_words = [word for word in chunk_words if float(word["start"]) >= committed_until]
            words.extend(chunk_words)
            emit(
                "progress",
                phase="transcribing",
                progress=min(0.68, 0.40 + 0.28 * end / total),
                message=f"Transcribing with NVIDIA Parakeet V3 ({end / total:.0%} complete).",
            )
            if end >= len(samples):
                break
            cursor = end - overlap_samples
    finally:
        transcribe_stop.set()
        transcribe_thread.join(timeout=1)
    text = " ".join(str(word["text"]).strip() for word in words if str(word["text"]).strip())
    return text, words, device


def finding(
    kind: str,
    severity: str,
    confidence: float,
    start: float,
    end: float,
    message: str,
    *,
    expected: str | None = None,
    observed: str | None = None,
    summary: str = "",
    metrics: dict[str, float] | None = None,
    safety: str = "safe",
    action: str | None = None,
    source_offset: int | None = None,
    source_length: int | None = None,
) -> dict[str, Any]:
    stable = f"{kind}|{start:.3f}|{end:.3f}|{expected or ''}|{observed or ''}"
    return {
        "id": hashlib.sha256(stable.encode("utf-8")).hexdigest()[:16],
        "type": kind,
        "severity": severity,
        "confidence": round(max(0.0, min(confidence, 1.0)), 4),
        "time_range": {"start": round(start, 4), "end": round(end, 4)},
        "message": message,
        "expected_text": expected,
        "observed_text": observed,
        "evidence": {"summary": summary, "metrics": metrics or {}},
        "source_offset": source_offset,
        "source_length": source_length,
        "source_chunk": None,
        "repair_safety": safety,
        "repair_action": action,
        "repair_status": "pending",
        "before_verification": metrics or None,
        "after_verification": None,
    }


def waveform_findings(analysis: AudioAnalysis, profile: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for start, end in analysis.silence_ranges:
        duration = end - start
        if duration > 2.2 and start > 0.75 and end < analysis.duration - 0.75:
            results.append(
                finding(
                    "long_pause",
                    "warning" if duration < 5 else "critical",
                    0.95,
                    start,
                    end,
                    f"Silence lasts {duration:.1f} seconds.",
                    summary="Waveform silence exceeds the natural narration threshold.",
                    metrics={"duration_seconds": duration, "target_seconds": 0.9},
                    action="Shorten this pause to the learned narration cadence.",
                )
            )

    speech_windows = [window for window in analysis.windows if window.rms_db > -55.0]
    median_rms = statistics.median([window.rms_db for window in speech_windows]) if speech_windows else -30.0
    for window in analysis.windows:
        if window.clipped_fraction >= 0.002:
            results.append(
                finding(
                    "clipping",
                    "critical",
                    0.99,
                    window.start,
                    window.end,
                    "The waveform reaches digital clipping.",
                    summary="Samples are at or extremely close to full scale.",
                    metrics={"clipped_fraction": window.clipped_fraction, "peak_dbfs": window.peak_db},
                    safety="review",
                    action="Regenerate this sentence when a reliable voice reference is available.",
                )
            )
        elif window.rms_db > median_rms + 9.0 and window.peak_db > -3.0:
            results.append(
                finding(
                    "loudness_spike",
                    "warning",
                    0.9,
                    window.start,
                    window.end,
                    "This region is much louder than the surrounding narration.",
                    metrics={"rms_dbfs": window.rms_db, "book_median_dbfs": median_rms},
                    action="Lower this region with a smooth gain envelope.",
                )
            )
        elif window.rms_db < median_rms - 14.0 and window.rms_db > -55.0:
            results.append(
                finding(
                    "quiet_region",
                    "warning",
                    0.85,
                    window.start,
                    window.end,
                    "This spoken region is unusually quiet.",
                    metrics={"rms_dbfs": window.rms_db, "book_median_dbfs": median_rms},
                    action="Raise this region with a smooth gain envelope.",
                )
            )

    if profile == "ACX Technical":
        checks = [
            not (-23.0 <= analysis.integrated_rms_db <= -18.0),
            analysis.peak_db > -3.0,
            analysis.noise_floor_db > -60.0,
        ]
        if any(checks):
            results.append(
                finding(
                    "format_compliance",
                    "warning",
                    1.0,
                    0,
                    analysis.duration,
                    "The audio does not meet one or more selected ACX technical targets.",
                    summary="Technical analysis only; this does not guarantee ACX eligibility or acceptance.",
                    metrics={
                        "rms_dbfs": analysis.integrated_rms_db,
                        "peak_dbfs": analysis.peak_db,
                        "noise_floor_dbfs": analysis.noise_floor_db,
                    },
                    action="Normalize using the ACX Technical profile.",
                )
            )
    return merge_adjacent_findings(results)


def merge_adjacent_findings(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: list[dict[str, Any]] = []
    for item in sorted(items, key=lambda value: (value["type"], value["time_range"]["start"])):
        if (
            merged
            and merged[-1]["type"] == item["type"]
            and item["time_range"]["start"] <= merged[-1]["time_range"]["end"] + 0.30
        ):
            previous = merged[-1]
            previous["time_range"]["end"] = item["time_range"]["end"]
            previous["severity"] = "critical" if "critical" in {previous["severity"], item["severity"]} else "warning"
            previous["confidence"] = max(previous["confidence"], item["confidence"])
            previous["evidence"]["metrics"].update(item["evidence"]["metrics"])
            stable = f'{previous["type"]}|{previous["time_range"]["start"]:.3f}|{previous["time_range"]["end"]:.3f}'
            previous["id"] = hashlib.sha256(stable.encode()).hexdigest()[:16]
        else:
            merged.append(item)
    return sorted(merged, key=lambda value: value["time_range"]["start"])


def transcript_findings(expected_text: str, transcript: str, words: list[dict[str, Any]], duration: float) -> list[dict[str, Any]]:
    if not expected_text or not transcript:
        return []
    expected = normalize_words(expected_text)
    observed = normalize_words(transcript)
    matcher = difflib.SequenceMatcher(a=expected, b=observed, autojunk=False)
    results: list[dict[str, Any]] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        expected_phrase = " ".join(expected[i1:i2])
        observed_phrase = " ".join(observed[j1:j2])
        if words and j1 < len(words):
            start = float(words[j1]["start"])
            end_index = min(max(j2 - 1, j1), len(words) - 1)
            end = float(words[end_index]["end"])
        else:
            ratio = j1 / max(len(observed), 1)
            start = duration * ratio
            end = min(duration, start + max(0.5, (j2 - j1) * 0.35))
        left_match = i1 > 0 and j1 > 0 and expected[i1 - 1] == observed[j1 - 1]
        right_match = i2 < len(expected) and j2 < len(observed) and expected[i2] == observed[j2]
        confidence = 0.72 + (0.09 if left_match else 0) + (0.09 if right_match else 0)
        if tag == "delete":
            kind, message = "missing_speech", f'Expected speech is missing: “{expected_phrase}”.'
        elif tag == "insert":
            repeated = bool(observed_phrase and observed_phrase in " ".join(expected[max(0, i1 - 12):i1 + 12]))
            kind = "repeated_speech" if repeated else "extra_speech"
            message = f'Unexpected speech was heard: “{observed_phrase}”.'
        else:
            kind, message = "substitution", f'Expected “{expected_phrase}” but heard “{observed_phrase}”.'
        results.append(
            finding(
                kind,
                "critical" if confidence >= 0.85 else "warning",
                confidence,
                start,
                end,
                message,
                expected=expected_phrase or None,
                observed=observed_phrase or None,
                summary="Expected text and Parakeet word alignment disagree.",
                metrics={"expected_words": float(i2 - i1), "observed_words": float(j2 - j1)},
                safety="review",
                action="Regenerate the containing sentence with the selected voice.",
            )
        )
    return results


def cadence_pause_findings(words: list[dict[str, Any]]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    grouped: dict[str, list[float]] = {"sentence": [], "clause": []}
    pairs: list[tuple[dict[str, Any], dict[str, Any], str, float]] = []
    for left, right in zip(words, words[1:]):
        text = str(left.get("text", "")).strip()
        if text.endswith((".", "!", "?")):
            punctuation_class = "sentence"
        elif text.endswith((",", ";", ":")):
            punctuation_class = "clause"
        else:
            continue
        gap = float(right["start"]) - float(left["end"])
        if 0 <= gap <= 4:
            grouped[punctuation_class].append(gap)
        pairs.append((left, right, punctuation_class, gap))
    defaults = {"sentence": 0.45, "clause": 0.25}
    learned: dict[str, tuple[float, float]] = {}
    for punctuation_class, gaps in grouped.items():
        target = statistics.median(gaps) if len(gaps) >= 5 else defaults[punctuation_class]
        deviations = [abs(value - target) for value in gaps]
        mad = statistics.median(deviations) if deviations else 0.08
        learned[punctuation_class] = (max(0.10, target), max(0.04, mad))
    for left, right, punctuation_class, gap in pairs:
        target, mad = learned[punctuation_class]
        if gap < target * 0.35:
            results.append(
                finding(
                    "short_pause",
                    "warning",
                    0.82,
                    float(left["end"]),
                    float(right["start"]),
                    f"Only {max(gap, 0):.2f} seconds separates these sentences.",
                    summary="Parakeet punctuation and word timestamps indicate a rushed boundary.",
                    metrics={"duration_seconds": max(gap, 0), "target_seconds": target},
                    safety="review",
                    action="Insert a short natural pause.",
                )
            )
        elif gap > max(2.2 if punctuation_class == "sentence" else 1.5, target + 5 * mad):
            results.append(
                finding(
                    "long_pause",
                    "warning",
                    0.78,
                    float(left["end"]),
                    float(right["start"]),
                    f"This {punctuation_class} pause is much longer than the book’s normal cadence.",
                    summary="Robust median and median-absolute-deviation cadence analysis.",
                    metrics={
                        "duration_seconds": gap,
                        "learned_target_seconds": target,
                        "median_absolute_deviation": mad,
                        "target_seconds": target,
                    },
                    safety="review",
                    action="Shorten the pause to the book’s learned cadence.",
                )
            )
    return results


def ffmpeg_loudness_metrics(audio: Path, ffmpeg: Path) -> dict[str, float]:
    process = run(
        [
            str(ffmpeg),
            "-hide_banner",
            "-nostats",
            "-i",
            str(audio),
            "-af",
            "loudnorm=I=-20:TP=-1.5:LRA=11:print_format=json",
            "-f",
            "null",
            "-",
        ],
        check=False,
    )
    match = re.search(r"\{\s*\"input_i\".*?\}", process.stderr, flags=re.DOTALL)
    if not match:
        return {}
    try:
        payload = json.loads(match.group(0))
    except json.JSONDecodeError:
        return {}
    mapping = {
        "input_i": "integrated_lufs",
        "input_tp": "true_peak_dbtp",
        "input_lra": "loudness_range_lu",
        "input_thresh": "loudness_threshold_lufs",
    }
    result: dict[str, float] = {}
    for source, destination in mapping.items():
        try:
            result[destination] = float(payload[source])
        except (KeyError, TypeError, ValueError):
            pass
    return result


def container_findings(probe: dict[str, Any], analysis: AudioAnalysis, profile: str) -> list[dict[str, Any]]:
    if profile != "ACX Technical":
        return []
    stream = next(item for item in probe.get("streams", []) if item.get("codec_type") == "audio")
    format_data = probe.get("format", {})
    codec = str(stream.get("codec_name", ""))
    sample_rate = int(stream.get("sample_rate") or 0)
    bit_rate = int(format_data.get("bit_rate") or 0)
    channels = int(stream.get("channels") or 0)
    problems: list[str] = []
    if codec != "mp3":
        problems.append("final delivery is not MP3")
    if sample_rate != 44100:
        problems.append("sample rate is not 44.1 kHz")
    if bit_rate and bit_rate < 192000:
        problems.append("bit rate is below 192 kbps")
    if channels not in {1, 2}:
        problems.append("channel layout is not mono or stereo")
    if analysis.duration > 120 * 60:
        problems.append("file is longer than 120 minutes")
    if not problems:
        return []
    return [
        finding(
            "format_compliance",
            "warning",
            1.0,
            0,
            analysis.duration,
            "ACX delivery-format issue: " + "; ".join(problems) + ".",
            summary="Technical analysis only; this does not guarantee ACX eligibility or acceptance.",
            metrics={
                "sample_rate_hz": float(sample_rate),
                "bit_rate_bps": float(bit_rate),
                "channels": float(channels),
                "duration_seconds": analysis.duration,
            },
            action="Export an ACX Technical MP3 copy after reviewing the narration.",
        )
    ]


def sentence_containing(text: str, phrase: str) -> str:
    if not phrase:
        return ""
    position = text.casefold().find(phrase.casefold())
    if position < 0:
        return phrase
    start = max(text.rfind(".", 0, position), text.rfind("!", 0, position), text.rfind("?", 0, position))
    start = 0 if start < 0 else start + 1
    ends = [value for value in (text.find(".", position), text.find("!", position), text.find("?", position)) if value >= 0]
    end = min(ends) + 1 if ends else min(len(text), position + 400)
    sentence = re.sub(r"\s+", " ", text[start:end]).strip()
    return sentence[:600] or phrase


def enrich_speech_findings(
    findings: list[dict[str, Any]],
    expected_text: str,
    generated_chunks_path: str | None,
    words: list[dict[str, Any]],
) -> None:
    for item in findings:
        if item["type"] in {"missing_speech", "substitution"} and item.get("expected_text"):
            item["expected_text"] = sentence_containing(expected_text, item["expected_text"])
    chunks: list[dict[str, Any]] = []
    if generated_chunks_path and Path(generated_chunks_path).is_file():
        chunks = load_json(Path(generated_chunks_path)).get("chunks", [])
    for item in findings:
        if item["type"] != "clipping":
            continue
        timestamp = float(item["time_range"]["start"])
        match = next(
            (
                chunk
                for chunk in chunks
                if float(chunk.get("start", -1)) <= timestamp <= float(chunk.get("end", -1))
            ),
            None,
        )
        if match:
            item["source_chunk"] = int(match["index"])
            item["expected_text"] = str(match.get("text", ""))
            item["time_range"] = {
                "start": float(match.get("start", item["time_range"]["start"])),
                "end": float(match.get("end", item["time_range"]["end"])),
            }
            item["repair_action"] = "Regenerate the affected source chunk with Qwen."
            continue
        nearby = next(
            (
                word
                for word in words
                if float(word.get("start", -1)) <= timestamp <= float(word.get("end", -1))
            ),
            None,
        )
        if expected_text and nearby:
            sentence = sentence_containing(expected_text, str(nearby.get("text", "")).strip())
            if sentence:
                item["expected_text"] = sentence
                item["repair_action"] = "Regenerate the containing sentence with Qwen."
                continue
        item["repair_safety"] = "unrepairable"
        item["repair_action"] = "Clipped source samples cannot be restored without reliable source text."


def auto_voice_reference(
    audio: Path,
    ffmpeg: Path,
    output: Path,
    analysis: AudioAnalysis,
    words: list[dict[str, Any]],
) -> tuple[Path, Path] | None:
    if analysis.duration < 8 or not words:
        return None
    candidates: list[tuple[float, float]] = []
    for start in range(0, max(1, int(analysis.duration - 10)), 2):
        end = min(analysis.duration, start + 12)
        windows = [window for window in analysis.windows if start <= window.start < end]
        if not windows:
            continue
        speech = [window for window in windows if -38 <= window.rms_db <= -10]
        clipped = any(window.clipped_fraction > 0 or window.peak_db > -0.5 for window in windows)
        if not clipped and len(speech) / len(windows) >= 0.60:
            variation = statistics.pstdev([window.rms_db for window in speech]) if len(speech) > 1 else 0
            candidates.append((variation, float(start)))
    if not candidates:
        return None
    _, start = min(candidates)
    end = min(analysis.duration, start + 12)
    matching_words = [
        str(word["text"]).strip()
        for word in words
        if float(word["start"]) >= start and float(word["end"]) <= end
    ]
    transcript = " ".join(word for word in matching_words if word).strip()
    if len(normalize_words(transcript)) < 8:
        return None
    audio_path = unique_path(output, audio.stem, ".voice-reference.wav")
    transcript_path = audio_path.with_suffix(".txt")
    run(
        [
            str(ffmpeg),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{start:.3f}",
            "-t",
            f"{end - start:.3f}",
            "-i",
            str(audio),
            "-ac",
            "1",
            "-ar",
            "24000",
            "-c:a",
            "pcm_s16le",
            str(audio_path),
        ]
    )
    transcript_path.write_text(transcript, encoding="utf-8")
    return audio_path, transcript_path


def status_for(findings: Sequence[dict[str, Any]]) -> str:
    if any(item["severity"] == "critical" for item in findings):
        return "Needs Review"
    if findings:
        return "Passed with Warnings"
    return "Passed"


def markdown_report(report: dict[str, Any]) -> str:
    summary = report["summary"]
    metrics = report["global_metrics"]
    lines = [
        f'# Audiobook Audit — {Path(report["input_audio"]).name}',
        "",
        f'**Status:** {summary["status"]}',
        "",
        f'- Duration: {format_time(summary["duration_seconds"])}',
        f'- Findings: {summary["finding_count"]} ({summary["critical_count"]} critical, {summary["warning_count"]} warnings)',
        f'- Integrated level: {metrics.get("integrated_rms_dbfs", -120):.1f} dBFS',
        f'- Peak: {metrics.get("peak_dbfs", -120):.1f} dBFS',
        f'- Estimated noise floor: {metrics.get("noise_floor_dbfs", -120):.1f} dBFS',
        f'- Profile: {report["quality_profile"]}',
        "",
    ]
    if report["quality_profile"] == "ACX Technical":
        lines.extend(
            [
                "> ACX Technical is an engineering check only. It does not guarantee ACX acceptance or eligibility.",
                "",
            ]
        )
    lines.extend(
        [
            "## Findings",
            "",
            "| Time | Severity | Problem | Confidence | Repair | Status |",
            "|---:|---|---|---:|---|---|",
        ]
    )
    for item in report["findings"]:
        time_text = f'{format_time(item["time_range"]["start"])}–{format_time(item["time_range"]["end"])}'
        message = item["message"].replace("|", "\\|")
        lines.append(
            f'| {time_text} | {item["severity"].title()} | {message} | {item["confidence"]:.0%} | '
            f'{item["repair_safety"].title()} | {item["repair_status"].replace("_", " ").title()} |'
        )
        if item.get("expected_text") or item.get("observed_text"):
            lines.append(
                f'|  |  | Expected: {item.get("expected_text") or "—"}<br>Observed: '
                f'{item.get("observed_text") or "—"} |  |  |  |'
            )
    if not report["findings"]:
        lines.append("| — | — | No problems were detected. | — | — | — |")
    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- The original audio was not modified.",
            "- Timestamps refer to the original audio timeline.",
            "- Review low-confidence speech findings by listening to the surrounding audio.",
            "",
        ]
    )
    return "\n".join(lines)


def format_time(value: float) -> str:
    seconds = max(0, int(round(value)))
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes}:{seconds:02d}"


def audit(manifest_path: Path, *, verification: bool = False) -> tuple[dict[str, Any], Path, Path]:
    manifest = load_json(manifest_path)
    audio, ffmpeg, ffprobe = validate_manifest(manifest)
    output = Path(manifest["output_directory"])
    session_id = str(manifest.get("session_id") or hashlib.sha256(str(audio).encode()).hexdigest()[:12])
    session_dir = output / ".readasme-audit" / session_id
    session_dir.mkdir(parents=True, exist_ok=True)
    emit("progress", phase="analyzing", progress=0.05, message="Inspecting the audio container.")
    probe = probe_audio(audio, ffprobe)
    proxy = session_dir / "analysis-16k-mono.wav"
    if not proxy.exists() or proxy.stat().st_mtime < audio.stat().st_mtime:
        emit("progress", phase="analyzing", progress=0.12, message="Preparing a bounded analysis copy.")
        decode_proxy(audio, ffmpeg, proxy)
    emit("progress", phase="analyzing", progress=0.20, message="Measuring pauses and volume.")
    analysis = analyze_wave(proxy)
    loudness = ffmpeg_loudness_metrics(audio, ffmpeg)
    expected_text = extract_expected_text(manifest.get("expected_text"))

    transcript = ""
    words: list[dict[str, Any]] = []
    device = "not loaded"
    transcript_cache = session_dir / "transcript.json"
    if transcript_cache.exists() and transcript_cache.stat().st_mtime >= audio.stat().st_mtime:
        cached = load_json(transcript_cache)
        transcript = str(cached.get("text", ""))
        words = list(cached.get("words", []))
        device = str(cached.get("device", "cache"))
    elif not verification:
        transcript, words, device = transcribe(proxy)
        write_json(transcript_cache, {"text": transcript, "words": words, "device": device})

    emit("progress", phase="analyzing", progress=0.72, message="Comparing timing, transcript, and source text.")
    profile = str(manifest.get("quality_profile", "Natural"))
    findings = waveform_findings(analysis, profile)
    findings.extend(cadence_pause_findings(words))
    findings.extend(container_findings(probe, analysis, profile))
    findings.extend(transcript_findings(expected_text, transcript, words, analysis.duration))
    for suggestion in source_suggestions(expected_text):
        findings.append(
            finding(
                "source_typo",
                "info",
                0.9,
                0,
                0,
                suggestion["message"],
                expected=suggestion["original"],
                observed=suggestion["replacement"],
                summary="The expected source text contains a deterministic repeated-word or punctuation issue.",
                safety="unrepairable",
                action="Review the source text; do not change the original book automatically.",
                source_offset=int(suggestion["offset"]),
                source_length=int(suggestion["length"]),
            )
        )
    enrich_speech_findings(findings, expected_text, manifest.get("generated_chunks"), words)
    findings.sort(key=lambda item: (item["time_range"]["start"], item["type"]))

    stem = audio.stem
    json_path = unique_path(output, stem, ".audit.json") if not verification else session_dir / "verification.json"
    markdown_path = json_path.with_suffix(".md") if not verification else session_dir / "verification.md"
    output_files = {
        "json_report": str(json_path),
        "markdown_report": str(markdown_path),
        "transcript": str(transcript_cache),
    }
    if not manifest.get("voice_reference") and not verification:
        emit("progress", phase="analyzing", progress=0.82, message="Selecting a clean voice reference for optional repairs.")
        reference = auto_voice_reference(audio, ffmpeg, output, analysis, words)
        if reference:
            output_files["voice_reference"] = str(reference[0])
            output_files["voice_reference_transcript"] = str(reference[1])

    report = {
        "schema_version": SCHEMA_VERSION,
        "report_id": hashlib.sha256(f"{audio}|{dt.datetime.now(dt.timezone.utc).isoformat()}".encode()).hexdigest()[:16],
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "input_audio": str(audio),
        "expected_text": manifest.get("expected_text"),
        "quality_profile": profile,
        "language": manifest.get("language", "auto"),
        "incomplete": False,
        "summary": {
            "status": status_for(findings),
            "duration_seconds": analysis.duration,
            "finding_count": len(findings),
            "critical_count": sum(item["severity"] == "critical" for item in findings),
            "warning_count": sum(item["severity"] == "warning" for item in findings),
            "repaired_count": 0,
        },
        "global_metrics": {
            "integrated_rms_dbfs": analysis.integrated_rms_db,
            "peak_dbfs": analysis.peak_db,
            "noise_floor_dbfs": analysis.noise_floor_db,
            "clipped_fraction": analysis.clipped_fraction,
            "duration_seconds": analysis.duration,
            "parakeet_word_count": float(len(words)),
            **loudness,
        },
        "findings": findings,
        "output_files": output_files,
        "timeline_map": None,
        "engine": {"model": MODEL_ID, "device": device, "ffmpeg_probe": probe.get("format", {})},
    }
    write_json(json_path, report)
    markdown_path.write_text(markdown_report(report), encoding="utf-8")
    emit(
        "complete",
        phase="complete",
        progress=1.0,
        message=report["summary"]["status"],
        report=str(json_path),
    )
    return report, json_path, markdown_path


def select_repairs(report: dict[str, Any], manifest: dict[str, Any]) -> list[dict[str, Any]]:
    mode = str(manifest.get("repair_mode") or "ids")
    ids = set(manifest.get("repair_finding_ids") or [])
    if mode == "all_safe":
        return [item for item in report["findings"] if item["repair_safety"] == "safe"]
    if mode == "all":
        return [item for item in report["findings"] if item["repair_safety"] != "unrepairable"]
    return [item for item in report["findings"] if item["id"] in ids]


def locate_report(manifest: dict[str, Any], audio: Path) -> Path:
    explicit = manifest.get("report_path")
    if explicit and Path(explicit).is_file():
        return Path(explicit)
    candidates = sorted(
        Path(manifest["output_directory"]).glob(f"{audio.stem}*.audit.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise ValueError("no audit report was found for this audio file")
    return candidates[0]


def timeline_edits(findings: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    edits: list[dict[str, Any]] = []
    for item in findings:
        start = float(item["time_range"]["start"])
        end = float(item["time_range"]["end"])
        metrics = item.get("evidence", {}).get("metrics", {})
        if item["type"] == "long_pause":
            target = float(metrics.get("target_seconds", 0.9))
            if end - start > target:
                excess = (end - start) - target
                edits.append({"type": "cut", "start": start + target / 2, "end": end - target / 2, "amount": excess})
        elif item["type"] == "short_pause":
            target = float(metrics.get("target_seconds", 0.4))
            gap = max(0.0, end - start)
            if target > gap:
                edits.append({"type": "insert", "at": end, "amount": target - gap})
        elif item["type"] == "loudness_spike":
            target = float(metrics.get("book_median_dbfs", -24.0))
            measured = float(metrics.get("rms_dbfs", target + 6.0))
            edits.append({"type": "gain", "start": start, "end": end, "db": max(-12.0, min(-1.0, target - measured))})
        elif item["type"] == "quiet_region":
            target = float(metrics.get("book_median_dbfs", -24.0))
            measured = float(metrics.get("rms_dbfs", target - 6.0))
            edits.append({"type": "gain", "start": start, "end": end, "db": min(12.0, max(1.0, target - measured))})
    return sorted(edits, key=lambda item: item.get("start", item.get("at", 0.0)))


def wav_duration(path: Path) -> float:
    with contextlib.closing(wave.open(str(path), "rb")) as source:
        return source.getnframes() / max(source.getframerate(), 1)


def generate_speech_replacement(
    item: dict[str, Any],
    manifest: dict[str, Any],
    folder: Path,
) -> Path | None:
    if item["type"] in {"extra_speech", "repeated_speech"}:
        return None
    text = str(item.get("expected_text") or "").strip()
    if not text:
        raise ValueError(f'{item["type"].replace("_", " ")} has no source text for regeneration')
    qwen_python = Path(str(manifest.get("qwen_python") or ""))
    converter = Path(str(manifest.get("converter") or ""))
    voice = Path(str(manifest.get("voice_reference") or ""))
    voice_transcript = Path(str(manifest.get("voice_transcript") or ""))
    for path, label in (
        (qwen_python, "Qwen Python"),
        (converter, "Qwen converter"),
        (voice, "voice reference"),
        (voice_transcript, "voice transcript"),
    ):
        if not path.is_file():
            raise ValueError(f"{label} is required for speech repair")
    repair_folder = folder / f"speech-{item['id']}"
    books = repair_folder / "book_to_convert"
    output = repair_folder / "audiobooks"
    books.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    (books / "replacement.txt").write_text(text, encoding="utf-8")
    emit("progress", phase="repairing", progress=0.22, message=f"Regenerating speech at {format_time(item['time_range']['start'])}.")
    process = run(
        [
            str(qwen_python),
            str(converter),
            "--voice-clone",
            "--voice-sample",
            str(voice),
            "--voice-transcript-file",
            str(voice_transcript),
        ],
        check=False,
        cwd=repair_folder,
    )
    generated = output / "replacement.wav"
    if process.returncode or not generated.is_file():
        detail = process.stderr.strip().splitlines()[-1] if process.stderr.strip() else "no replacement audio was produced"
        raise RuntimeError(f"Qwen speech regeneration failed: {detail}")
    return generated


def make_filter_complex(duration: float, sample_rate: int, channel_layout: str, edits: list[dict[str, Any]], profile: str) -> tuple[str, list[dict[str, float]], list[Path]]:
    cuts = [item for item in edits if item["type"] == "cut"]
    inserts = [item for item in edits if item["type"] == "insert"]
    replacements = [item for item in edits if item["type"] == "replace"]
    replacement_paths = [Path(item["path"]) for item in replacements]
    boundaries: list[tuple[float, str, float]] = []
    for item in cuts:
        boundaries.append((float(item["start"]), "cut_start", float(item["end"])))
    for item in inserts:
        boundaries.append((float(item["at"]), "insert", float(item["amount"])))
    for replacement_index, item in enumerate(replacements, start=1):
        boundaries.append((float(item["start"]), f"replace:{replacement_index}", float(item["end"])))
    boundaries.sort()

    filter_parts: list[str] = []
    labels: list[str] = []
    timeline: list[dict[str, float]] = []
    cursor = 0.0
    repaired_cursor = 0.0
    index = 0
    for point, kind, value in boundaries:
        if point > cursor:
            label = f"s{index}"
            filter_parts.append(f"[0:a]atrim=start={cursor:.6f}:end={point:.6f},asetpts=PTS-STARTPTS[{label}]")
            labels.append(f"[{label}]")
            timeline.append(
                {
                    "original_start": cursor,
                    "original_end": point,
                    "repaired_start": repaired_cursor,
                    "repaired_end": repaired_cursor + point - cursor,
                }
            )
            repaired_cursor += point - cursor
            index += 1
            cursor = point
        if kind == "cut_start":
            cursor = value
        elif kind.startswith("replace:"):
            input_index = int(kind.split(":", 1)[1])
            replacement = replacements[input_index - 1]
            replacement_duration = float(replacement["duration"])
            label = f"s{index}"
            filter_parts.append(
                f"[{input_index}:a]aresample={sample_rate},aformat=channel_layouts={channel_layout},asetpts=PTS-STARTPTS[{label}]"
            )
            labels.append(f"[{label}]")
            timeline.append(
                {
                    "original_start": point,
                    "original_end": value,
                    "repaired_start": repaired_cursor,
                    "repaired_end": repaired_cursor + replacement_duration,
                }
            )
            repaired_cursor += replacement_duration
            cursor = value
            index += 1
        else:
            label = f"s{index}"
            filter_parts.append(f"anullsrc=r={sample_rate}:cl={channel_layout},atrim=duration={value:.6f}[{label}]")
            labels.append(f"[{label}]")
            repaired_cursor += value
            index += 1
    if cursor < duration:
        label = f"s{index}"
        filter_parts.append(f"[0:a]atrim=start={cursor:.6f}:end={duration:.6f},asetpts=PTS-STARTPTS[{label}]")
        labels.append(f"[{label}]")
        timeline.append(
            {
                "original_start": cursor,
                "original_end": duration,
                "repaired_start": repaired_cursor,
                "repaired_end": repaired_cursor + duration - cursor,
            }
        )

    if len(labels) == 1:
        joined = labels[0]
    else:
        filter_parts.append("".join(labels) + f"concat=n={len(labels)}:v=0:a=1[joined]")
        joined = "[joined]"

    chain: list[str] = []
    for item in edits:
        if item["type"] == "gain":
            mapped_start = map_time(float(item["start"]), timeline)
            mapped_end = map_time(float(item["end"]), timeline)
            chain.append(f"volume={item['db']:.2f}dB:enable='between(t,{mapped_start:.6f},{mapped_end:.6f})'")
    if profile == "ACX Technical":
        chain.append("loudnorm=I=-20.5:TP=-3.0:LRA=7")
    else:
        chain.append("alimiter=limit=0.891:attack=5:release=50")
    filter_parts.append(f"{joined}{','.join(chain)}[out]")
    return ";".join(filter_parts), timeline, replacement_paths


def map_time(original: float, timeline: Sequence[dict[str, float]]) -> float:
    for item in timeline:
        if item["original_start"] <= original <= item["original_end"]:
            return item["repaired_start"] + (original - item["original_start"])
    if timeline:
        return timeline[-1]["repaired_end"]
    return original


def ffmetadata_for_chapters(
    chapters: Sequence[dict[str, Any]],
    timeline: Sequence[dict[str, float]],
    destination: Path,
) -> bool:
    if not chapters:
        return False
    lines = [";FFMETADATA1"]
    for index, chapter in enumerate(chapters, start=1):
        original_start = float(chapter.get("start_time", 0))
        original_end = float(chapter.get("end_time", original_start))
        start = int(round(map_time(original_start, timeline) * 1000))
        end = max(start + 1, int(round(map_time(original_end, timeline) * 1000)))
        title = str(chapter.get("tags", {}).get("title", f"Chapter {index}"))
        title = title.replace("\\", "\\\\").replace("=", "\\=").replace(";", "\\;").replace("#", "\\#")
        lines.extend(["[CHAPTER]", "TIMEBASE=1/1000", f"START={start}", f"END={end}", f"title={title}"])
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def same_format_copy(
    master: Path,
    original: Path,
    ffmpeg: Path,
    destination: Path,
    probe: dict[str, Any],
    timeline: Sequence[dict[str, float]],
) -> None:
    suffix = destination.suffix.lower()
    codec_args: list[str]
    if suffix == ".mp3":
        codec_args = ["-c:a", "libmp3lame", "-b:a", "192k"]
    elif suffix in {".m4a", ".m4b"}:
        codec_args = ["-c:a", "aac", "-b:a", "192k"]
    elif suffix == ".flac":
        codec_args = ["-c:a", "flac"]
    else:
        codec_args = ["-c:a", "pcm_s16le"]
    with tempfile.TemporaryDirectory(prefix="readasme-metadata-") as temporary:
        metadata_path = Path(temporary) / "chapters.ffmetadata"
        has_chapters = ffmetadata_for_chapters(probe.get("chapters", []), timeline, metadata_path)
        command = [
            str(ffmpeg),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(master),
            "-i",
            str(original),
        ]
        if has_chapters:
            command.extend(["-f", "ffmetadata", "-i", str(metadata_path)])
        command.extend(
            [
            "-map",
            "0:a",
            "-map",
            "1:v?",
            "-map_metadata",
            "1",
            "-c:v",
            "copy",
        ]
        )
        if has_chapters:
            command.extend(["-map_chapters", "2"])
        command.extend(
            [
            *codec_args,
            str(destination),
            ]
        )
        run(command)


def repair(manifest_path: Path) -> tuple[dict[str, Any], Path]:
    manifest = load_json(manifest_path)
    audio, ffmpeg, ffprobe = validate_manifest(manifest)
    report_path = locate_report(manifest, audio)
    report = load_json(report_path)
    selected = select_repairs(report, manifest)
    if not selected:
        raise ValueError("no repairable findings were selected")
    emit("progress", phase="repairing", progress=0.10, message="Building a non-destructive repair plan.")
    probe = probe_audio(audio, ffprobe)
    audio_stream = next(item for item in probe["streams"] if item.get("codec_type") == "audio")
    sample_rate = int(audio_stream.get("sample_rate") or 48000)
    channels = int(audio_stream.get("channels") or 1)
    layout = str(audio_stream.get("channel_layout") or ("mono" if channels == 1 else "stereo"))
    duration = float(probe.get("format", {}).get("duration") or report["summary"]["duration_seconds"])
    output_folder = Path(manifest["output_directory"])
    edits = timeline_edits(selected)
    speech_selected = [
        item
        for item in selected
        if item["type"] in {"missing_speech", "extra_speech", "substitution", "repeated_speech", "clipping"}
    ]
    session_folder = output_folder / ".readasme-repair" / str(manifest.get("session_id", "session"))
    session_folder.mkdir(parents=True, exist_ok=True)
    for item in speech_selected:
        if item["type"] in {"extra_speech", "repeated_speech"}:
            edits.append(
                {
                    "type": "replace",
                    "start": float(item["time_range"]["start"]),
                    "end": float(item["time_range"]["end"]),
                    "path": "",
                    "duration": 0.20,
                    "silence": True,
                }
            )
            continue
        replacement = generate_speech_replacement(item, manifest, session_folder)
        if replacement:
            edits.append(
                {
                    "type": "replace",
                    "start": float(item["time_range"]["start"]),
                    "end": float(item["time_range"]["end"]),
                    "path": str(replacement),
                    "duration": wav_duration(replacement),
                }
            )
    if not edits:
        raise ValueError("the selected findings have no available automatic waveform repair")
    # Silence replacements are represented as a cut plus a short insertion.
    expanded_edits: list[dict[str, Any]] = []
    for item in edits:
        if item.get("silence"):
            expanded_edits.extend(
                [
                    {"type": "cut", "start": item["start"], "end": item["end"], "amount": item["end"] - item["start"]},
                    {"type": "insert", "at": item["end"], "amount": item["duration"]},
                ]
            )
        else:
            expanded_edits.append(item)
    edits = sorted(expanded_edits, key=lambda item: item.get("start", item.get("at", 0.0)))
    graph, timeline, replacement_paths = make_filter_complex(duration, sample_rate, layout, edits, str(manifest.get("quality_profile", "Natural")))
    master = unique_path(output_folder, audio.stem, ".repaired.wav")
    partial = master.with_suffix(".partial.wav")
    emit("progress", phase="repairing", progress=0.35, message="Applying timing and loudness repairs.")
    try:
        command = [
                str(ffmpeg),
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(audio),
        ]
        for replacement in replacement_paths:
            command.extend(["-i", str(replacement)])
        command.extend(
            [
                "-filter_complex",
                graph,
                "-map",
                "[out]",
                "-c:a",
                "pcm_s16le",
                str(partial),
            ]
        )
        run(command)
        partial.replace(master)
    finally:
        partial.unlink(missing_ok=True)

    same_format: Path | None = None
    if bool(manifest.get("output_same_format")) and audio.suffix.lower() != ".wav":
        same_format = unique_path(output_folder, audio.stem, f".repaired{audio.suffix.lower()}")
        same_format_copy(master, audio, ffmpeg, same_format, probe, timeline)

    emit("progress", phase="verifying", progress=0.72, message="Verifying the repaired audiobook.")
    before_metrics = report.get("global_metrics", {})
    with tempfile.TemporaryDirectory(prefix="readasme-verify-") as temporary:
        proxy = decode_proxy(master, ffmpeg, Path(temporary) / "verify.wav")
        after = analyze_wave(proxy)
        speech_verification_ok = True
        if speech_selected:
            emit("progress", phase="verifying", progress=0.80, message="Rechecking regenerated speech with Parakeet.")
            repaired_transcript, _, _ = transcribe(proxy)
            repaired_words = normalize_words(repaired_transcript)
            repaired_word_set = set(repaired_words)
            for item in speech_selected:
                expected_words = normalize_words(str(item.get("expected_text") or ""))
                if not expected_words:
                    continue
                covered = sum(word in repaired_word_set for word in expected_words) / len(expected_words)
                if covered < 0.65:
                    item["repair_status"] = "rolled_back"
                    speech_verification_ok = False
    improved = (
        after.clipped_fraction <= float(before_metrics.get("clipped_fraction", 1.0)) + 1e-7
        and after.peak_db <= max(-0.1, float(before_metrics.get("peak_dbfs", 0.0)) + 0.25)
        and speech_verification_ok
    )
    if not improved:
        master.unlink(missing_ok=True)
        if same_format:
            same_format.unlink(missing_ok=True)
        selected_ids = {item["id"] for item in selected}
        for item in report["findings"]:
            if item["id"] in selected_ids:
                item["repair_status"] = "rolled_back"
        write_json(report_path, report)
        Path(report["output_files"]["markdown_report"]).write_text(markdown_report(report), encoding="utf-8")
        raise RuntimeError("verification found worse peak or clipping measurements; the repaired copy was rolled back")

    selected_ids = {item["id"] for item in selected}
    for item in report["findings"]:
        if item["id"] in selected_ids:
            item["repair_status"] = "repaired"
            item["after_verification"] = {
                "peak_dbfs": after.peak_db,
                "integrated_rms_dbfs": after.integrated_rms_db,
                "clipped_fraction": after.clipped_fraction,
            }
    report["summary"]["repaired_count"] = sum(item["repair_status"] == "repaired" for item in report["findings"])
    report["output_files"]["repaired_wav"] = str(master)
    if same_format:
        report["output_files"]["repaired_same_format"] = str(same_format)
    report["timeline_map"] = timeline
    write_json(report_path, report)
    Path(report["output_files"]["markdown_report"]).write_text(markdown_report(report), encoding="utf-8")
    emit("complete", phase="complete", progress=1.0, message="Repair complete", report=str(report_path), output=str(master))
    return report, master


def verify(manifest_path: Path) -> None:
    audit(manifest_path, verification=True)


def extract_reference(manifest_path: Path) -> Path:
    manifest = load_json(manifest_path)
    audio, ffmpeg, _ = validate_manifest(manifest)
    output = Path(manifest["output_directory"])
    with tempfile.TemporaryDirectory(prefix="readasme-reference-") as temporary:
        proxy = decode_proxy(audio, ffmpeg, Path(temporary) / "proxy.wav")
        analysis = analyze_wave(proxy, window_seconds=1.0)
    candidates = [
        window
        for window in analysis.windows
        if -36.0 <= window.rms_db <= -12.0 and window.peak_db < -1.0 and window.clipped_fraction == 0
    ]
    if not candidates:
        raise ValueError("no clean single-narrator voice sample could be found automatically")
    center = candidates[len(candidates) // 2].start
    start = max(0.0, center - 1.0)
    duration = min(12.0, analysis.duration - start)
    destination = unique_path(output, audio.stem, ".voice-reference.wav")
    run(
        [
            str(ffmpeg),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{start:.3f}",
            "-t",
            f"{duration:.3f}",
            "-i",
            str(audio),
            "-ac",
            "1",
            "-ar",
            "24000",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ]
    )
    emit("complete", phase="complete", progress=1.0, message="Voice reference extracted", output=str(destination))
    return destination


def review_source(path: Path, output: Path) -> None:
    text = extract_expected_text(str(path))
    suggestions = source_suggestions(text)
    payload = {"schema_version": 1, "source": str(path), "text": text, "suggestions": suggestions}
    write_json(output, payload)
    emit("complete", phase="complete", progress=1.0, message=f"{len(suggestions)} source text suggestions", output=str(output))


def main() -> None:
    parser = argparse.ArgumentParser(description="Audit and repair ReadAsMe audiobooks")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("audit", "repair", "verify", "extract-reference"):
        child = subparsers.add_parser(command)
        child.add_argument("--manifest", required=True, type=Path)
    source = subparsers.add_parser("review-source")
    source.add_argument("--source", required=True, type=Path)
    source.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "audit":
            audit(args.manifest)
        elif args.command == "repair":
            repair(args.manifest)
        elif args.command == "verify":
            verify(args.manifest)
        elif args.command == "extract-reference":
            extract_reference(args.manifest)
        else:
            review_source(args.source, args.output)
    except KeyboardInterrupt:
        emit("cancelled", phase="cancelled", progress=1.0, message="Operation cancelled")
        raise SystemExit(130)
    except Exception as error:
        fail(str(error), 1)


if __name__ == "__main__":
    main()
