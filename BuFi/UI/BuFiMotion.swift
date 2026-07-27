import SwiftUI

enum BuFiMotion {
    // 빠르게 반응한 뒤 짧게 감쇠하도록 통일해 터치 지연감 없이 탄력만 남긴다.
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
    static let fade = Animation.spring(
        duration: 0.28,
        bounce: 0.08
    )
    static let text = Animation.spring(
        duration: 0.32,
        bounce: 0.12
    )
    static let color = Animation.easeInOut(duration: 0.34)
    static let lyrics = Animation.spring(
        duration: 0.42,
        bounce: 0.16
    )
}
