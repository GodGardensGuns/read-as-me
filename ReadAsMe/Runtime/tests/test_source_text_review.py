import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import source_text_review


class SourceTextReviewTests(unittest.TestCase):
    def test_offsets_use_utf16(self):
        text = "🎧 This is is ready..."
        found = source_text_review.suggestions(text)
        repeated = next(item for item in found if item["kind"] == "repeated_word")
        self.assertEqual(repeated["offset"], 8)
        self.assertEqual(repeated["replacement"], "is")

    def test_punctuation_cleanup_is_suggested(self):
        found = source_text_review.suggestions("Hello  , world!!!")
        replacements = {item["replacement"] for item in found}
        self.assertIn(",", replacements)
        self.assertIn("!", replacements)


if __name__ == "__main__":
    unittest.main()
