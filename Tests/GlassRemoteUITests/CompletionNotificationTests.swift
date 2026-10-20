import AppKit
import SwiftUI
import UserNotifications
import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Completion notifications", .serialized)
struct CompletionNotificationTests {
    @Test("notification titles preserve case and use the list's extension policy")
    func titles() {
        #expect(GlassCompletionNotificationCenter.title(name: "My Movie.MKV", displayName: "My Movie.MKV", fileCount: 1, showsExtensions: false) == "My Movie")
        #expect(GlassCompletionNotificationCenter.title(name: "My Movie.MKV", displayName: "My Movie.MKV", fileCount: 1, showsExtensions: true) == "My Movie.MKV")
        #expect(GlassCompletionNotificationCenter.title(name: "Series", displayName: "Series Season 1", fileCount: 12, showsExtensions: false) == "Series Season 1")
        #expect(GlassCompletionNotificationCenter.title(name: "Game.ZIP", displayName: "Game.ZIP", fileCount: 1, showsExtensions: false) == "Game.ZIP")
    }
    @Test("system completion alerts appear even for downloads visible in Glass")
    func foregroundCompletionAlert() {
        let visible = GlassCompletionNotificationCenter.presentationOptions(isVisible: true)
        let offscreen = GlassCompletionNotificationCenter.presentationOptions(isVisible: false)
        #expect(visible.contains(.banner))
        #expect(visible.contains(.sound))
        #expect(!visible.contains(.list))
        #expect(offscreen.contains(.banner))
        #expect(offscreen.contains(.sound))
        #expect(offscreen.contains(.list))
    }

    @Test("acknowledgement distinguishes identical hashes on different destinations")
    func identities() {
        let first = GlassCompletionNotificationCenter.key(["sourceID": "first", "hashString": "same", "name": "Title"])
        let second = GlassCompletionNotificationCenter.key(["sourceID": "second", "hashString": "same", "name": "Title"])
        #expect(first != second)
        #expect(GlassCompletionNotificationCenter.key(["name": "Title"]) == nil)
    }
    @Test("clears only the visible download, including older notification identifiers")
    func selectiveRemoval() {
        func request(_ id: String, source: String, hash: String) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo = ["sourceID": source, "hashString": hash]
            return UNNotificationRequest(identifier: id, content: content, trigger: nil)
        }
        let requests = [request("legacy-random", source: "one", hash: "seen"),
                        request("completed-one:seen", source: "one", hash: "seen"),
                        request("unseen", source: "one", hash: "unseen"),
                        request("other-destination", source: "two", hash: "seen")]
        #expect(GlassCompletionNotificationCenter.identifiersToClear(requests: requests, keys: ["one:seen"]) == ["legacy-random", "completed-one:seen"])
        #expect(GlassCompletionNotificationCenter.identifiersToClear(requests: requests, keys: []).isEmpty)
        #expect(GlassCompletionNotificationCenter.identifiersToClear(requests: requests, keys: ["one:seen"], excluding: ["completed-one:seen"]) == ["legacy-random"])
        #expect(GlassCompletionNotificationCenter.unreadCount(requests: requests, visibleKeys: ["one:seen"]) == 2)
        #expect(GlassCompletionNotificationCenter.unreadCount(requests: requests, visibleKeys: []) == 4)
    }

    @Test("missing local files and unmapped shares report failure for the Glass fallback")
    func unavailableDownload() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(await glassOpenCompletedTorrent(sourceID: UUID(), directory: directory, name: "Missing Movie.MKV", isLocal: true) == false)
        #expect(await glassOpenCompletedTorrent(sourceID: UUID(), directory: "/remote/downloads", name: "Game", isLocal: false) == false)
    }

    @Test("native scroll visibility excludes offscreen rows and follows scrolling", arguments: [false, true])
    func viewport(grid: Bool) async throws {
        var visible = Set<String>()
        let report: @MainActor (Set<String>, UUID, Bool) -> Void = { keys, _, shown in
            if shown { visible.formUnion(keys) } else { visible.subtract(keys) }
        }
        func rows() -> some View {
            ForEach(0..<30) { index in
                Text("Download \(index)").frame(height: 60)
                    .modifier(CompletionVisibility(keys: [String(index)], report: report))
            }
        }
        let fixture = Group {
            if grid { ScrollView { LazyVGrid(columns: [GridItem(.flexible())]) { rows() } } }
            else { List { rows() }.listStyle(.plain) }
        }
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: fixture)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            if visible.contains("0") { break }
        }
        #expect(visible.contains("0"))
        #expect(!visible.contains("29"))
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try #require(scrollView(in: host))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1200))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            if !visible.contains("0"), !visible.isEmpty { break }
        }
        #expect(!visible.contains("0"))
        #expect(!visible.isEmpty)
    }

}
