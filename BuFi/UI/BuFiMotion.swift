import SwiftUI

enum BuFiMotion {
    static let tap = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.06)
    static let player = Animation.interactiveSpring(response: 0.44, dampingFraction: 0.89, blendDuration: 0.08)
    static let page = Animation.easeOut(duration: 0.20)
    static let fade = Animation.easeOut(duration: 0.24)
    static let text = Animation.easeInOut(duration: 0.32)
    static let color = Animation.easeInOut(duration: 0.38)
    static let lyrics = Animation.easeOut(duration: 0.36)
}
