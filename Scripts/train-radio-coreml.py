#!/usr/bin/env python3
"""Fit a linear Core ML ranker from the feel-placement grammar."""

from __future__ import annotations

import os

import coremltools as ct
import numpy as np

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
        "BuFi radio 50-to-30 ranker trained on feel-placement data"
    )
    model = ct.models.MLModel(spec)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = os.path.join(root, "BuFi", "Resources", "BuFiRadioTransition.mlmodel")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    model.save(dest)
    print("wrote", dest, "n=", x.shape[0], "bias=", round(bias, 4))


if __name__ == "__main__":
    main()
