#!/usr/bin/env python3
"""Measure sequence patterns in the captured Spotify recommendation runs.

This is deliberately separate from model training.  The Notion pages are
observations of Spotify's recommender, not hand-authored playlists, so we first
measure what Spotify repeatedly does: candidate recurrence, rank stability,
artist-return spacing, and immediate artist repetition.  Training can then use
those measured priors instead of inventing fixed intervals.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict, dataclass
import json
import os
from statistics import mean, median

from radio_teacher import fetch_lines, item_key, normalize, teacher_blocks


def artist_key(raw: str) -> str:
    return normalize(raw)


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
    top_candidates: list[CandidateStat]


def rounded(value: float, digits: int = 3) -> float:
    return round(float(value), digits)


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

        # Candidate recurrence/rank is measured once per captured Spotify run.
        for rank, track in enumerate(recommendations, start=1):
            key = item_key(track.title, track.artist)
            candidate_positions[key].append(rank)
            candidate_meta[key] = (track.title, track.artist)

        sequence = run
        seed_artist = artist_key(seed.artist)
        last_position_by_artist: dict[str, int] = {}
        returned_seed_artist = False
        for position, track in enumerate(sequence):
            current_artist = artist_key(track.artist)
            if position > 0:
                previous_artist = artist_key(sequence[position - 1].artist)
                total_edges += 1
                if current_artist == previous_artist:
                    same_artist_edges += 1
            if current_artist in last_position_by_artist:
                # Number of other records between two appearances of this artist.
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
        key=lambda item: (
            -item.appearance_rate,
            item.mean_rank,
            item.title.lower(),
        )
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
            rounded(mean(all_artist_return_gaps), 2)
            if all_artist_return_gaps
            else None
        ),
        any_artist_return_gap_median=(
            rounded(median(all_artist_return_gaps), 2)
            if all_artist_return_gaps
            else None
        ),
        top_candidates=candidates[:12],
    )


def main() -> None:
    blocks = teacher_blocks(fetch_lines())
    grouped: dict[str, list[list]] = defaultdict(list)
    for block in blocks:
        if len(block) < 2:
            continue
        grouped[item_key(block[0].title, block[0].artist)].append(block)

    reports = [report_for_runs(runs) for runs in grouped.values()]
    reports.sort(key=lambda report: (-report.runs, report.seed_title.lower()))

    repeated = [report for report in reports if report.runs >= 2]
    singletons = [report for report in reports if report.runs == 1]
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
        if report.runs >= 2:
            for item in report.top_candidates[:8]:
                print(
                    "  TOP"
                    f" rate={item.appearance_rate:.3f}"
                    f" meanRank={item.mean_rank:.2f}"
                    f" range={item.best_rank}-{item.worst_rank}"
                    f" | {item.title} — {item.artist}"
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
