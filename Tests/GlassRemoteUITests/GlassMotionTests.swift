import SwiftUI
import Testing
@testable import GlassRemoteUI

struct GlassMotionTests {
    @Test("Reduce Motion removes movement and keeps only a short replacement crossfade")
    func reducedMotionPolicy() {
        let moving: [GlassMotion.Role] = [.control, .feedback, .structure, .selection, .undo, .progress, .hover]
        for role in moving { #expect(GlassMotion.animation(role, reduceMotion: true) == nil) }
        #expect(GlassMotion.animation(.replacement, reduceMotion: true) == .linear(duration: 0.2))
        #expect(GlassMotion.attention(active: true, reduceMotion: true) == nil)
        #expect(GlassMotion.drop(isTargeted: true, reduceMotion: true) == nil)
    }

    @Test("saved inspector blur timings and its disabled state are preserved")
    func savedBlurTiming() {
        #expect(GlassMotion.inspectorBlur(enabled: true, waiting: true, easeIn: 0.8,
            easeOut: 0.6, reduceMotion: false) == .easeInOut(duration: 0.8))
        #expect(GlassMotion.inspectorBlur(enabled: true, waiting: false, easeIn: 0.8,
            easeOut: 0.6, reduceMotion: false) == .easeInOut(duration: 0.6))
        #expect(GlassMotion.inspectorBlur(enabled: false, waiting: true, easeIn: 0.8,
            easeOut: 0.6, reduceMotion: false) == nil)
    }
}
