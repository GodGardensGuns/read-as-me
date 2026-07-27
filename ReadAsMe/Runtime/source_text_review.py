#!/usr/bin/env python3
"""Lightweight source-text review used before audiobook generation."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def extract_text(path: Path) -> str:
    if not path.is_file():
        raise ValueError(f"source text was not found: {path}")
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
    raise ValueError(f"unsupported source-text format: {suffix}")


def suggestions(text: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []

    def utf16_range(start: int, end: int) -> tuple[int, int]:
        location = len(text[:start].encode("utf-16-le")) // 2
        length = len(text[start:end].encode("utf-16-le")) // 2
        return location, length

    for index, match in enumerate(re.finditer(r"\b([\w’'-]+)(\s+)\1\b", text, flags=re.IGNORECASE)):
        location, length = utf16_range(match.start(), match.end())
        results.append(
            {
                "id": f"repeated-{index}-{location}",
                "kind": "repeated_word",
                "offset": location,
                "length": length,
                "original": match.group(0),
                "replacement": match.group(1),
                "message": f"“{match.group(1)}” appears twice in a row.",
                "accepted": False,
            }
        )
    patterns = [
        (r"([!?.,])\1{2,}", r"\1", "Repeated punctuation"),
        (r"\s+([,.;:!?])", r"\1", "Space before punctuation"),
    ]
    sequence = len(results)
    for pattern, replacement, message in patterns:
        for index, match in enumerate(re.finditer(pattern, text)):
            location, length = utf16_range(match.start(), match.end())
            results.append(
                {
                    "id": f"punctuation-{sequence + index}-{location}",
                    "kind": "punctuation",
                    "offset": location,
                    "length": length,
                    "original": match.group(0),
                    "replacement": re.sub(pattern, replacement, match.group(0)),
                    "message": message,
                    "accepted": False,
                }
            )
        sequence = len(results)
    return results


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Review audiobook source text")
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        text = extract_text(args.source)
        found = suggestions(text)
        write_json(
            args.output,
            {
                "schema_version": 1,
                "source": str(args.source),
                "text": text,
                "suggestions": found,
            },
        )
        print(
            json.dumps(
                {
                    "event": "complete",
                    "message": f"{len(found)} source text suggestions",
                    "output": str(args.output),
                }
            ),
            flush=True,
        )
    except Exception as error:
        print(json.dumps({"event": "error", "message": str(error)}), flush=True)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
