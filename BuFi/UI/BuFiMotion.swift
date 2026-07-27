import SwiftUI

enum BuFiMotion {
    // Motion is intentionally quantized in 0.05-second steps so related
    // transitions feel consistent instead of each view inventing a spring.
    static let micro = Animation.easeOut(duration: 0.10)
    static let tap = Animation.spring(duration: 0.20, bounce: 0.18)
    static let selection = Animation.spring(duration: 0.25, bounce: 0.12)
    static let fade = Animation.easeInOut(duration: 0.25)
    static let text = Animation.spring(duration: 0.30, bounce: 0.08)
    static let color = Animation.easeInOut(duration: 0.35)
    static let page = Animation.spring(duration: 0.40, bounce: 0.10)
    static let player = Animation.spring(duration: 0.45, bounce: 0.12)
    static let lyrics = Animation.spring(duration: 0.50, bounce: 0.10)
}
