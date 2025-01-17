@testable import App

import Vapor


extension App.FileManager {
    static let mock = Self.mock(fileExists: true)
    static func mock(fileExists: Bool) -> Self {
        .init(
            attributesOfItem: { _ in [:] },
            contentsOfDirectory: { _ in [] },
            checkoutsDirectory: { DirectoryConfiguration.detect().workingDirectory + "SPI-checkouts" },
            createDirectory: { path, _, _ in
                print("ℹ️ MOCK: imagine we're creating a directory at path: \(path)")
            },
            fileExists: { path in
                print("ℹ️ MOCK: file at \(path) exists")
                
                return fileExists
            },
            removeItem: { _ in },
            workingDirectory: { DirectoryConfiguration.detect().workingDirectory }
        )
    }
}
