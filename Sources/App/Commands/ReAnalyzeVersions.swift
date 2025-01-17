import Vapor
import Fluent


struct ReAnalyzeVersionsCommand: Command {
    let defaultBatchSize = 10
    let defaultLimit = 1

    struct Signature: CommandSignature {
        @Option(name: "batchSize", short: "b")
        var batchSize: Int?
        @Option(name: "limit", short: "l")
        var limit: Int?
        @Option(name: "id")
        var id: UUID?
        @Option(name: "before")
        var before: Date?
    }

    var help: String { "Run version re-analysis" }

    func run(using context: CommandContext, signature: Signature) throws {
        let limit = signature.limit ?? defaultLimit

        let client = context.application.client
        let db = context.application.db
        let logger = Logger(component: "re-analyze-versions")
        let threadPool = context.application.threadPool

        if let id = signature.id {
            logger.info("Re-analyzing versions (id: \(id)) ...")
            try reAnalyzeVersions(client: client,
                                  database: db,
                                  logger: logger,
                                  threadPool: threadPool,
                                  versionsLastUpdatedBefore: Current.date(),
                                  id: id)
                .wait()
        } else {
            guard let cutoffDate = signature.before else {
                logger.info("No cut-off date set, skipping re-analysis")
                return
            }

            logger.info("Re-analyzing versions (limit: \(limit)) ...")
            var processed = 0
            while processed < limit {
                let currentBatchSize = min(signature.batchSize ?? defaultBatchSize,
                                           limit - processed)
                logger.info("Re-analyzing versions (batch: \(processed)..<\(processed + currentBatchSize) ...")
                try reAnalyzeVersions(client: client,
                                      database: db,
                                      logger: logger,
                                      threadPool: threadPool,
                                      before: cutoffDate,
                                      limit: currentBatchSize)
                .wait()
                processed += currentBatchSize
            }
        }
        try AppMetrics.push(client: client,
                            logger: logger,
                            jobName: "re-analyze-versions")
            .wait()

        logger.info("done.")
    }
}


/// Re-analyze outdated versions for a given `Package`, identified by its `Id`.
/// - Parameters:
///   - client: `Client` object
///   - database: `Database` object
///   - logger: `Logger` object
///   - threadPool: `NIOThreadPool` (for running shell commands)
///   - versionsLastUpdatedBefore: `Date` cut-off for versions to update
///   - packages: packages to be analysed
/// - Returns: future
func reAnalyzeVersions(client: Client,
                       database: Database,
                       logger: Logger,
                       threadPool: NIOThreadPool,
                       versionsLastUpdatedBefore cutOffDate: Date,
                       id: Package.Id) -> EventLoopFuture<Void> {
    Package.fetchCandidate(database, id: id)
        .map { [$0] }
        .flatMap { reAnalyzeVersions(client: client,
                                     database: database,
                                     logger: logger,
                                     threadPool: threadPool,
                                     before: cutOffDate,
                                     packages: $0) }
}


/// Re-analyze outdated versions.
/// - Parameters:
///   - client: `Client` object
///   - database: `Database` object
///   - logger: `Logger` object
///   - threadPool: `NIOThreadPool` (for running shell commands)
///   - versionsLastUpdatedBefore: `Date` cut-off for versions to update
///   - packages: packages to be analysed
/// - Returns: future
func reAnalyzeVersions(client: Client,
                       database: Database,
                       logger: Logger,
                       threadPool: NIOThreadPool,
                       before cutOffDate: Date,
                       limit: Int) -> EventLoopFuture<Void> {
    Package.fetchReAnalysisCandidates(database,
                                      before: cutOffDate,
                                      limit: limit)
        .flatMap { reAnalyzeVersions(client: client,
                                     database: database,
                                     logger: logger,
                                     threadPool: threadPool,
                                     before: cutOffDate,
                                     packages: $0) }
}


