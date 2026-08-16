#!/usr/bin/env python3
"""Export Notion radio lists as Create ML MLRecommender CSV."""

from __future__ import annotations

import csv
import json
import os
import re
import unicodedata
import urllib.request

PAGES = [
    "3bef030e-09cf-8010-a650-f4b906e8e91f",
    "3bef030e-09cf-8004-968b-e79de61a4528",
]


def normalize(text: str) -> str:
    value = unicodedata.normalize("NFKC", text or "").lower()
    value = re.sub(r"\(.*?\)", "", value)
    return re.sub(r"[^0-9a-z가-힣]+", "", value)


def item_key(title: str, artist: str) -> str:
    return f"{normalize(title)}|{normalize(artist.split('(')[0])}"


def parse_line(line: str) -> tuple[str, str] | None:
    text = re.sub(r"^\d+\.\s*", "", line.replace("\u2060", "").strip())
    text = re.sub(r"^시드:\s*", "", text)
    if not text or text.startswith("세트") or "스크린샷" in text:
        return None
    if " - " not in text:
        return None
    title, artist = text.rsplit(" - ", 1)
    title, artist = title.strip(), artist.strip()
    if not title or not artist:
        return None
    return title, artist


def fetch_lines() -> list[str]:
    url = "https://www.notion.so/api/v3/loadPageChunk"
    lines: list[str] = []

    def post(payload):
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())

    def plain(prop):
        if not prop:
            return ""
        return "".join(str(run[0]) for run in prop if isinstance(run, list) and run)

    for page in PAGES:
        blocks = {}
        cursor = []
        chunk = 0
        while True:
            data = post(
                {
                    "page": {"id": page},
                    "limit": 100,
                    "cursor": {"stack": cursor},
                    "chunkNumber": chunk,
                    "verticalColumns": False,
                }
            )
            blocks.update(data.get("recordMap", {}).get("block", {}))
            cursor = data.get("cursor", {}).get("stack", [])
            chunk += 1
            if not cursor or chunk > 60:
                break

        def walk(block_id: str) -> None:
            rec = blocks.get(block_id, {})
            value = rec.get("value", {}).get("value", rec.get("value", {})) or {}
            title = plain((value.get("properties") or {}).get("title"))
            for piece in title.splitlines():
                if piece.strip():
                    lines.append(piece.strip())
            for child in value.get("content") or []:
                walk(child)

        walk(page)
    return lines


def blocks_from_lines(lines: list[str]) -> list[list[tuple[str, str]]]:
    parsed = [item for item in (parse_line(line) for line in lines) if item]
    blocks: list[list[tuple[str, str]]] = []
    current: list[tuple[str, str]] = []
    seed_titles = {
        "style",
        "karma",
        "cruel summer",
        "so high school",
        "anti-hero",
        "the one that got away",
        "dance the night away",
        "ode to love",
        "hey! hey!",
        "blue valentine",
        "lemonade",
        "love attack",
        "갑자기",
    }
    for title, artist in parsed:
        if current and title.lower().strip() in seed_titles and len(current) >= 6:
            blocks.append(current)
            current = [(title, artist)]
        else:
            current.append((title, artist))
    if len(current) >= 3:
        blocks.append(current)
    return blocks


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = os.path.join(root, "Scripts", "radio-recommender.csv")
    try:
        lines = fetch_lines()
    except Exception as error:
        print("notion fetch failed", error)
        lines = []
    blocks = blocks_from_lines(lines)
    rows: list[tuple[str, str, float]] = []
    for index, block in enumerate(blocks):
        user = f"radio-{index}"
        seen = set()
        for rank, (title, artist) in enumerate(block):
            key = item_key(title, artist)
            if not key or key == "|" or key in seen:
                continue
            seen.add(key)
            rating = max(1.0, 6.0 - rank * 0.08)
            rows.append((user, key, rating))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["user", "item", "rating"])
        writer.writerows(rows)
    print("wrote", dest, "rows", len(rows), "blocks", len(blocks))


if __name__ == "__main__":
    main()
