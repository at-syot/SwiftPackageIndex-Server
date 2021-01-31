import Foundation


// `Manifest` is mirroring what `dump-package` presumably renders into JSON
// https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html
// Mentioning this in particular with regards to optional values, like `platforms`
// vs mandatory ones like `products`
//
//Package(
//    name: String,
//    platforms: [SupportedPlatform]? = nil,
//    products: [Product] = [],
//    dependencies: [Package.Dependency] = [],
//    targets: [Target] = [],
//    swiftLanguageVersions: [SwiftVersion]? = nil,
//    cLanguageStandard: CLanguageStandard? = nil,
//    cxxLanguageStandard: CXXLanguageStandard? = nil
//)


struct Manifest: Decodable, Equatable {
    struct Platform: Decodable, Equatable {
        enum Name: String, Decodable, Equatable, CaseIterable {
            case macos
            case ios
            case tvos
            case watchos
        }
        var platformName: Name
        var version: String
    }
    struct Product: Decodable, Equatable {
        enum `Type`: String, CodingKey, CaseIterable {
            case executable
            case library
        }
        var name: String
        var targets: [String] = []
        var type: `Type`
    }
    struct Dependency: Decodable, Equatable {
        var name: String
        var url: URL
    }
    struct Target: Decodable, Equatable {
        var name: String
    }
    struct ToolsVersion: Decodable, Equatable {
        enum CodingKeys: String, CodingKey {
            case version = "_version"
        }
        var version: String
    }
    var name: String
    var platforms: [Platform]?
    var products: [Product]
    var dependencies: [Dependency]
    var swiftLanguageVersions: [String]?
    var targets: [Target]
    var toolsVersion: ToolsVersion?
}


extension Manifest.Product.`Type`: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Self.self)
        for k in Self.allCases {
            if let _ = try? container.decodeNil(forKey: k) {
                self = k
                return
            }
            
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: container.codingPath,
                                  debugDescription: "none of the required keys found"))
    }
}
