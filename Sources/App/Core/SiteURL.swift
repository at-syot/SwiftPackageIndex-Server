import Plot
import Vapor


// MARK: - Resource declaration


// The following are all the routes we support and reference from various places, some of them
// static routes (images), others dynamic ones for use in controller definitions.
//
// Introduce nesting by declaring a new type conforming to Resourceable and embed it in the
// parent resource.
//
// Enums based on String are automatically Resourceable via RawRepresentable.


enum Api: Resourceable {
    case packages(_ owner: Parameter<String>, _ repository: Parameter<String>, PackagesPathComponents)
    case packageCollections
    case search
    case version
    case versions(_ id: Parameter<UUID>, VersionsPathComponents)
    
    var path: String {
        switch self {
            case let .packages(.value(owner), .value(repo), next):
                return "packages/\(owner)/\(repo)/\(next.path)"
            case .packages:
                fatalError("path must not be called with a name parameter")
            case .packageCollections:
                return "package-collections"
            case .version:
                return "version"
            case let .versions(.value(id), next):
                return "versions/\(id.uuidString)/\(next.path)"
            case .versions(.key, _):
                fatalError("path must not be called with a name parameter")
            case .search:
                return "search"
        }
    }
    
    var pathComponents: [PathComponent] {
        switch self {
            case let .packages(.key, .key, remainder):
                return ["packages", ":owner", ":repository"] + remainder.pathComponents
            case .packages:
                fatalError("pathComponents must not be called with a value parameter")
            case .packageCollections:
                return ["package-collections"]
            case .search, .version:
                return [.init(stringLiteral: path)]
            case let .versions(.key, remainder):
                return ["versions", ":id"] + remainder.pathComponents
            case .versions(.value, _):
                fatalError("pathComponents must not be called with a value parameter")
        }
    }
    
    enum PackagesPathComponents: String, Resourceable {
        case badge
        case triggerBuilds = "trigger-builds"
    }
    
    enum VersionsPathComponents: String, Resourceable {
        case builds
        case triggerBuild = "trigger-build"
    }
    
}


enum Docs: String, Resourceable {
    case builds
}


enum SiteURL: Resourceable {
    
    case api(Api)
    case author(_ owner: Parameter<String>)
    case builds(_ id: Parameter<UUID>)
    case docs(Docs)
    case faq
    case addAPackage
    case home
    case images(String)
    case package(_ owner: Parameter<String>, _ repository: Parameter<String>, PackagePathComponents?)
    case privacy
    case rssPackages
    case rssReleases
    case siteMap
    case stylesheets(String)
    
    var path: String {
        switch self {
            case let .api(next):
                return "api/\(next.path)"

            case let .author(.value(owner)):
                return owner

            case .author:
                fatalError("invalid path: \(self)")

            case let .builds(.value(id)):
                return "builds/\(id.uuidString)"

            case .builds(.key):
                fatalError("invalid path: \(self)")

            case let .docs(next):
                return "docs/\(next.path)"

            case .faq:
                return "faq"
                
            case .addAPackage:
                return "add-a-package"
                
            case .home:
                return ""
                
            case let .images(name):
                return "images/\(name)"
                
            case let .package(.value(owner), .value(repo), .none):
                let owner = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? owner
                let repo = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
                return "\(owner)/\(repo)"

            case let .package(owner, repo, .some(next)):
                return "\(Self.package(owner, repo, .none).path)/\(next.path)"

            case .package:
                fatalError("invalid path: \(self)")
                
            case .privacy:
                return "privacy"
                
            case .rssPackages:
                return "packages.rss"
                
            case .rssReleases:
                return "releases.rss"
                
            case .siteMap:
                return "sitemap.xml"
                
            case let .stylesheets(name):
                return "stylesheets/\(name)"
        }
    }
    
    var pathComponents: [PathComponent] {
        switch self {
            case .faq, .addAPackage, .home, .privacy, .rssPackages, .rssReleases, .siteMap:
                return [.init(stringLiteral: path)]
                
            case let .api(next):
                return ["api"] + next.pathComponents
                
            case .author:
                return [":owner"]

            case .builds(.key):
                return ["builds", ":id"]

            case .builds(.value):
                fatalError("pathComponents must not be called with a value parameter")

            case let .docs(next):
                return ["docs"] + next.pathComponents

            case .package(.key, .key, .none):
                return [":owner", ":repository"]
                
            case let .package(k1, k2, .some(next)):
                return Self.package(k1, k2, .none).pathComponents + next.pathComponents

            case .package:
                fatalError("pathComponents must not be called with a value parameter")
                
            case .images, .stylesheets:
                fatalError("invalid resource path for routing - only use in static HTML (DSL)")
        }
    }
    
    static let _relativeURL: (String) -> String = { path in
        guard path.hasPrefix("/") else { return "/" + path }
        return path
    }
    
    #if DEBUG
    // make `var` for debug so we can dependency inject
    static var relativeURL = _relativeURL
    #else
    static let relativeURL = _relativeURL
    #endif
    
    static func absoluteURL(_ path: String) -> String {
        Current.siteURL() + relativeURL(path)
    }
    
    static var apiBaseURL: String { absoluteURL("api") }

    enum PackagePathComponents: String, Resourceable {
        case builds
        case dependencies
    }

}


// MARK: - Types for use in resource declaration


protocol Resourceable {
    func absoluteURL(anchor: String?) -> String
    func relativeURL(anchor: String?) -> String
    var path: String { get }
    var pathComponents: [PathComponent] { get }
}


extension Resourceable {
    func absoluteURL(anchor: String? = nil) -> String {
        "\(SiteURL.absoluteURL(path))" + (anchor.map { "#\($0)" } ?? "")
    }
    
    func absoluteURL(parameters: [String: String]) -> String {
        "\(SiteURL.absoluteURL(path))\(parameters.queryString())"
    }
    
    func relativeURL(anchor: String? = nil) -> String {
        "\(SiteURL.relativeURL(path))" + (anchor.map { "#\($0)" } ?? "")
    }
}


extension Resourceable where Self: RawRepresentable, RawValue == String {
    var path: String { rawValue }
    var pathComponents: [PathComponent] { [.init(stringLiteral: path)] }
}


enum Parameter<T> {
    case key
    case value(T)
}
