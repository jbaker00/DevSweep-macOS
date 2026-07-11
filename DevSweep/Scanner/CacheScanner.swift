import Foundation

/// Discovers developer caches and their on-disk sizes. Everything here is
/// read-only; deletion lives in SweepModel.
enum CacheScanner {

    static func scan() async -> [CacheCategory] {
        let builders: [@Sendable () -> CacheCategory?] = [
            derivedData,
            deviceSupport,
            simulatorCaches,
            simulatorDevices,
            simulatorRuntimes,
            archives,
            packageManagerCaches,
            mlCaches,
        ]
        return await withTaskGroup(of: (Int, CacheCategory?).self) { group in
            for (index, build) in builders.enumerated() {
                group.addTask { (index, build()) }
            }
            var results: [(Int, CacheCategory)] = []
            for await (index, category) in group {
                if let category, !category.items.isEmpty {
                    results.append((index, category))
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Categories

    @Sendable private static func derivedData() -> CacheCategory? {
        let root = home("Library/Developer/Xcode/DerivedData")
        let items = subdirectories(of: root).map { dir in
            CacheItem(id: "derived:\(dir.lastPathComponent)",
                      name: dir.lastPathComponent,
                      detail: "Build products and indexes — rebuilt on next build",
                      url: dir,
                      size: directorySize(dir),
                      preselected: true)
        }
        return CacheCategory(id: "derived", name: "Xcode DerivedData",
                             note: "Per-project build caches. Deleting only costs a full rebuild.",
                             items: items.sorted { $0.size > $1.size })
    }

    /// Debug symbols copied from every physical device OS version ever connected.
    /// Keeps the newest version per device model deselected; everything older is fair game.
    @Sendable private static func deviceSupport() -> CacheCategory? {
        let root = home("Library/Developer/Xcode/iOS DeviceSupport")
        let dirs = subdirectories(of: root)

        // Folder names look like "iPhone18,2 26.5.2 (23F84)" — group by model,
        // compare the version token numerically.
        func model(_ url: URL) -> String { url.lastPathComponent.components(separatedBy: " ").first ?? url.lastPathComponent }
        func version(_ url: URL) -> String {
            let parts = url.lastPathComponent.components(separatedBy: " ")
            return parts.count > 1 ? parts[1] : ""
        }
        let newestPerModel = Dictionary(grouping: dirs, by: model).compactMapValues { group in
            group.max { version($0).compare(version($1), options: .numeric) == .orderedAscending }
        }
        let keepers = Set(newestPerModel.values)

        let items = dirs.map { dir in
            let isNewest = keepers.contains(dir)
            return CacheItem(id: "devsupport:\(dir.lastPathComponent)",
                             name: dir.lastPathComponent,
                             detail: isNewest ? "Newest for this device — kept by default"
                                              : "Superseded; Xcode regenerates on next device connect",
                             url: dir,
                             size: directorySize(dir),
                             preselected: !isNewest,
                             risk: isNewest ? .caution : .safe)
        }
        return CacheCategory(id: "devsupport", name: "iOS DeviceSupport",
                             note: "Symbols from physical devices. Regenerated automatically when a device reconnects.",
                             items: items.sorted { $0.size > $1.size })
    }

    @Sendable private static func simulatorCaches() -> CacheCategory? {
        var items: [CacheItem] = []
        for url in [home("Library/Developer/CoreSimulator/Caches"),
                    URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches")] {
            let size = directorySize(url)
            if size > 0 {
                items.append(CacheItem(id: "simcache:\(url.path)",
                                       name: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                       detail: "dyld and runtime caches — rebuilt on next simulator boot",
                                       url: url,
                                       size: size,
                                       preselected: true))
            }
        }
        return CacheCategory(id: "simcache", name: "Simulator caches",
                             note: "Safe to clear; simulators rebuild these on boot.",
                             items: items)
    }

    @Sendable private static func simulatorDevices() -> CacheCategory? {
        let item = CacheItem(id: "simctl:delete-unavailable",
                             name: "Delete unavailable simulators",
                             detail: "Runs `xcrun simctl delete unavailable` — removes devices whose runtime is gone",
                             command: ["/usr/bin/xcrun", "simctl", "delete", "unavailable"],
                             size: 0,
                             preselected: true)
        return CacheCategory(id: "simctl", name: "Simulator devices",
                             note: "Removes devices whose runtime is gone. Runtimes themselves are in Simulator runtimes below.",
                             items: [item])
    }

    /// Downloaded simulator runtimes (~16GB each). Deleted via
    /// `simctl runtime delete <uuid>`, which finishes asynchronously on Apple's
    /// side, so runtimes whose state is not "Ready" (mid-deletion) are skipped.
    /// NOTHING here is ever preselected — the user must opt in.
    @Sendable private static func simulatorRuntimes() -> CacheCategory? {
        guard let json = jsonOutput(["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"])
                as? [String: Any] else { return nil }

        struct Runtime {
            let uuid: String
            let platform: String
            let version: String
            let build: String
            let size: Int64
            let runtimeIdentifier: String?
        }
        var runtimes: [Runtime] = []
        for (key, value) in json {
            guard let dict = value as? [String: Any] else { continue }
            // Not "Ready" means download in progress or already being deleted.
            guard (dict["state"] as? String) == "Ready" else { continue }
            runtimes.append(Runtime(uuid: dict["identifier"] as? String ?? key,
                                    platform: platformName(dict["platformIdentifier"] as? String ?? ""),
                                    version: dict["version"] as? String ?? "",
                                    build: dict["build"] as? String ?? "",
                                    size: dict["sizeBytes"] as? Int64 ?? 0,
                                    runtimeIdentifier: dict["runtimeIdentifier"] as? String))
        }
        guard !runtimes.isEmpty else { return nil }

        // How many simulator devices reference each runtime, keyed by
        // identifiers like "com.apple.CoreSimulator.SimRuntime.iOS-26-4".
        let deviceCounts = simulatorDeviceCounts()
        func deviceCount(for runtime: Runtime) -> Int {
            if let id = runtime.runtimeIdentifier, let count = deviceCounts[id] { return count }
            // Loose fallback: identifier suffix "iOS-26-4" matches versions "26.4" and "26.4.1".
            let parts = runtime.version.components(separatedBy: ".")
            guard parts.count >= 2 else { return 0 }
            let suffix = "\(runtime.platform)-\(parts[0])-\(parts[1])"
            return deviceCounts.first { $0.key.hasSuffix(suffix) }?.value ?? 0
        }

        // Keep-newest safety: the newest version per platform is caution.
        let newestPerPlatform = Dictionary(grouping: runtimes, by: \.platform).compactMapValues { group in
            group.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        }
        let keepers = Set(newestPerPlatform.values.map(\.uuid))

        let items = runtimes.map { runtime -> CacheItem in
            let isNewest = keepers.contains(runtime.uuid)
            var detail = isNewest ? "Newest \(runtime.platform) runtime — kept by default"
                                  : "Superseded — re-downloadable from Xcode Settings"
            let used = deviceCount(for: runtime)
            if used > 0 { detail += " · used by \(used) simulator(s)" }
            return CacheItem(id: "runtime:\(runtime.uuid)",
                             name: "\(runtime.platform) \(runtime.version) (\(runtime.build))",
                             detail: detail,
                             command: ["/usr/bin/xcrun", "simctl", "runtime", "delete", runtime.uuid],
                             size: runtime.size,
                             preselected: false,
                             risk: isNewest ? .caution : .safe)
        }
        return CacheCategory(id: "runtimes", name: "Simulator runtimes",
                             note: "Nothing preselected: each runtime is a ~16GB re-download from Xcode Settings. Deleting one also removes the simulators that use it; deletion finishes in the background.",
                             items: items.sorted { $0.size > $1.size })
    }

    @Sendable private static func archives() -> CacheCategory? {
        let root = home("Library/Developer/Xcode/Archives")
        let items = subdirectories(of: root).map { dir in
            CacheItem(id: "archive:\(dir.lastPathComponent)",
                      name: dir.lastPathComponent,
                      detail: "App archives — needed to re-symbolicate crashes from those builds",
                      url: dir,
                      size: directorySize(dir),
                      preselected: false,
                      risk: .caution)
        }
        return CacheCategory(id: "archives", name: "Xcode Archives",
                             note: "Not preselected: keep archives for any build still in the field.",
                             items: items.sorted { $0.size > $1.size })
    }

    @Sendable private static func packageManagerCaches() -> CacheCategory? {
        var items: [CacheItem] = []
        let dirCaches: [(String, String, String)] = [
            ("npm", ".npm/_cacache", "npm download cache"),
            ("swiftpm", "Library/Caches/org.swift.swiftpm", "Swift Package Manager checkouts and manifests"),
            ("pip", "Library/Caches/pip", "Python package downloads"),
            ("cocoapods", "Library/Caches/CocoaPods", "CocoaPods spec repo and pod downloads"),
            ("gradle", ".gradle/caches", "Gradle dependency and build caches"),
            ("playwright", "Library/Caches/ms-playwright", "Playwright browser binaries"),
        ]
        for (id, path, detail) in dirCaches {
            let url = home(path)
            let size = directorySize(url)
            if size > 0 {
                items.append(CacheItem(id: "pkg:\(id)", name: id,
                                       detail: "\(detail) — re-downloaded on demand",
                                       url: url, size: size, preselected: true))
            }
        }
        let brewCache = directorySize(home("Library/Caches/Homebrew"))
        if brewCache > 0 {
            items.append(CacheItem(id: "pkg:brew", name: "Homebrew",
                                   detail: "Runs `brew cleanup -s --prune=all`",
                                   command: ["/bin/zsh", "-lc", "brew cleanup -s --prune=all"],
                                   size: brewCache,
                                   preselected: true))
        }
        return CacheCategory(id: "pkg", name: "Package manager caches",
                             note: "All re-downloaded on demand.",
                             items: items.sorted { $0.size > $1.size })
    }

    @Sendable private static func mlCaches() -> CacheCategory? {
        var items: [CacheItem] = []
        let hf = home(".cache/huggingface")
        let hfSize = directorySize(hf)
        if hfSize > 0 {
            items.append(CacheItem(id: "ml:hf", name: "Hugging Face",
                                   detail: "Downloaded models — large re-downloads if you use them again",
                                   url: hf, size: hfSize,
                                   preselected: false, risk: .caution))
        }
        let ollama = home(".ollama/models")
        let ollamaSize = directorySize(ollama)
        if ollamaSize > 0 {
            items.append(CacheItem(id: "ml:ollama", name: "Ollama models",
                                   detail: "Local LLM weights — prefer `ollama rm <model>` for specific ones",
                                   url: ollama, size: ollamaSize,
                                   preselected: false, risk: .caution))
        }
        return CacheCategory(id: "ml", name: "ML model caches",
                             note: "Not preselected: models can take a long time to re-download.",
                             items: items)
    }

    // MARK: - simctl helpers

    /// Runs a command synchronously and parses its stdout as JSON.
    /// Returns nil if the command fails to launch, exits non-zero, or the
    /// output is not valid JSON. Read-only: only used with `list` commands.
    private static func jsonOutput(_ command: [String]) -> Any? {
        guard let executable = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain the pipe before waiting so large output can't deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// "com.apple.platform.iphonesimulator" → "iOS", etc.
    private static func platformName(_ identifier: String) -> String {
        let id = identifier.lowercased()
        if id.contains("watch") { return "watchOS" }
        if id.contains("appletv") { return "tvOS" }
        if id.contains("xr") || id.contains("vision") { return "visionOS" }
        if id.contains("mac") { return "macOS" }
        if id.contains("iphone") || id.contains("ipad") || id.contains("ios") { return "iOS" }
        return identifier.components(separatedBy: ".").last ?? identifier
    }

    /// Device counts per runtime identifier from `simctl list devices -j`.
    /// Best effort — an empty dictionary just means no "used by N" annotations.
    private static func simulatorDeviceCounts() -> [String: Int] {
        guard let json = jsonOutput(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"])
                as? [String: Any],
              let devices = json["devices"] as? [String: Any] else { return [:] }
        var counts: [String: Int] = [:]
        for (runtimeIdentifier, list) in devices {
            counts[runtimeIdentifier] = (list as? [Any])?.count ?? 0
        }
        return counts
    }

    // MARK: - Filesystem helpers

    private static func home(_ path: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    private static func subdirectories(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
