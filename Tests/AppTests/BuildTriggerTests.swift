@testable import App

import SQLKit
import Vapor
import XCTest


class BuildTriggerTests: AppTestCase {

    func test_fetchBuildCandidates_missingBuilds() throws {
        // setup
        let pkgIdComplete = UUID()
        let pkgIdIncomplete1 = UUID()
        let pkgIdIncomplete2 = UUID()
        do {  // save package with all builds
            let p = Package(id: pkgIdComplete, url: pkgIdComplete.uuidString.url)
            try p.save(on: app.db).wait()
            let v = try Version(package: p,
                                latest: .defaultBranch,
                                reference: .branch("main"))
            try v.save(on: app.db).wait()
            try BuildPair.all.forEach { pair in
                try Build(id: UUID(),
                          version: v,
                          platform: pair.platform,
                          status: .ok,
                          swiftVersion: pair.swiftVersion)
                    .save(on: app.db).wait()
            }
        }
        // save two packages with partially completed builds
        try [pkgIdIncomplete1, pkgIdIncomplete2].forEach { id in
            let p = Package(id: id, url: id.uuidString.url)
            try p.save(on: app.db).wait()
            try [Version.Kind.defaultBranch, .release].forEach { kind in
                let v = try Version(package: p,
                                    latest: kind,
                                    reference: kind == .release
                                        ? .tag(1, 2, 3)
                                        : .branch("main"))
                try v.save(on: app.db).wait()
                try BuildPair.all
                    .dropFirst() // skip one platform to create a build gap
                    .forEach { pair in
                        try Build(id: UUID(),
                                  version: v,
                                  platform: pair.platform,
                                  status: .ok,
                                  swiftVersion: pair.swiftVersion)
                            .save(on: app.db).wait()
                    }
            }
        }

        // MUT
        let ids = try fetchBuildCandidates(app.db).wait()

        // validate
        XCTAssertEqual(ids, [pkgIdIncomplete1, pkgIdIncomplete2])
    }

    func test_fetchBuildCandidates_noBuilds() throws {
        // Test finding build candidate without any builds (essentially
        // testing the `LEFT` in `LEFT JOIN builds`)
        // setup
        // save package without any builds
        let pkgId = UUID()
        let p = Package(id: pkgId, url: pkgId.uuidString.url)
        try p.save(on: app.db).wait()
        try [Version.Kind.defaultBranch, .release].forEach { kind in
            let v = try Version(package: p,
                                latest: kind,
                                reference: kind == .release
                                    ? .tag(1, 2, 3)
                                    : .branch("main"))
            try v.save(on: app.db).wait()
        }

        // MUT
        let ids = try fetchBuildCandidates(app.db).wait()

        // validate
        XCTAssertEqual(ids, [pkgId])
    }

    func test_findMissingBuilds() throws {
        // setup
        let pkgId = UUID()
        let versionId = UUID()
        let droppedPlatform = try XCTUnwrap(Build.Platform.allActive.first)
        do {  // save package with partially completed builds
            let p = Package(id: pkgId, url: "1")
            try p.save(on: app.db).wait()
            let v = try Version(id: versionId,
                                package: p,
                                latest: .release,
                                reference: .tag(1, 2, 3))
            try v.save(on: app.db).wait()
            try Build.Platform.allActive
                .filter { $0 != droppedPlatform } // skip one platform to create a build gap
                .forEach { platform in
                try SwiftVersion.allActive.forEach { swiftVersion in
                    try Build(id: UUID(),
                              version: v,
                              platform: platform,
                              status: .ok,
                              swiftVersion: swiftVersion)
                        .save(on: app.db).wait()
                }
            }
        }

        // MUT
        let res = try findMissingBuilds(app.db, packageId: pkgId).wait()
        let expectedPairs = Set(SwiftVersion.allActive.map { BuildPair(droppedPlatform, $0) })
        XCTAssertEqual(res, [.init(versionId: versionId,
                                   pairs: expectedPairs,
                                   reference: .tag(1, 2, 3))])
    }

    func test_triggerBuildsUnchecked() throws {
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }

        // Use live dependency but replace actual client with a mock so we can
        // assert on the details being sent without actually making a request
        Current.triggerBuild = Gitlab.Builder.triggerBuild
        let queue = DispatchQueue(label: "serial")
        var queries = [Gitlab.Builder.PostDTO]()
        let client = MockClient { req, res in
            queue.sync {
                guard let query = try? req.query.decode(Gitlab.Builder.PostDTO.self) else { return }
                queries.append(query)
            }
        }

