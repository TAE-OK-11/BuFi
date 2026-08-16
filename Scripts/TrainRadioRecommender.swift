#!/usr/bin/env swift
import CreateML
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    die("usage: TrainRadioRecommender.swift <csv> <out.mlmodel>")
}

let csv = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
guard FileManager.default.isReadableFile(atPath: csv.path) else {
    die("missing csv: \(csv.path)")
}

do {
    let table = try MLDataTable(contentsOf: csv)
    let recommender: MLRecommender
    if let configured = try? MLRecommender(
        trainingData: table,
        userColumn: "user",
        itemColumn: "item",
        ratingColumn: "rating",
        parameters: MLRecommender.ModelParameters(
            algorithm: .itemSimilarity(.jaccard)
        )
    ) {
        recommender = configured
    } else {
        recommender = try MLRecommender(
            trainingData: table,
            userColumn: "user",
            itemColumn: "item",
            ratingColumn: "rating"
        )
    }
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
    }
    try recommender.write(to: output)
    print("wrote \(output.path)")
} catch {
    die("train failed: \(error)")
}
