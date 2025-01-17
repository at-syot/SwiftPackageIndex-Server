import Fluent
import Foundation
import SemanticVersion
import SQLKit


struct RecentRelease: Decodable, Equatable {
    static let schema = "recent_releases"
    
    var id: UUID
    var repositoryOwner: String
    var repositoryName: String
    var packageName: String
    var packageSummary: String?
    var version: String
    var releasedAt: Date
    var releaseUrl: String?
    var releaseNotesHTML: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case repositoryOwner = "repository_owner"
        case repositoryName = "repository_name"
        case packageName = "package_name"
        case packageSummary = "package_summary"
        case version
        case releasedAt = "released_at"
        case releaseUrl = "release_url"
        case releaseNotesHTML = "release_notes_html"
    }
}

extension RecentRelease {
    static func refresh(on database: Database) -> EventLoopFuture<Void> {
        guard let db = database as? SQLDatabase else {
            fatalError("Database must be an SQLDatabase ('as? SQLDatabase' must succeed)")
        }
        return db.raw("REFRESH MATERIALIZED VIEW \(raw: Self.schema)").run()
    }
    
    static func filterReleases(_ releases: [RecentRelease], by filter: Filter) -> [RecentRelease] {
        if filter == .all { return releases }
        return releases.filter { recent in
            guard let version = SemanticVersion(recent.version) else { return false }
            if filter.contains(.major) && version.isMajorRelease { return true }
            if filter.contains(.minor) && version.isMinorRelease { return true }
            if filter.contains(.patch) && version.isPatchRelease { return true }
            if filter.contains(.pre) && version.isPreRelease { return true }
            return false
        }
    }
    
    static func fetch(on database: Database,
                      limit: Int = Constants.recentPackagesLimit,
                      filter: Filter = .all) -> EventLoopFuture<[RecentRelease]> {
        guard let db = database as? SQLDatabase else {
            fatalError("Database must be an SQLDatabase ('as? SQLDatabase' must succeed)")
        }
        
        return db.raw("SELECT * FROM \(raw: Self.schema) ORDER BY released_at DESC LIMIT \(bind: limit)")
            .all(decoding: RecentRelease.self)
            .map { filterReleases($0, by: filter) }
    }
}


extension RecentRelease {
    struct Filter: OptionSet {
        let rawValue: Int
        
        static let major = Filter(rawValue: 1 << 0)
        static let minor = Filter(rawValue: 1 << 1)
        static let patch = Filter(rawValue: 1 << 2)
        static let pre = Filter(rawValue: 1 << 3)
        static var all: Self { [.major, .minor, .patch, .pre] }
    }
}


extension RecentRelease.Filter {
    init(_ string: String) {
        switch string.lowercased() {
            case "major":
                self = .major
            case "minor":
                self = .minor
            case "patch":
                self = .patch
            case "pre":
                self = .pre
            default:
                self = [.major, .minor, .patch, .pre]
        }
    }
}
