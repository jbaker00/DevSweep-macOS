import Foundation

enum Risk: Sendable {
    /// Regenerated automatically; deleting costs nothing but a rebuild/redownload.
    case safe
    /// Deleting loses something you might want (old archives, symbols for older devices).
    case caution
}

/// One deletable thing: either a filesystem path or an external command.
struct CacheItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let url: URL?
    /// Full executable path + args; used when url is nil (e.g. `brew cleanup`).
    let command: [String]?
    let size: Int64
    let preselected: Bool
    let risk: Risk

    init(id: String, name: String, detail: String, url: URL? = nil,
         command: [String]? = nil, size: Int64, preselected: Bool, risk: Risk = .safe) {
        self.id = id
        self.name = name
        self.detail = detail
        self.url = url
        self.command = command
        self.size = size
        self.preselected = preselected
        self.risk = risk
    }
}

struct CacheCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let note: String
    var items: [CacheItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
