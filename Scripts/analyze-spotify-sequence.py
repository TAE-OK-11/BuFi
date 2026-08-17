#!/usr/bin/env python3
"""Measure sequence patterns in captured Spotify recommendation runs.

The Notion pages are observations of Spotify's recommender, not hand-authored
playlists. Measure recurring policy signals first: title recurrence, rank
stability, artist-return spacing, immediate repetition, and the raw ordered
runs. The third teacher page is parsed generically by recognizing a track
heading followed by `세트 1`, so new seed headings do not need to be hard-coded.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
import json
import os
import urllib.request
from statistics import mean, median

from radio_teacher import (
    PAGE_MARKER,
    clean_line,
    fetch_lines,
    is_set_marker,
    item_key,
    normalize,
    parse_line,
    teacher_blocks,
)

EXTRA_PAGES = ["3bff030e-09cf-800b-a225-dbeb5db192b9"]


def artist_key(raw: str) -> str:
    return normalize(raw)


def _fetch_page(page: str, page_index: int) -> list[str]:
    """Fetch one public Notion page using the endpoint used by radio_teacher."""
    url = "https://www.notion.so/api/v3/loadPageChunk"
    lines = [f"{PAGE_MARKER}:{page_index}"]

    def post(payload: dict) -> dict:
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode())

    def plain(prop) -> str:
        if not prop:
            return ""
        return "".join(str(run[0]) for run in prop if isinstance(run, list) and run)

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
        record = blocks.get(block_id, {})
        value = record.get("value", {}).get("value", record.get("value", {})) or {}
        title = plain((value.get("properties") or {}).get("title"))
        for piece in title.splitlines():
            if piece.strip():
                lines.append(piece.strip())
        for child in value.get("content") or []:
            walk(child)

    walk(page)
    return lines


def _mark_generic_seeds(lines: list[str]) -> list[str]:
    """Mark a track heading as a seed when its next set marker is `세트 1`.

    Existing pages use hard-coded seed headings because seed titles can also
    appear as recommendations. For new pages, `track heading -> 세트 1` is a
    stronger structural signal. A recommendation before `세트 2+` is not
    mistaken for a new seed.
    """
    output = list(lines)
    for index, raw in enumerate(lines):
        parsed = parse_line(raw)
        if parsed is None or parsed.explicit_seed:
            continue
        next_set_number: int | None = None
        for later in lines[index + 1 : index + 8]:
            clean = clean_line(later)
            if not clean:
                continue
            if clean.startswith(PAGE_MARKER):
                break
            if is_set_marker(clean):
                digits = "".join(character for character in clean if character.isdigit())
                next_set_number = int(digits) if digits else None
                break
            if parse_line(later) is not None:
                break
        if next_set_number == 1:
            output[index] = "시드: " + clean_line(raw)
    return output


def all_teacher_lines() -> list[str]:
    lines = fetch_lines()
    start_index = 2
    for offset, page in enumerate(EXTRA_PAGES):
        extra = _fetch_page(page, start_index + offset)
        lines.extend(_mark_generic_seeds(extra))
    return lines


@dataclass
class CandidateStat:
    title: str
    artist: str
    appearances: int
    appearance_rate: float
    mean_rank: float
    median_rank: float
    best_rank: int
    worst_rank: int


@dataclass
class SeedReport:
    seed_title: str
    seed_artist: str
    runs: int
    mean_recommendations: float
    unique_artist_ratio: float
    same_artist_adjacent_rate: float
    seed_artist_return_rate: float
    seed_artist_return_gap_mean: float | None
    seed_artist_return_gap_median: float | None
    any_artist_return_gap_mean: float | None
    any_artist_return_gap_median: float | None
    seed_artist_return_gap_histogram: dict[str, int]
    any_artist_return_gap_histogram: dict[str, int]
    top_candidates: list[CandidateStat]


def rounded(value: float, digits: int = 3) -> float:
    return round(float(value), digits)


def _histogram(values: list[int]) -> dict[str, int]:
    return {str(key): value for key, value in sorted(Counter(values).items())}


def report_for_runs(runs: list[list]) -> SeedReport:
    seed = runs[0][0]
    run_count = len(runs)
    candidate_positions: dict[str, list[int]] = defaultdict(list)
    candidate_meta: dict[str, tuple[str, str]] = {}
    unique_artist_ratios: list[float] = []
    same_artist_edges = 0
    total_edges = 0
    seed_return_runs = 0
    seed_return_gaps: list[int] = []
    all_artist_return_gaps: list[int] = []

    for run in runs:
        recommendations = run[1:]
        if recommendations:
            unique_artists = {artist_key(track.artist) for track in recommendations}
            unique_artist_ratios.append(len(unique_artists) / len(recommendations))
        else:
            unique_artist_ratios.append(0.0)

        for rank, track in enumerate(recommendations, start=1):
            key = item_key(track.title, track.artist)
            candidate_positions[key].append(rank)
            candidate_meta[key] = (track.title, track.artist)

        seed_artist = artist_key(seed.artist)
        last_position_by_artist: dict[str, int] = {}
        returned_seed_artist = False
        for position, track in enumerate(run):
            current_artist = artist_key(track.artist)
            if position > 0:
                previous_artist = artist_key(run[position - 1].artist)
                total_edges += 1
                if current_artist == previous_artist:
                    same_artist_edges += 1
            if current_artist in last_position_by_artist:
                gap = max(0, position - last_position_by_artist[current_artist] - 1)
                all_artist_return_gaps.append(gap)
                if current_artist == seed_artist:
                    seed_return_gaps.append(gap)
                    returned_seed_artist = True
            last_position_by_artist[current_artist] = position
        if returned_seed_artist:
            seed_return_runs += 1

    candidates: list[CandidateStat] = []
    for key, positions in candidate_positions.items():
        title, artist = candidate_meta[key]
        candidates.append(
            CandidateStat(
                title=title,
                artist=artist,
                appearances=len(positions),
                appearance_rate=rounded(len(positions) / run_count),
                mean_rank=rounded(mean(positions), 2),
                median_rank=rounded(median(positions), 2),
                best_rank=min(positions),
                worst_rank=max(positions),
            )
        )
    candidates.sort(
        key=lambda item: (-item.appearance_rate, item.mean_rank, item.title.lower())
    )

    return SeedReport(
        seed_title=seed.title,
        seed_artist=seed.artist,
        runs=run_count,
        mean_recommendations=rounded(mean(max(0, len(run) - 1) for run in runs), 2),
        unique_artist_ratio=rounded(mean(unique_artist_ratios)),
        same_artist_adjacent_rate=rounded(
            same_artist_edges / total_edges if total_edges else 0.0
        ),
        seed_artist_return_rate=rounded(seed_return_runs / run_count),
        seed_artist_return_gap_mean=(
            rounded(mean(seed_return_gaps), 2) if seed_return_gaps else None
        ),
        seed_artist_return_gap_median=(
            rounded(median(seed_return_gaps), 2) if seed_return_gaps else None
        ),
        any_artist_return_gap_mean=(
            rounded(mean(all_artist_return_gaps), 2) if all_artist_return_gaps else None
        ),
        any_artist_return_gap_median=(
            rounded(median(all_artist_return_gaps), 2) if all_artist_return_gaps else None
        ),
        seed_artist_return_gap_histogram=_histogram(seed_return_gaps),
        any_artist_return_gap_histogram=_histogram(all_artist_return_gaps),
        top_candidates=candidates[:20],
    )


def main() -> None:
    blocks = teacher_blocks(all_teacher_lines())
    grouped: dict[str, list[list]] = defaultdict(list)
    for block in blocks:
        if len(block) < 2:
            continue
        grouped[item_key(block[0].title, block[0].artist)].append(block)

    reports = [report_for_runs(runs) for runs in grouped.values()]
    reports.sort(key=lambda report: (-report.runs, report.seed_title.lower()))
    repeated = [report for report in reports if report.runs >= 2]
    singletons = [report for report in reports if report.runs == 1]

    raw_runs = [
        {
            "seed": {"title": block[0].title, "artist": block[0].artist},
            "tracks": [
                {"position": index, "title": track.title, "artist": track.artist}
                for index, track in enumerate(block)
            ],
        }
        for block in blocks
        if block
    ]
    payload = {
        "source": "spotify-observation-notion",
        "teacherBlocks": len(blocks),
        "seedCount": len(reports),
        "repeatedSeedCount": len(repeated),
        "singletonSeedCount": len(singletons),
        "reports": [
            {
                **asdict(report),
                "top_candidates": [asdict(item) for item in report.top_candidates],
            }
            for report in reports
        ],
        "raw_runs": raw_runs,
    }

    print(
        "Spotify teacher sequence:"
        f" blocks={len(blocks)} seeds={len(reports)}"
        f" repeated={len(repeated)} singletons={len(singletons)}"
    )
    for report in reports:
        print(
            f"SEED {report.seed_title} — {report.seed_artist} | runs={report.runs}"
            f" meanN={report.mean_recommendations}"
            f" uniqueArtist={report.unique_artist_ratio}"
            f" adjacentSameArtist={report.same_artist_adjacent_rate}"
            f" seedReturnRate={report.seed_artist_return_rate}"
            f" seedReturnGap={report.seed_artist_return_gap_mean}"
            f" anyReturnGap={report.any_artist_return_gap_mean}"
        )

    destination = os.environ.get(
        "BUFI_SPOTIFY_SEQUENCE_REPORT",
        "build/spotify-sequence-report.json",
    )
    os.makedirs(os.path.dirname(destination) or ".", exist_ok=True)
    with open(destination, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
    print("wrote", destination)


if __name__ == "__main__":
    main()
