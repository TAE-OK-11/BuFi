#!/usr/bin/env python3
"""Export the two Notion recommendation pages as balanced Create ML sessions.

The teacher pages are not simple playlists: one seed may have several
independent recommendation sets and long screenshot-derived radio runs. We
preserve those boundaries, then create small pseudo-sessions so the Jaccard
item recommender learns local handoffs instead of raw popularity. Long blocks
are sampled across their full span with a per-block cap so page length does not
turn into an accidental preference weight.
"""

from __future__ import annotations

import csv
import os

from radio_teacher import TeacherTrack, fetch_lines, item_key, teacher_blocks


def unique_tracks(block: list[TeacherTrack]) -> list[TeacherTrack]:
    result: list[TeacherTrack] = []
    seen: set[str] = set()
    for track in block:
        key = item_key(track.title, track.artist)
        if not key or key == "|" or key in seen:
            continue
        seen.add(key)
        result.append(track)
    return result


def spaced_starts(starts: list[int], limit: int) -> list[int]:
    """Keep deterministic positions spread over the whole teacher run."""
    if limit <= 0 or not starts:
        return []
    if len(starts) <= limit:
        return starts
    if limit == 1:
        return [starts[0]]
    picked: list[int] = []
    last_index = len(starts) - 1
    for slot in range(limit):
        index = round(slot * last_index / (limit - 1))
        value = starts[index]
        if not picked or picked[-1] != value:
            picked.append(value)
    return picked


def add_session(
    rows: list[tuple[str, str, float]],
    user: str,
    tracks: list[TeacherTrack],
    seed_key: str | None = None,
) -> None:
    seen: set[str] = set()
    for rank, track in enumerate(tracks):
        key = item_key(track.title, track.artist)
        if key in seen:
            continue
        seen.add(key)
        if seed_key is not None and key == seed_key:
            rating = 6.0
        else:
            # Jaccard mostly learns co-occurrence, but keep rank information for
            # fallback/default MLRecommender implementations.
            rating = max(3.4, 5.7 - rank * 0.16)
        rows.append((user, key, rating))


def rows_from_blocks(blocks: list[list[TeacherTrack]]) -> list[tuple[str, str, float]]:
    rows: list[tuple[str, str, float]] = []
    direct_seen: set[tuple[str, str]] = set()

    for block_index, raw_block in enumerate(blocks):
        block = unique_tracks(raw_block)
        if len(block) < 3:
            continue
        seed = block[0]
        seed_key = item_key(seed.title, seed.artist)
        recommendations = block[1:]

        # 1) Seed-centred rooms. Sample at most five chunks across the entire
        # run so a 100-track screenshot does not outweigh a concise 8-track set.
        room_starts = spaced_starts(
            list(range(0, len(recommendations), 10)),
            limit=5,
        )
        for chunk_index, start in enumerate(room_starts):
            chunk = recommendations[start : start + 12]
            if len(chunk) < 2:
                continue
            add_session(
                rows,
                f"teacher-{block_index}-room-{chunk_index}",
                [seed] + chunk,
                seed_key=seed_key,
            )

        # 2) Strong opening: the first recommendations receive their own small
        # context instead of being diluted by a long radio run.
        opening = [seed] + recommendations[:8]
        if len(opening) >= 3:
            add_session(
                rows,
                f"teacher-{block_index}-opening",
                opening,
                seed_key=seed_key,
            )

        # 3) Sliding local windows teach actual handoffs. Long runs get at most
        # twelve windows chosen across the full sequence, retaining late-run
        # evidence without giving them 5x the statistical weight.
        sequence = [seed] + recommendations
        flow_starts = spaced_starts(
            list(range(0, max(1, len(sequence) - 2), 2)),
            limit=12,
        )
        for window_index, start in enumerate(flow_starts):
            window = sequence[start : start + 6]
            if len(window) < 3:
                continue
            add_session(
                rows,
                f"teacher-{block_index}-flow-{window_index}",
                window,
                seed_key=seed_key if start == 0 else None,
            )

        # 4) Direct seed↔candidate evidence for the top cross-artist choices.
        # Same-artist pairs are intentionally not amplified: the teacher data
        # may contain them, but identity must not become a shortcut.
        seed_artist = seed.artist.casefold()
        for rank, candidate in enumerate(recommendations[:8]):
            if candidate.artist.casefold() == seed_artist:
                continue
            candidate_key = item_key(candidate.title, candidate.artist)
            pair = (seed_key, candidate_key)
            if pair in direct_seen:
                continue
            direct_seen.add(pair)
            context = [seed, candidate]
            if rank + 1 < len(recommendations):
                context.append(recommendations[rank + 1])
            add_session(
                rows,
                f"teacher-{block_index}-pair-{rank}",
                context,
                seed_key=seed_key,
            )

    return rows


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = os.path.join(root, "Scripts", "radio-recommender.csv")

    try:
        lines = fetch_lines()
        blocks = teacher_blocks(lines)
    except Exception as error:
        print("notion fetch failed", error)
        blocks = []

    if not blocks:
        # Do not destroy the committed teacher snapshot when Notion is
        # temporarily unavailable. CI can still train from the last export.
        if os.path.isfile(dest) and os.path.getsize(dest) > 32:
            print("no live teacher blocks; keeping", dest)
            return
        raise SystemExit("no Notion teacher data and no fallback CSV")

    rows = rows_from_blocks(blocks)
    if len(rows) < 40:
        raise SystemExit(f"teacher export unexpectedly small: {len(rows)} rows")

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["user", "item", "rating"])
        writer.writerows(rows)

    seeds = len({item_key(block[0].title, block[0].artist) for block in blocks if block})
    print(
        "wrote",
        dest,
        "rows",
        len(rows),
        "teacher blocks",
        len(blocks),
        "seeds",
        seeds,
    )


if __name__ == "__main__":
    main()