        let versionId = UUID()
        do {  // save package with partially completed builds
            let p = Package(id: UUID(), url: "2")
            try p.save(on: app.db).wait()
            let v = try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
            try v.save(on: app.db).wait()
        }
        let triggers = [BuildTriggerInfo(versionId: versionId,
                                         pairs: [BuildPair(.ios, .v5_4)])]

        // MUT
        try triggerBuildsUnchecked(on: app.db,
                                   client: client,
                                   logger: app.logger,
                                   triggers: triggers).wait()

        // validate
        // ensure Gitlab requests go out
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.map { $0.variables["VERSION_ID"] }, [versionId.uuidString])
        XCTAssertEqual(queries.map { $0.variables["BUILD_PLATFORM"] }, ["ios"])
        XCTAssertEqual(queries.map { $0.variables["SWIFT_VERSION"] }, ["5.4"])

        // ensure the Build stubs is created to prevent re-selection
        let v = try Version.find(versionId, on: app.db).wait()
        try v?.$builds.load(on: app.db).wait()
        XCTAssertEqual(v?.builds.count, 1)
        XCTAssertEqual(v?.builds.map(\.status), [.pending])
    }

    func test_triggerBuildsUnchecked_supported() throws {
        // Explicitly test the full range of all currently triggered platforms and swift versions
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }

        // Use live dependency but replace actual client with a mock so we can
        // assert on the details being sent without actually making a request
        Current.triggerBuild = Gitlab.Builder.triggerBuild
        let queue = DispatchQueue(label: "serial")
        var queries = [Gitlab.Builder.PostDTO]()
        let client = MockClient { req, res in
            queue.sync {
                guard let query = try? req.query.decode(Gitlab.Builder.PostDTO.self) else { return }
                queries.append(query)
            }
        }

        let pkgId = UUID()
        let versionId = UUID()
        do {  // save package with partially completed builds
            let p = Package(id: pkgId, url: "2")
            try p.save(on: app.db).wait()
            let v = try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
            try v.save(on: app.db).wait()
        }
        let triggers = try findMissingBuilds(app.db, packageId: pkgId).wait()

        // MUT
        try triggerBuildsUnchecked(on: app.db,
                                   client: client,
                                   logger: app.logger,
                                   triggers: triggers).wait()

        // validate
        // ensure Gitlab requests go out
        XCTAssertEqual(queries.count, 34)
        XCTAssertEqual(queries.map { $0.variables["VERSION_ID"] },
                       Array(repeating: versionId.uuidString, count: 34))
        let buildPlatforms = queries.compactMap { $0.variables["BUILD_PLATFORM"] }
        XCTAssertEqual(Dictionary(grouping: buildPlatforms, by: { $0 })
                        .mapValues(\.count),
                       ["ios": 5,
                        "macos-spm": 5,
                        "macos-spm-arm": 2,
                        "macos-xcodebuild": 5,
                        "macos-xcodebuild-arm": 2,
                        "linux": 5,
                        "watchos": 5,
                        "tvos": 5])
        let swiftVersions = queries.compactMap { $0.variables["SWIFT_VERSION"] }
        XCTAssertEqual(Dictionary(grouping: swiftVersions, by: { $0 })
                        .mapValues(\.count),
                       ["5.0": 6,
                        "5.1": 6,
                        "5.2": 6,
                        "5.3": 8,
                        "5.4": 8])

        // ensure the Build stubs are created to prevent re-selection
        let v = try Version.find(versionId, on: app.db).wait()
        try v?.$builds.load(on: app.db).wait()
        XCTAssertEqual(v?.builds.count, 34)

        // ensure re-selection is empty
        XCTAssertEqual(try fetchBuildCandidates(app.db).wait(), [])
    }

    func test_triggerBuilds_checked() throws {
        // Ensure we respect the pipeline limit when triggering builds
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }
        Current.gitlabPipelineLimit = { 300 }
        // Use live dependency but replace actual client with a mock so we can
        // assert on the details being sent without actually making a request
        Current.triggerBuild = Gitlab.Builder.triggerBuild
        var triggerCount = 0
        let client = MockClient { _, _ in triggerCount += 1 }

        do {  // fist run: we are at capacity and should not be triggering more builds
            Current.getStatusCount = { _, _ in self.future(300) }

            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "1")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: false)).wait()

            // validate
            XCTAssertEqual(triggerCount, 0)
            // ensure no build stubs have been created either
            let v = try Version.find(versionId, on: app.db).wait()
            try v?.$builds.load(on: app.db).wait()
            XCTAssertEqual(v?.builds.count, 0)
        }

        triggerCount = 0

        do {  // second run: we are just below capacity and allow more builds to be triggered
            Current.getStatusCount = { _, _ in self.future(299) }

            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "2")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: false)).wait()

            // validate
            XCTAssertEqual(triggerCount, 34)
            // ensure builds are now in progress
            let v = try Version.find(versionId, on: app.db).wait()
            try v?.$builds.load(on: app.db).wait()
            XCTAssertEqual(v?.builds.count, 34)
        }

        do {  // third run: we are at capacity and using the `force` flag
            Current.getStatusCount = { _, _ in self.future(300) }

            var triggerCount = 0
            let client = MockClient { _, _ in triggerCount += 1 }

            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "3")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: true)).wait()

            // validate
            XCTAssertEqual(triggerCount, 34)
            // ensure builds are now in progress
            let v = try Version.find(versionId, on: app.db).wait()
            try v?.$builds.load(on: app.db).wait()
            XCTAssertEqual(v?.builds.count, 34)
        }

    }

    func test_triggerBuilds_multiplePackages() throws {
        // Ensure we respect the pipeline limit when triggering builds for multiple package ids
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }
        Current.gitlabPipelineLimit = { 300 }
        // Use live dependency but replace actual client with a mock so we can
        // assert on the details being sent without actually making a request
        Current.triggerBuild = Gitlab.Builder.triggerBuild
        var triggerCount = 0
        let client = MockClient { _, _ in triggerCount += 1 }
        Current.getStatusCount = { _, _ in self.future(299 + triggerCount) }

        let pkgIds = [UUID(), UUID()]
        try pkgIds.forEach { id in
            let p = Package(id: id, url: id.uuidString.url)
            try p.save(on: app.db).wait()
            try Version(id: UUID(), package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()
        }

        // MUT
        try triggerBuilds(on: app.db,
                          client: client,
                          logger: app.logger,
                          parameter: .limit(4)).wait()

        // validate - only the first batch must be allowed to trigger
        XCTAssertEqual(triggerCount, 34)
    }

    func test_triggerBuilds_trimming() throws {
        // Ensure we trim builds as part of triggering
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }
        Current.gitlabPipelineLimit = { 300 }

        let client = MockClient { _, _ in }

        let pkgId = UUID()
        let versionId = UUID()
        let p = Package(id: pkgId, url: "2")
        try p.save(on: app.db).wait()
        let v = try Version(id: versionId, package: p, latest: nil, reference: .branch("main"))
        try v.save(on: app.db).wait()
        try Build(id: UUID(), version: v, platform: .ios, status: .pending, swiftVersion: .v5_1)
            .save(on: app.db).wait()
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 1)

        // MUT
        try triggerBuilds(on: app.db,
                          client: client,
                          logger: app.logger,
                          parameter: .id(pkgId, force: false)).wait()

        // validate
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 0)
    }

    func test_override_switch() throws {
        // Ensure don't trigger if the override is off
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }
        // Use live dependency but replace actual client with a mock so we can
        // assert on the details being sent without actually making a request
        Current.triggerBuild = Gitlab.Builder.triggerBuild
        var triggerCount = 0
        let client = MockClient { _, _ in triggerCount += 1 }

        do {  // confirm that the off switch prevents triggers
            Current.allowBuildTriggers = { false }


            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "1")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: false)).wait()

            // validate
            XCTAssertEqual(triggerCount, 0)
        }

        triggerCount = 0

        do {  // flipping the switch to on should allow triggers to proceed
            Current.allowBuildTriggers = { true }

            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "2")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: false)).wait()

            // validate
            XCTAssertEqual(triggerCount, 34)
        }
    }

    func test_downscaling() throws {
        // Test build trigger downscaling behaviour
        // setup
        Current.builderToken = { "builder token" }
        Current.gitlabPipelineToken = { "pipeline token" }
        Current.siteURL = { "http://example.com" }
        Current.buildTriggerDownscaling = { 0.05 }  // 5% downscaling rate
        // Use live dependency but replace actual client with a mock so we can
        // assert on the details being sent without actually making a request
        Current.triggerBuild = Gitlab.Builder.triggerBuild
        var triggerCount = 0
        let client = MockClient { _, _ in triggerCount += 1 }

        do {  // confirm that bad luck prevents triggers
            Current.random = { _ in 0.05 }  // rolling a 0.05 ... so close!

            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "1")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: false)).wait()

            // validate
            XCTAssertEqual(triggerCount, 0)
        }

        triggerCount = 0

        do {  // if we get lucky however...
            Current.random = { _ in 0.049 }  // rolling a 0.05 gets you in

            let pkgId = UUID()
            let versionId = UUID()
            let p = Package(id: pkgId, url: "2")
            try p.save(on: app.db).wait()
            try Version(id: versionId, package: p, latest: .defaultBranch, reference: .branch("main"))
                .save(on: app.db).wait()

            // MUT
            try triggerBuilds(on: app.db,
                              client: client,
                              logger: app.logger,
                              parameter: .id(pkgId, force: false)).wait()

            // validate
            XCTAssertEqual(triggerCount, 34)
        }

    }

    func test_trimBuilds() throws {
        // setup
        let pkgId = UUID()
        let p = Package(id: pkgId, url: "1")
        try p.save(on: app.db).wait()
        // v1 is a significant version, only old pending builds should be deleted
        let v1 = try Version(package: p, latest: .defaultBranch)
        try v1.save(on: app.db).wait()
        // v2 is not a significant version - all its builds should be deleted
        let v2 = try Version(package: p)
        try v2.save(on: app.db).wait()

        let deleteId1 = UUID()
        let keepBuildId1 = UUID()
        let keepBuildId2 = UUID()

        do {  // v1 builds
            // old pending build (delete)
            try Build(id: deleteId1,
                      version: v1, platform: .ios, status: .pending, swiftVersion: .v5_1)
                .save(on: app.db).wait()
            // new pending build (keep)
            try Build(id: keepBuildId1,
                      version: v1, platform: .ios, status: .pending, swiftVersion: .v5_2)
                .save(on: app.db).wait()
            // old non-pending build (keep)
            try Build(id: keepBuildId2,
                      version: v1, platform: .ios, status: .ok, swiftVersion: .v5_3)
                .save(on: app.db).wait()

            // make old builds "old" by resetting "created_at"
            try [deleteId1, keepBuildId2].forEach { id in
                let sql = "update builds set created_at = created_at - interval '4 hours' where id = '\(id.uuidString)'"
                try (app.db as! SQLDatabase).raw(.init(sql)).run().wait()
            }
        }

        do {  // v2 builds (should all be deleted)
            // old pending build
            try Build(id: UUID(),
                      version: v2, platform: .ios, status: .pending, swiftVersion: .v5_1)
                .save(on: app.db).wait()
            // new pending build
            try Build(id: UUID(),
                      version: v2, platform: .ios, status: .pending, swiftVersion: .v5_2)
                .save(on: app.db).wait()
            // old non-pending build
            try Build(id: UUID(),
                      version: v2, platform: .ios, status: .ok, swiftVersion: .v5_3)
                .save(on: app.db).wait()
        }

        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 6)

        // MUT
        let deleteCount = try trimBuilds(on: app.db).wait()

        // validate
        XCTAssertEqual(deleteCount, 4)
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 2)
        XCTAssertEqual(try Build.query(on: app.db).all().wait().map(\.id),
                       [keepBuildId1, keepBuildId2])
    }

    func test_trimBuilds_bindParam() throws {
        // Bind parameter issue regression test, details:
        // https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/909
        // setup
        let pkgId = UUID()
        let p = Package(id: pkgId, url: "1")
        try p.save(on: app.db).wait()
        let v1 = try Version(package: p, latest: .defaultBranch)
        try v1.save(on: app.db).wait()
        try Build(version: v1, platform: .ios, status: .pending, swiftVersion: .v5_1)
            .save(on: app.db).wait()

        let db = try XCTUnwrap(app.db as? SQLDatabase)
        try db.raw("update builds set created_at = NOW() - interval '1 h'")
            .run().wait()

        // MUT
        let deleteCount = try trimBuilds(on: app.db).wait()

        // validate
        XCTAssertEqual(deleteCount, 0)
    }

    func test_trimBuilds_timeout() throws {
        // Ensure timouts are not deleted
        // setup
        let pkgId = UUID()
        let p = Package(id: pkgId, url: "1")
        try p.save(on: app.db).wait()
        let v = try Version(package: p, latest: .defaultBranch)
        try v.save(on: app.db).wait()

        let buildId = UUID()
        try Build(id: buildId,
                  version: v,
                  platform: .ios,
                  status: .timeout,
                  swiftVersion: .v5_4)
            .save(on: app.db).wait()

        // MUT
        var deleteCount = try trimBuilds(on: app.db).wait()

        // validate
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 1)

        do { // make build "old" by resetting "created_at"
            let sql = "update builds set created_at = created_at - interval '4 hours' where id = '\(buildId.uuidString)'"
            try (app.db as! SQLDatabase).raw(.init(sql)).run().wait()
        }

        // MUT
        deleteCount = try trimBuilds(on: app.db).wait()

        // validate
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 1)
    }

    func test_trimBuilds_infrastructureError() throws {
        // Ensure infrastructerErrors are deleted
        // setup
        let pkgId = UUID()
        let p = Package(id: pkgId, url: "1")
        try p.save(on: app.db).wait()
        let v = try Version(package: p, latest: .defaultBranch)
        try v.save(on: app.db).wait()

        let buildId = UUID()
        try Build(id: buildId,
                  version: v,
                  platform: .ios,
                  status: .infrastructureError,
                  swiftVersion: .v5_4)
            .save(on: app.db).wait()

        // MUT
        var deleteCount = try trimBuilds(on: app.db).wait()

        // validate
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 1)

        do { // make build "old" by resetting "created_at"
            let sql = "update builds set created_at = created_at - interval '4 hours' where id = '\(buildId.uuidString)'"
            try (app.db as! SQLDatabase).raw(.init(sql)).run().wait()
        }

        // MUT
        deleteCount = try trimBuilds(on: app.db).wait()

        // validate
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(try Build.query(on: app.db).count().wait(), 0)
    }

    func test_BuildPair_Equatable() throws {
        XCTAssertEqual(BuildPair(.ios, .init(5, 3, 0)),
                       BuildPair(.ios, .init(5, 3, 3)))
        XCTAssertFalse(BuildPair(.ios, .init(5, 3, 0))
                       == BuildPair(.ios, .init(5, 4, 0)))
        XCTAssertFalse(BuildPair(.ios, .init(5, 3, 0))
                       == BuildPair(.tvos, .init(5, 3, 0)))
    }

    func test_BuildPair_Hashable() throws {
        let set = Set([BuildPair(.ios, .init(5, 3, 0))])
        XCTAssertTrue(set.contains(BuildPair(.ios, .init(5, 3, 3))))
        XCTAssertFalse(set.contains(BuildPair(.ios, .init(5, 4, 0))))
        XCTAssertFalse(set.contains(BuildPair(.macosSpm, .init(5, 3, 0))))
    }

    func test_issue_1065() throws {
        // Regression test for
        // https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/1065
        // addressing a problem with findMissingBuilds not ignoring
        // Swift patch versions.
        // setup
        let pkgId = UUID()
        let versionId = UUID()
        do {  // save package with an outdated Swift version
              // (5.3.0 when SwiftVersion.v5_3 is "5.3.3")
            let p = Package(id: pkgId, url: "1")
            try p.save(on: app.db).wait()
            let v = try Version(id: versionId,
                                package: p,
                                latest: .release,
                                reference: .tag(1, 2, 3))
            try v.save(on: app.db).wait()
            try Build(id: UUID(),
                      version: v,
                      platform: .ios,
                      status: .ok,
                      swiftVersion: .init(5, 3, 0))
                .save(on: app.db).wait()
        }

        // MUT
        let res = try findMissingBuilds(app.db, packageId: pkgId).wait()
        XCTAssertEqual(res.count, 1)
        let triggerInfo = try XCTUnwrap(res.first)
        XCTAssertEqual(triggerInfo.pairs.count, 33)
        XCTAssertTrue(!triggerInfo.pairs.contains(.init(.ios, .v5_3)))
    }
}
