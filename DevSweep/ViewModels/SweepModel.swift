import Foundation
import Observation

@MainActor
@Observable
final class SweepModel {
    var categories: [CacheCategory] = []
    var selection: Set<String> = []
    var isScanning = false
    var isCleaning = false
    var lastFreed: Int64?
    var errors: [String] = []

    var allItems: [CacheItem] { categories.flatMap(\.items) }

    var selectedSize: Int64 {
        allItems.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var selectedCount: Int {
        allItems.filter { selection.contains($0.id) }.count
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false }
        let result = await CacheScanner.scan()
        categories = result
        selection = Set(result.flatMap { $0.items.filter(\.preselected).map(\.id) })
    }

    func cleanSelected() async {
        isCleaning = true
        defer { isCleaning = false }
        errors = []
        var freed: Int64 = 0

        for item in allItems where selection.contains(item.id) {
            if let url = item.url {
                do {
                    try FileManager.default.removeItem(at: url)
                    freed += item.size
                } catch {
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            } else if let command = item.command {
                await Self.run(command)
                freed += item.size
            }
        }
        lastFreed = freed
        await scan()
    }

    nonisolated private static func run(_ command: [String]) async {
        guard let executable = command.first else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(command.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
    }
}
