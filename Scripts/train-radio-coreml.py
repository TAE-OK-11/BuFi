#!/usr/bin/env python3
"""Fit a linear Core ML ranker from feel grammar plus structured teacher radios."""

from __future__ import annotations

import os

import coremltools as ct
import numpy as np

from radio_teacher import fetch_lines as fetch_teacher_lines
from radio_teacher import normalize as _norm
from radio_teacher import teacher_blocks

FEELS = [
    "sparkle",
    "rush",
    "bittersweet",
    "cool",
    "electro",
    "glow",
    "hush",
]

PAIR_NAMES = [
    "energy_gap",
    "valence_gap",
    "bpm_gap",
    "intimacy_gap",
    "kpop_same",
    "feel_same",
    "starred",
    "plays",
    "seed_energy",
    "cand_energy",
] + [f"seed_feel_{name}" for name in FEELS] + [f"cand_feel_{name}" for name in FEELS]

NEXT = {
    ("sparkle", "sparkle"): 0.78,
    ("sparkle", "rush"): 0.86,
    ("rush", "sparkle"): 0.86,
    ("sparkle", "bittersweet"): 0.80,
    ("bittersweet", "sparkle"): 0.80,
    ("sparkle", "glow"): 0.58,
    ("glow", "sparkle"): 0.58,
    ("rush", "rush"): 0.78,
    ("rush", "cool"): 0.64,
    ("cool", "rush"): 0.64,
    ("rush", "electro"): 0.70,
    ("electro", "rush"): 0.70,
    ("bittersweet", "bittersweet"): 0.78,
    ("bittersweet", "glow"): 0.80,
    ("glow", "bittersweet"): 0.80,
    ("bittersweet", "hush"): 0.82,
    ("hush", "bittersweet"): 0.82,
    ("cool", "cool"): 0.78,
    ("cool", "electro"): 0.88,
    ("electro", "cool"): 0.88,
    ("cool", "bittersweet"): 0.60,
    ("bittersweet", "cool"): 0.60,
    ("glow", "glow"): 0.78,
    ("glow", "hush"): 0.76,
    ("hush", "glow"): 0.76,
    ("hush", "hush"): 0.78,
    ("sparkle", "cool"): 0.42,
    ("cool", "sparkle"): 0.42,
    ("sparkle", "electro"): 0.28,
    ("electro", "sparkle"): 0.28,
    ("hush", "rush"): 0.12,
    ("rush", "hush"): 0.12,
    ("hush", "electro"): 0.08,
    ("electro", "hush"): 0.08,
    ("glow", "electro"): 0.34,
    ("electro", "glow"): 0.34,
    ("electro", "electro"): 0.78,
}

ROOM = {
    "sparkle": (0.58, 0.68, 0.58, 0.0),
    "rush": (0.78, 0.62, 0.66, 0.4),
    "bittersweet": (0.42, 0.32, 0.48, 0.2),
    "cool": (0.62, 0.48, 0.58, 1.0),
    "electro": (0.80, 0.50, 0.70, 1.0),
    "glow": (0.38, 0.50, 0.68, 0.3),
    "hush": (0.22, 0.28, 0.82, 0.1),
}


def next_score(a: str, b: str) -> float:
    if a == b:
        return NEXT.get((a, b), 0.78)
    return NEXT.get((a, b), 0.36)


def one_hot(feel: str) -> list[float]:
    return [1.0 if feel == name else 0.0 for name in FEELS]


def row(seed: str, cand: str, rng: np.random.Generator) -> tuple[list[float], float]:
    se, sv, si, sk = ROOM[seed]
    ce, cv, ci, ck = ROOM[cand]
    se = float(np.clip(se + rng.normal(0, 0.05), 0, 1))
    ce = float(np.clip(ce + rng.normal(0, 0.05), 0, 1))
    sv = float(np.clip(sv + rng.normal(0, 0.05), 0, 1))
    cv = float(np.clip(cv + rng.normal(0, 0.05), 0, 1))
    sb = float(np.clip(0.4 + se * 0.4 + rng.normal(0, 0.04), 0, 1))
    cb = float(np.clip(0.4 + ce * 0.4 + rng.normal(0, 0.04), 0, 1))
    kpop_same = 1.0 if abs(sk - ck) < 0.5 else 0.0
    features = [
        abs(se - ce),
        abs(sv - cv),
        abs(sb - cb),
        abs(si - ci),
        kpop_same,
        1.0 if seed == cand else 0.0,
        float(rng.random() < 0.15),
        float(rng.random() * 0.4),
        se,
        ce,
    ] + one_hot(seed) + one_hot(cand)
    label = next_score(seed, cand)
    label += (1.0 - abs(se - ce)) * 0.10
    if kpop_same:
        label += 0.12
        if seed in {"sparkle", "rush"} and cand in {"cool", "electro"}:
            label -= 0.18
        if seed in {"cool", "electro"} and cand in {"sparkle"}:
            label -= 0.16
    else:
        label -= 0.14
    label = float(np.clip(label, 0, 1))
    return features, label


