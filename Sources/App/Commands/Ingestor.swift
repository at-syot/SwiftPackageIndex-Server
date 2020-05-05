import Vapor
import Fluent


struct IngestorCommand: Command {
    let defaultLimit = 1

    struct Signature: CommandSignature {
        @Option(name: "limit", short: "l")
        var limit: Int?
    }

    var help: String { "Run package ingestion (fetching repository metadata)" }

    func run(using context: CommandContext, signature: Signature) throws {
        let limit = signature.limit ?? defaultLimit
        context.console.info("Ingesting (limit: \(limit)) ...")
        let request = ingest(client: context.application.client,
                             database: context.application.db,
                             limit: limit)
        context.console.info("Processing ...", newLine: true)
        try request.wait()
    }

}


func ingest(client: Client, database: Database, limit: Int) -> EventLoopFuture<Void> {
    Package.fetchUpdateCandidates(database, limit: limit)
        .flatMapEach(on: database.eventLoop) { fetchMetadata(for: $0, with: client) }
        .flatMapEachThrowing { updateTables(on: database, result: $0) }
        .flatMap { .andAllComplete($0, on: database.eventLoop) }
}


typealias PackageMetadata = (Package, Github.Metadata)


func fetchMetadata(for package: Package, with client: Client) -> EventLoopFuture<Result<PackageMetadata, Error>> {
    do {
        return try Current.fetchMetadata(client, package)
            .map { .success((package, $0)) }
            .flatMapErrorThrowing { .failure($0) }
    } catch {
        return client.eventLoop.makeSucceededFuture(.failure(error))
    }
}


func updateTables(on database: Database, result: Result<PackageMetadata, Error>) -> EventLoopFuture<Void> {
    do {
        let (pkg, md) = try result.get()
        return try insertOrUpdateRepository(on: database, for: pkg, metadata: md)
            .flatMap {
                pkg.status = .ok
                return pkg.save(on: database)
            }
    } catch {
        return recordIngestionError(database: database, error: error)
    }
}


func insertOrUpdateRepository(on database: Database, for package: Package, metadata: Github.Metadata) throws -> EventLoopFuture<Void> {
    Repository.query(on: database)
        .filter(try \.$package.$id == package.requireID())
        .first()
        .flatMap { repo -> EventLoopFuture<Void> in
            if let repo = repo {
                repo.defaultBranch = metadata.defaultBranch
                repo.description = metadata.description
                repo.forks = metadata.forksCount
                repo.license = metadata.license?.key
                repo.stars = metadata.stargazersCount
                // TODO: find and assign parent repo
                return repo.save(on: database)
            } else {
                do {
                    return try Repository(package: package, metadata: metadata)
                        .save(on: database)
                } catch {
                    return database.eventLoop.makeFailedFuture(
                        AppError.genericError(package.id,
                                              "Failed to create Repository for \(package.url)")
                    )
                }
            }
        }
}


func recordIngestionError(database: Database, error: Error) -> EventLoopFuture<Void> {
    func setStatus(id: Package.Id?, status: Status) -> EventLoopFuture<Void> {
        Package.find(id, on: database).flatMap { pkg in
            guard let pkg = pkg else { return database.eventLoop.makeSucceededFuture(()) }
            pkg.status = status
            return pkg.save(on: database)
        }
    }

    database.logger.error("Ingestion error: \(error.localizedDescription)")

    switch error {
        case let AppError.invalidPackageUrl(id, _):
            return setStatus(id: id, status: .invalidUrl)
        case let AppError.metadataRequestFailed(id, _, _):
            return setStatus(id: id, status: .metadataRequestFailed)
        case let AppError.genericError(id, _):
            return setStatus(id: id, status: .ingestionFailed)
        default:
            // TODO: log somewhere more actionable - table or online service
            return database.eventLoop.makeSucceededFuture(())
    }
}