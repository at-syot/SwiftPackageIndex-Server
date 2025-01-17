import Fluent
import Vapor


extension API {
    struct SearchController {
        static func get(req: Request) throws -> EventLoopFuture<Search.Result> {
            let query = req.query[String.self, at: "query"] ?? ""
            let page = req.query[Int.self, at: "page"] ?? 1
            return search(database: req.db,
                          query: query,
                          page: page,
                          pageSize: Constants.searchPageSize)
        }
    }
}


extension API {
    static func search(database: Database,
                       query: String,
                       page: Int,
                       pageSize: Int) -> EventLoopFuture<Search.Result> {
        let terms = query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return database.eventLoop.future(.init(hasMoreResults: false, results: []))
        }
        return Search.fetch(database, terms, page: page, pageSize: pageSize)
    }
}
