import CoreML
import Foundation

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

guard CommandLine.arguments.count >= 2 else {
    throw SmokeFailure(description: "usage: CoreMLSmokeTest.swift <compiled-model.mlmodelc>")
}

let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let model = try MLModel(contentsOf: modelURL)

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

let features = try MLMultiArray(shape: shape, dataType: constraint.dataType)
for index in 0..<features.count {
    features[index] = NSNumber(value: Double(index) / Double(max(features.count - 1, 1)))
}

let input = try MLDictionaryFeatureProvider(dictionary: ["features": features])
let output = try model.prediction(from: input)
guard let score = output.featureValue(for: "score") else {
    throw SmokeFailure(description: "prediction completed without score output; outputs=\(output.featureNames)")
}

if let array = score.multiArrayValue, array.count > 0 {
    print("CoreML smoke test OK: inputShape=\(shape) dataType=\(constraint.dataType.rawValue) score=\(array[0].doubleValue)")
} else if score.type == .double {
    print("CoreML smoke test OK: inputShape=\(shape) dataType=\(constraint.dataType.rawValue) score=\(score.doubleValue)")
} else {
    throw SmokeFailure(description: "unexpected score type: \(score.type.rawValue)")
}
