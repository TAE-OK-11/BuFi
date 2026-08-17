import CoreML
import Foundation

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

guard CommandLine.arguments.count >= 2 else {
    throw SmokeFailure(description: "usage: CoreMLSmokeTest.swift <compiled-model.mlmodelc>")
}

let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuOnly
let model = try MLModel(contentsOf: modelURL, configuration: configuration)

guard let inputDescription = model.modelDescription.inputDescriptionsByName["features"],
      let constraint = inputDescription.multiArrayConstraint else {
    throw SmokeFailure(description: "missing MLMultiArray input named features")
}

let shape = constraint.shape
let count = shape.reduce(1) { partial, item in
    partial * item.intValue
}
guard count == 24 else {
    throw SmokeFailure(description: "unexpected feature count: \(count), shape=\(shape)")
}

var lastScore = 0.0
let iterations = 512
for iteration in 0..<iterations {
    let features = try MLMultiArray(shape: shape, dataType: constraint.dataType)
    for index in 0..<features.count {
        let phase = Double((iteration + index) % 31) / 30.0
        features[index] = NSNumber(value: phase)
    }

    let input = try MLDictionaryFeatureProvider(dictionary: ["features": features])
    let output = try model.prediction(from: input)
    guard let score = output.featureValue(for: "score") else {
        throw SmokeFailure(
            description: "prediction completed without score output; outputs=\(output.featureNames)"
        )
    }

    let value: Double
    if let array = score.multiArrayValue, array.count > 0 {
        value = array[0].doubleValue
    } else if score.type == .double {
        value = score.doubleValue
    } else {
        throw SmokeFailure(description: "unexpected score type: \(score.type.rawValue)")
    }
    guard value.isFinite else {
        throw SmokeFailure(description: "non-finite score at iteration \(iteration)")
    }
    lastScore = value
}

print(
    "CoreML smoke test OK: cpuOnly iterations=\(iterations) "
        + "inputShape=\(shape) dataType=\(constraint.dataType.rawValue) "
        + "lastScore=\(lastScore)"
)
