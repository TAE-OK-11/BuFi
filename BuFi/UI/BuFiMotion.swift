import SwiftUI

enum BuFiMotion {
    static let tap = Animation.interactiveSpring(
        response: 0.26,
        dampingFraction: 0.78,
        blendDuration: 0.04
    )
    static let player = Animation.interactiveSpring(
        response: 0.36,
        dampingFraction: 0.82,
        blendDuration: 0.06
    )
    static let page = Animation.interactiveSpring(
        response: 0.34,
        dampingFraction: 0.86,
        blendDuration: 0.05
    )
    static let fade = Animation.interactiveSpring(
        response: 0.30,
        dampingFraction: 0.90,
        blendDuration: 0.04
    )
    static let text = Animation.interactiveSpring(
        response: 0.34,
        dampingFraction: 0.86,
        blendDuration: 0.05
    )
    static let color = Animation.easeInOut(duration: 0.34)
    static let lyrics = Animation.interactiveSpring(
        response: 0.40,
        dampingFraction: 0.80,
        blendDuration: 0.06
    )
}
