import os
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from audiobook_converter import (
    CHUNK_SIZE_CHARACTERS,
    CHUNK_SIZE_WORDS,
    QwenAudiobookConverter,
    QwenRequestTimeout,
)


def write_test_wav(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(24_000)
        audio.writeframes(b"\x00\x00" * 100)


class AudiobookConverterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.converter = QwenAudiobookConverter.__new__(QwenAudiobookConverter)
        self.converter.logger = Mock()

    def test_combine_chunks_requires_every_chunk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            previous_directory = Path.cwd()
            os.chdir(temporary_directory)
            try:
                write_test_wav(Path("chunks/chunk_0001.wav"))
                output = Path("audiobooks/book.wav")
                output.parent.mkdir()

                success = self.converter.combine_chunks(
                    total_chunks=2,
                    output_path=output,
                    results={1: True, 2: False},
                )

                self.assertFalse(success)
                self.assertFalse(output.exists())
            finally:
                os.chdir(previous_directory)

    def test_combine_chunks_writes_complete_audio(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            previous_directory = Path.cwd()
            os.chdir(temporary_directory)
            try:
                write_test_wav(Path("chunks/chunk_0001.wav"))
                write_test_wav(Path("chunks/chunk_0002.wav"))
                output = Path("audiobooks/book.wav")
                output.parent.mkdir()

                success = self.converter.combine_chunks(
                    total_chunks=2,
                    output_path=output,
                    results={1: True, 2: True},
                )

                self.assertTrue(success)
                self.assertTrue(output.exists())
                with wave.open(str(output), "rb") as audio:
                    self.assertEqual(audio.getnframes(), 200)
            finally:
                os.chdir(previous_directory)

    def test_timeout_retries_the_same_chunk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "chunk.wav"
            write_test_wav(output)
            self.converter.generate_chunk_via_qwen = Mock(
                side_effect=[QwenRequestTimeout("slow chunk"), str(output)]
            )

            with patch("audiobook_converter.time.sleep"):
                success = self.converter.process_chunk_with_retry((1, "A slow sentence."))

            self.assertTrue(success)
            self.assertEqual(self.converter.generate_chunk_via_qwen.call_count, 2)

    def test_failed_run_cleanup_preserves_resume_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            previous_directory = Path.cwd()
            os.chdir(temporary_directory)
            try:
                write_test_wav(Path("chunks/chunk_0001.wav"))
                write_test_wav(Path("cache/audio_chunks/cached.wav"))

                with patch.dict(
                    os.environ,
                    {"READ_AS_ME_APP_SUPPORT": "", "QWEN_AUDIOBOOK_APP_SUPPORT": ""},
                    clear=False,
                ):
                    self.converter.cleanup_chunks(clear_cache=False)

                self.assertFalse(Path("chunks/chunk_0001.wav").exists())
                self.assertTrue(Path("cache/audio_chunks/cached.wav").exists())
            finally:
                os.chdir(previous_directory)

    def test_readasme_uses_persistent_resume_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with patch.dict(os.environ, {"READ_AS_ME_APP_SUPPORT": temporary_directory}, clear=False):
                cache = self.converter.cache_directory()

            self.assertEqual(cache, Path(temporary_directory) / "cache" / "qwen-audio-chunks")

    def test_resume_cache_distinguishes_voice_samples_with_same_filename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first_sample = root / "first" / "voice.wav"
            second_sample = root / "second" / "voice.wav"
            first_sample.parent.mkdir()
            second_sample.parent.mkdir()
            first_sample.write_bytes(b"first voice")
            second_sample.write_bytes(b"second voice")

            def converter_for(sample: Path) -> QwenAudiobookConverter:
                converter = QwenAudiobookConverter.__new__(QwenAudiobookConverter)
                converter.voice_mode = "voice_clone"
                converter.voice_clone_ref_audio = str(sample)
                converter.voice_clone_ref_text = "matching transcript"
                converter.voice_clone_use_xvector_only = False
                return converter

            with patch.dict(
                os.environ,
                {"READ_AS_ME_APP_SUPPORT": "", "QWEN_AUDIOBOOK_APP_SUPPORT": ""},
                clear=False,
            ):
                first_cache = converter_for(first_sample).get_cache_path("Narration text")
                second_cache = converter_for(second_sample).get_cache_path("Narration text")

            self.assertNotEqual(first_cache, second_cache)

    def test_clean_text_preserves_spoken_numbers(self) -> None:
        cleaned = self.converter._clean_text("Chapter 7 has 101 reasons.")

        self.assertEqual(cleaned, "Chapter 7 has 101 reasons.")

    def test_clean_text_preserves_paragraph_breaks(self) -> None:
        cleaned = self.converter._clean_text("First line.\ncontinued.\n\nSecond paragraph.")

        self.assertEqual(cleaned, "First line. continued.\n\nSecond paragraph.")

    def test_split_into_chunks_limits_unpunctuated_text(self) -> None:
        text = " ".join("word" for _ in range(CHUNK_SIZE_WORDS * 2 + 5))

        chunks = self.converter.split_into_chunks(text)

        self.assertEqual([len(chunk.split()) for chunk in chunks], [CHUNK_SIZE_WORDS, CHUNK_SIZE_WORDS, 5])
        self.assertTrue(all(len(chunk) <= CHUNK_SIZE_CHARACTERS for chunk in chunks))

    def test_split_into_chunks_never_crosses_paragraphs(self) -> None:
        text = "First paragraph has two sentences. It should remain together.\n\nSecond paragraph."

        chunks = self.converter.split_into_chunks(text)

        self.assertEqual(
            chunks,
            [
                "First paragraph has two sentences. It should remain together.",
                "Second paragraph.",
            ],
        )

    def test_split_into_chunks_limits_long_sentences_by_characters(self) -> None:
        text = " ".join("readable" for _ in range(100))

        chunks = self.converter.split_into_chunks(text)

        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(len(chunk) <= CHUNK_SIZE_CHARACTERS for chunk in chunks))
        self.assertTrue(all(len(chunk.split()) <= CHUNK_SIZE_WORDS for chunk in chunks))

    def test_epub_extraction_reads_document_items(self) -> None:
        item = Mock()
        item.get_type.return_value = __import__("ebooklib").ITEM_DOCUMENT
        item.get_body_content.return_value = b"<p>Readable chapter text.</p>"
        book = Mock()
        book.spine = [("chapter-1", "yes")]
        book.get_item_by_id.return_value = item

        with patch("audiobook_converter.epub.read_epub", return_value=book):
            text = self.converter._extract_epub_ebooklib(Path("book.epub"))

        self.assertEqual(text, "Readable chapter text.")


if __name__ == "__main__":
    unittest.main()
