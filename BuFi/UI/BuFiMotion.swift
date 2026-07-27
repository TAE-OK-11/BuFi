import SwiftUI

enum BuFiMotion {
    // 짧은 response와 적당한 damping으로 입력은 즉시 반응하고,
    // 플레이어·가사는 한 번만 탄력 있게 감쇠하도록 공통 곡선을 사용한다.
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