def is_kpop(track: dict) -> bool:
    if track.get("kpop"):
        return True
    genre = str(track.get("genre") or "").lower()
    return "k-pop" in genre or "kpop" in genre or "idol" in genre


def pair_from_tracks(seed: dict, cand: dict) -> tuple[list[float], float]:
    sf = seed.get("features") or {}
    cf = cand.get("features") or {}
    se = float(sf.get("energy") or seed.get("energy") or 0.5)
    ce = float(cf.get("energy") or cand.get("energy") or 0.5)
    sv = float(sf.get("valence") or seed.get("valence") or 0.5)
    cv = float(cf.get("valence") or cand.get("valence") or 0.5)
    sb = float(sf.get("bpm") or 0)
    cb = float(cf.get("bpm") or 0)
    si = float(sf.get("intimacy") or seed.get("intimacy") or 0.5)
    ci = float(cf.get("intimacy") or cand.get("intimacy") or 0.5)
    seed_feel = str(seed.get("feel") or "glow")
    cand_feel = str(cand.get("feel") or "glow")
    if seed_feel not in FEELS:
        seed_feel = "glow"
    if cand_feel not in FEELS:
        cand_feel = "glow"
    kpop_same = 1.0 if is_kpop(seed) == is_kpop(cand) else 0.0
    features = [
        abs(se - ce),
        abs(sv - cv),
        abs(sb - cb),
        abs(si - ci),
        kpop_same,
        1.0 if seed_feel == cand_feel else 0.0,
        1.0 if cand.get("starred") else 0.0,
        float(cf.get("plays") or 0),
        se,
        ce,
    ] + one_hot(seed_feel) + one_hot(cand_feel)
    label = next_score(seed_feel, cand_feel)
    label += (1.0 - abs(se - ce)) * 0.10
    label += max(0.0, 0.08 - abs(sb - cb) * 0.2)
    # Artist identity is deliberately not a numeric shortcut. Teacher radios
    # contain useful same-artist anchors, but the model should learn their
    # audio/feel shape rather than a generic same-artist bonus.
    if kpop_same:
        label += 0.12
        if seed_feel in {"sparkle", "rush"} and cand_feel in {"cool", "electro"}:
            label -= 0.14
    else:
        label -= 0.12
    return features, float(np.clip(label, 0, 1))


def _resolve(title: str, artist: str, index: dict) -> dict | None:
    exact = _norm(title) + _norm(artist)
    if exact in index:
        return index[exact][0]
    title_key = _norm(title)
    if title_key in index:
        return index[title_key][0]
    if len(title_key) > 4:
        for stored, tracks in index.items():
            if title_key in stored or stored in title_key:
                return tracks[0]
    return None


def load_notion_pairs(
    scan_path: str, rng: np.random.Generator
) -> tuple[list[list[float]], list[float]]:
    import json
    from collections import defaultdict

    tracks = json.loads(open(scan_path, encoding="utf-8").read()).get("tracks", [])
    index: dict[str, list[dict]] = defaultdict(list)
    for track in tracks:
        title_key = _norm(track.get("title", ""))
        index[title_key].append(track)
        index[title_key + _norm(track.get("artist", ""))].append(track)

    try:
        teacher = teacher_blocks(fetch_teacher_lines())
    except Exception as error:
        print("notion fetch failed", error)
        return [], []

    xs: list[list[float]] = []
    ys: list[float] = []
    resolved_blocks: list[list[dict]] = []
    for block in teacher:
        resolved: list[dict] = []
        seen: set[str] = set()
        for item in block:
            track = _resolve(item.title, item.artist, index)
            if track is None:
                continue
            track_id = str(track.get("id") or "")
            if not track_id or track_id in seen:
                continue
            seen.add(track_id)
            resolved.append(track)
        if len(resolved) >= 3:
            resolved_blocks.append(resolved)

    for block in resolved_blocks:
        seed = block[0]
        positives = {track.get("id") for track in block[1:]}

        # Seed-to-ranked-candidate teacher labels. Repeat strong observations so
        # they can meaningfully calibrate the larger synthetic grammar corpus.
        for rank, track in enumerate(block[1:]):
            features, _ = pair_from_tracks(seed, track)
            label = max(0.68, 0.99 - rank * 0.014)
            repeats = 3 if rank < 8 else 2
            for _ in range(repeats):
                xs.append(features)
                ys.append(label)

        # Consecutive teacher order is stronger than simple co-membership.
        for index_a in range(len(block) - 1):
            features, _ = pair_from_tracks(block[index_a], block[index_a + 1])
            label = 0.96 if index_a < 3 else 0.92
            xs.extend([features, features])
            ys.extend([label, label])

        # A one-track skip captures smooth local arcs without pretending every
        # distant track in a long screenshot run is an immediate transition.
        for index_a in range(len(block) - 2):
            features, _ = pair_from_tracks(block[index_a], block[index_a + 2])
            xs.append(features)
            ys.append(0.84)

        others = [
            track
            for track in tracks
            if track.get("id") not in positives | {seed.get("id")}
        ]
        if others:
            picks = rng.choice(len(others), size=min(8, len(others)), replace=False)
            for pick in picks:
                features, grammar = pair_from_tracks(seed, others[int(pick)])
                xs.append(features)
                ys.append(min(grammar, 0.28))

    print("notion matched pairs", len(xs), "blocks", len(resolved_blocks))
    return xs, ys


