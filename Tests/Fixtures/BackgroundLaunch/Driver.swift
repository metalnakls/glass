import AppKit

@main
private enum Driver {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let app = root.appendingPathComponent("Probe.app")
        let identifier = Bundle(url: app)!.bundleIdentifier!
        let worker = Process()
        worker.executableURL = app.appendingPathComponent("Contents/MacOS/Probe")
        worker.arguments = ["--worker"]
        try worker.run()
        defer {
            for process in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
                process.forceTerminate()
            }
            if worker.isRunning { worker.terminate() }
        }
        func events() -> String { (try? String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)) ?? "" }
        func waitFor(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "BackgroundLaunchTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out: \(label); events: \(events())"])
        }
        try await waitFor("worker startup") { events().contains("worker:") }
        // Exercise Launch Services, not a direct delegate call. This is the
        // request that promoted the old RunLoop worker and returned error -600.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        try await waitFor("foreground window process") { events().contains("foreground:") }

        func send(_ id: AEEventID, urls: [URL] = []) throws {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: worker.processIdentifier),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            if !urls.isEmpty {
                let list = NSAppleEventDescriptor.list()
                for (i, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: i + 1) }
                event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
            }
            try event.sendEvent(options: .noReply, timeout: 1)
        }
        let files = ["one.torrent", "two.torrent"].map { root.appendingPathComponent($0) }
        for file in files { try Data().write(to: file) }
        try send(AEEventID(kAEOpenDocuments), urls: files)
        try send(AEEventID(kAEReopenApplication))
        try send(AEEventID(kAEReopenApplication))
        try await waitFor("both files and repeated reopen") {
            files.allSatisfy { events().contains("url:\($0.absoluteString)") } &&
                events().components(separatedBy: "reopen").count >= 3
        }
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard processes.count == 2,
              processes.first(where: { $0.processIdentifier == worker.processIdentifier })?.activationPolicy == .prohibited,
              events().components(separatedBy: "foreground:").count == 2 else {
            throw NSError(domain: "BackgroundLaunchTest", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Worker became foreground or duplicate window processes launched"])
        }
        let magnet = "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"
        let link = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: worker.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        link.setParam(NSAppleEventDescriptor(string: magnet), forKeyword: AEKeyword(keyDirectObject))
        try link.sendEvent(options: .noReply, timeout: 1)
        try await waitFor("magnet delivery") { events().contains("url:\(magnet)") }
        let foreground = processes.first { $0.processIdentifier != worker.processIdentifier }!
        foreground.forceTerminate()
        try await waitFor("foreground termination") { foreground.isTerminated }
        try send(AEEventID(kAEOpenDocuments), urls: files)
        try send(AEEventID(kAEReopenApplication))
        try send(AEEventID(kAEOpenDocuments), urls: files)
        try await waitFor("cold file launch and queued requests") {
            events().components(separatedBy: "foreground:").count == 3 &&
                files.allSatisfy { events().components(separatedBy: "url:\($0.absoluteString)").count == 4 }
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count == 2 else {
            throw NSError(domain: "BackgroundLaunchTest", code: 3)
        }
        print("PASS: Launch Services reopen, warm/cold file delivery, magnet delivery, queued opens, one foreground process, background worker")

    }
}