/// Re-analyze outdated versions for the given list of `Package`s.
/// - Parameters:
///   - client: `Client` object
///   - database: `Database` object
///   - logger: `Logger` object
///   - threadPool: `NIOThreadPool` (for running shell commands)
///   - versionsLastUpdatedBefore: `Date` cut-off for versions to update
///   - packages: packages to be analysed
/// - Returns: future
func reAnalyzeVersions(client: Client,
                       database: Database,
                       logger: Logger,
                       threadPool: NIOThreadPool,
                       before cutoffDate: Date,
                       packages: [Package]) -> EventLoopFuture<Void> {
    // Pick essentials parts of companion function `analyze` and run the for
    // re-analysis.
    //
    // We don't refresh checkouts, because these are being refreshed in `analyze`
    // and would race unnecessarily if we also tried to refresh them here.
    //
    // Care should be taken to ensure `reAnalyzeVersions` operates on a
    // set of versions that is distinct from those `analyze` updates, to
    // avoid data races.
    //
    // Since `reAnalyzeVersions` only updates existing versions, this will be the
    // case by design, as `analyze` will only add or remove versions, ignoring
    // existing ones.

    database.transaction { tx in
        getExistingVersions(client: client,
                            logger: logger,
                            threadPool: threadPool,
                            transaction: tx,
                            packages: packages,
                            before: cutoffDate)
            .flatMap { setUpdatedAt(on: tx, packageVersions: $0) }
            .flatMap { mergeReleaseInfo(on: tx, packageVersions: $0) }
            .map { getManifests(packageAndVersions: $0) }
            .flatMap { updateVersions(on: tx, packageResults: $0) }
            .flatMap { updateProducts(on: tx, packageResults: $0) }
            .flatMap { updateTargets(on: tx, packageResults: $0) }
    }
    .transform(to: ())
}


func getExistingVersions(client: Client,
                         logger: Logger,
                         threadPool: NIOThreadPool,
                         transaction: Database,
                         packages: [Package],
                         before cutoffDate: Date) -> EventLoopFuture<[Result<(Package, [Version]), Error>]> {
    EventLoopFuture.whenAllComplete(
        packages.map { pkg in
            diffVersions(client: client,
                         logger: logger,
                         threadPool: threadPool,
                         transaction: transaction,
                         package: pkg)
                .map {
                    (pkg, $0.toKeep.filter {
                        $0.updatedAt != nil && $0.updatedAt! < cutoffDate
                    })
                }
                .map { pkg, versions in
                    logger.info("updating \(versions.count) versions (id: \(pkg.id)) ...")
                    return (pkg, versions)
                }
        },
        on: transaction.eventLoop
    )
}


func setUpdatedAt(on database: Database,
                  packageVersions: [Result<(Package, [Version]), Error>]) -> EventLoopFuture<[Result<(Package, [Version]), Error>]> {
    packageVersions.whenAllComplete(on: database.eventLoop) { pkg, versions in
        versions
            .map { version -> Version in
                version.updatedAt = Current.date()
                return version
            }
            .save(on: database)
            .map { (pkg, versions) }
    }
}


/// Merge release details from `Repository.releases` into the list of existing `Version`s.
/// - Parameters:
///   - transaction: transaction to run the save and delete in
///   - packageVersions: tuples containing the `Package` and its existing `Version`s
/// - Returns: future with an array of each `Package` paired with its existing `Version`s for further processing
func mergeReleaseInfo(on transaction: Database,
                      packageVersions: [Result<(Package, [Version]), Error>]) -> EventLoopFuture<[Result<(Package, [Version]), Error>]> {
    packageVersions.whenAllComplete(on: transaction.eventLoop) { pkg, versions in
        mergeReleaseInfo(on: transaction, package: pkg, versions: versions)
            .map { (pkg, $0) }
    }
}


extension Package {
    static func fetchReAnalysisCandidates(
        _ database: Database,
        before cutOffDate: Date,
        limit: Int) -> EventLoopFuture<[Package]> {
        Package.query(on: database)
            .with(\.$repositories)
            .join(Version.self, on: \Package.$id == \Version.$package.$id)
            .filter(Version.self, \.$updatedAt < cutOffDate)
            .fields(for: Package.self)
            .unique()
            .sort(\.$updatedAt)
            .limit(limit)
            .all()
    }
}