def load_scan_pairs(path: str, rng: np.random.Generator) -> tuple[list[list[float]], list[float]]:
    import json

    data = json.loads(open(path, encoding="utf-8").read())
    tracks = [t for t in data.get("tracks", []) if isinstance(t, dict)]
    xs: list[list[float]] = []
    ys: list[float] = []
    if len(tracks) < 2:
        return xs, ys
    for seed in tracks:
        picks = rng.choice(len(tracks), size=min(8, len(tracks)), replace=False)
        for index in picks:
            cand = tracks[int(index)]
            if cand.get("id") == seed.get("id"):
                continue
            features, label = pair_from_tracks(seed, cand)
            xs.append(features)
            ys.append(label)
    return xs, ys


def main() -> None:
    rng = np.random.default_rng(11)
    xs: list[list[float]] = []
    ys: list[float] = []
    for seed in FEELS:
        for cand in FEELS:
            copies = 36 if seed == cand or (seed, cand) in NEXT else 8
            if (seed, cand) in {
                ("sparkle", "bittersweet"),
                ("bittersweet", "sparkle"),
                ("sparkle", "rush"),
                ("rush", "sparkle"),
                ("cool", "electro"),
                ("electro", "cool"),
            }:
                copies += 16
            for _ in range(copies):
                features, label = row(seed, cand, rng)
                xs.append(features)
                ys.append(label)

    scan = os.environ.get("BUFI_SCAN_EXPORT", "/root/텍스트.txt")
    if os.path.isfile(scan):
        extra_x, extra_y = load_scan_pairs(scan, rng)
        xs.extend(extra_x)
        ys.extend(extra_y)
        print("loaded scan pairs", len(extra_x), "from", scan)
        notion_x, notion_y = load_notion_pairs(scan, rng)
        xs.extend(notion_x)
        ys.extend(notion_y)
        print("loaded notion pairs", len(notion_x))

    x = np.asarray(xs, dtype=np.float32)
    y = np.asarray(ys, dtype=np.float32)
    ones = np.ones((x.shape[0], 1), dtype=np.float32)
    fitted, _, _, _ = np.linalg.lstsq(np.hstack([x, ones]), y, rcond=None)
    weights = fitted[:-1].astype(np.float32)
    bias = float(fitted[-1])

    builder = ct.models.neural_network.NeuralNetworkBuilder(
        input_features=[("features", ct.models.datatypes.Array(len(PAIR_NAMES)))],
        output_features=[("score", ct.models.datatypes.Array(1))],
        mode="regressor",
    )
    builder.add_inner_product(
        name="rank",
        input_name="features",
        output_name="score",
        input_channels=len(PAIR_NAMES),
        output_channels=1,
        W=weights,
        b=np.array([bias], dtype=np.float32),
        has_bias=True,
    )
    spec = builder.spec
    spec.description.predictedFeatureName = "score"
    spec.description.metadata.shortDescription = (
        "BuFi radio 50-to-30 ranker trained on feel grammar and structured teacher radios"
    )
    model = ct.models.MLModel(spec)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = os.path.join(root, "BuFi", "Resources", "BuFiRadioTransition.mlmodel")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    model.save(dest)
    print("wrote", dest, "n=", x.shape[0], "bias=", round(bias, 4))


if __name__ == "__main__":
    main()
