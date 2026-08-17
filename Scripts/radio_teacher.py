#!/usr/bin/env python3
"""Shared parser for the two Notion radio-teacher pages.

The source pages mix explicit seeds, repeated `세트 N` groups, long ranked
recommendation runs, and screenshot-derived `첫 번째 재생 곡` headings.  Keep
those boundaries intact so Create ML sees independent radio sessions instead
of one giant popularity list.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import re
import unicodedata
import urllib.request

PAGES = [
    "3bef030e-09cf-8010-a650-f4b906e8e91f",
    "3bef030e-09cf-8004-968b-e79de61a4528",
]

# Only titles that are explicitly seeds/headings in the teacher material.
# Numbered recommendation rows must not accidentally start a new block.
SEED_TITLES = {
    "style",
    "cruel summer",
    "karma",
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

SET_RE = re.compile(r"^세트\s*\d+\s*$", re.IGNORECASE)
PLAYBACK_RE = re.compile(
    r"(?:첫\s*번째|두\s*번째|세\s*번째)\s*재생\s*곡\s*:\s*"
    r"['‘’\"]?(.+?)['‘’\"]?\s*\((.+?)\)\s*$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class TeacherTrack:
    title: str
    artist: str


@dataclass(frozen=True)
class ParsedLine:
    track: TeacherTrack
    is_seed: bool


def normalize(text: str) -> str:
    value = unicodedata.normalize("NFKC", text or "").lower()
    value = re.sub(r"\(.*?\)", "", value)
    return re.sub(r"[^0-9a-z가-힣]+", "", value)


def item_key(title: str, artist: str) -> str:
    # Keep this identical to RadioCoreMLTransition.normalize: parenthetical
    # text is removed but every non-parenthetical artist token is retained.
    return f"{normalize(title)}|{normalize(artist)}"


def clean_line(raw: str) -> str:
    text = (raw or "").replace("\u2060", "").strip()
    text = text.replace("<br>", "").replace("<br/>", "")
    text = text.replace("\\[", "").replace("\\]", "")
    text = text.replace("**", "")
    text = re.sub(r"^[-•]\s*", "", text)
    return re.sub(r"\s+", " ", text).strip()


def is_set_marker(raw: str) -> bool:
    return SET_RE.match(clean_line(raw)) is not None


def parse_line(raw: str) -> ParsedLine | None:
    text = clean_line(raw)
    if not text or is_set_marker(text):
        return None
    if any(
        marker in text
        for marker in (
            "스크린샷",
            "전체 목록",
            "복사하여",
            "화면 흐름",
            "서브 그룹",
            "맨 처음 올려",
        )
    ):
        return None

    playback = PLAYBACK_RE.search(text)
    if playback:
        return ParsedLine(
            TeacherTrack(playback.group(1).strip(), playback.group(2).strip()),
            True,
        )

    explicit_seed = "시드:" in text
    text = re.sub(r"^\d+\.\s*", "", text).strip()
    text = re.sub(r"^시드\s*:\s*", "", text, flags=re.IGNORECASE).strip()

    recommendation_heading = "추천 트랙" in text
    if recommendation_heading:
        text = re.sub(r"\s*추천 트랙.*$", "", text).strip()

    if " - " not in text:
        return None
    title, artist = text.rsplit(" - ", 1)
    title = title.strip(" \t'‘’\"")
    artist = artist.strip(" \t'‘’\"")
    if not title or not artist:
        return None

    is_seed = explicit_seed or recommendation_heading or normalize(title) in {
        normalize(value) for value in SEED_TITLES
    }
    return ParsedLine(TeacherTrack(title, artist), is_seed)


def teacher_blocks(lines: list[str]) -> list[list[TeacherTrack]]:
    blocks: list[list[TeacherTrack]] = []
    seed: TeacherTrack | None = None
    current: list[TeacherTrack] = []

    def flush() -> None:
        nonlocal current
        if seed is not None and len(current) >= 3:
            # Preserve order but remove exact repeated recordings inside a set.
            unique: list[TeacherTrack] = []
            seen: set[str] = set()
            for track in current:
                key = item_key(track.title, track.artist)
                if key in seen:
                    continue
                seen.add(key)
                unique.append(track)
            if len(unique) >= 3:
                blocks.append(unique)
        current = []

    for raw in lines:
        if is_set_marker(raw):
            flush()
            if seed is not None:
                current = [seed]
            continue

        parsed = parse_line(raw)
        if parsed is None:
            continue
        if parsed.is_seed:
            flush()
            seed = parsed.track
            current = [seed]
            continue
        if seed is not None:
            current.append(parsed.track)

    flush()
    return blocks


def fetch_lines() -> list[str]:
    """Read both public Notion pages using the same endpoint as the old exporter."""
    url = "https://www.notion.so/api/v3/loadPageChunk"
    lines: list[str] = []

    def post(payload: dict) -> dict:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())

    def plain(prop) -> str:
        if not prop:
            return ""
        return "".join(str(run[0]) for run in prop if isinstance(run, list) and run)

    for page in PAGES:
        blocks: dict = {}
        cursor: list = []
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
