@testable import App

import Vapor
import XCTest


class GithubTests: AppTestCase {
    
    func test_parseOwnerName() throws {
        do {
            let res = try Github.parseOwnerName(url: "https://github.com/foo/bar")
            XCTAssertEqual(res.owner, "foo")
            XCTAssertEqual(res.name, "bar")
        }
        do {
            let res = try Github.parseOwnerName(url: "https://github.com/foo/bar.git")
            XCTAssertEqual(res.owner, "foo")
            XCTAssertEqual(res.name, "bar")
        }
        XCTAssertThrowsError(
            try Github.parseOwnerName(url: "https://github.com/foo/bar/baz")
        ) { error in
            XCTAssertEqual(error.localizedDescription,
                           "invalid URL: https://github.com/foo/bar/baz (id: nil)")
        }
    }

    func test_decode_Metadata_null() throws {
        // Ensure missing values don't trip up decoding
        struct Response: Decodable {
            var data: Github.Metadata
        }
        do {
            let data = """
            {"data":{"repository":{"closedIssues":{"nodes":[]},"closedPullRequests":{"nodes":[]},"createdAt":"2019-04-23T09:26:22Z","defaultBranchRef":{"name":"master"},"description":null,"forkCount":0,"isArchived":false,"isFork":false,"licenseInfo":null,"mergedPullRequests":{"nodes":[]},"name":"CRToastSwift","openIssues":{"totalCount":0},"openPullRequests":{"totalCount":0},"owner":{"login":"krugazor","avatarUrl": "https://avatars.githubusercontent.com/u/2742179?u=28d2ccb6a27c975e663738fe86af579ff74203ac&v=4","name": "Nicolas Zinovieff"},"releases":{"nodes":[]},"stargazerCount":3,"isInOrganization":false},"rateLimit":{"remaining":4753}}}
            """
            _ = try Github.decoder.decode(Response.self, from: Data(data.utf8))
        }
        do {  // no repository at all (can happen)
            let data = """
                {"data":{"repository":null,"rateLimit":{"remaining":4986}},"errors":[{"type":"NOT_FOUND","path":["repository"],"locations":[{"line":2,"column":3}],"message":"Could not resolve to a Repository with the name 'IBM-Swift/kitura-mustachetemplateengine'."}]}
            """
            _ = try Github.decoder.decode(Response.self, from: Data(data.utf8))
        }
    }

    func test_fetchResource() throws {
        Current.githubToken = { "secr3t" }
        let client = MockClient { _, resp in
            resp.status = .ok
            resp.body = makeBody("{\"data\":{\"viewer\":{\"login\":\"finestructure\"}}}")
        }
        struct Response: Decodable, Equatable {
            var data: Data
            struct Data: Decodable, Equatable {
                var viewer: Viewer
            }
            struct Viewer: Decodable, Equatable {
                var login: String
            }
        }
        let q = Github.GraphQLQuery(query: "query { viewer { login } }")
        let res = try Github.fetchResource(Response.self, client: client, query: q).wait()
        XCTAssertEqual(res, Response(data: .init(viewer: .init(login: "finestructure"))))
    }

    func test_fetchMetadata() throws {
        Current.githubToken = { "secr3t" }
        let data = try XCTUnwrap(try loadData(for: "github-graphql-resource.json"))
        let client = MockClient { _, resp in
            resp.status = .ok
            resp.body = makeBody(data)
        }
        let iso8601 = ISO8601DateFormatter()

        // MUT
        let res = try Github.fetchMetadata(client: client,
                                           owner: "alamofire",
                                           repository: "alamofire").wait()

        // validation
        XCTAssertEqual(res.repository?.closedIssues.nodes.first!.closedAt,
                       iso8601.date(from: "2020-11-24T16:00:07Z"))
        XCTAssertEqual(res.repository?.closedPullRequests.nodes.first!.closedAt,
                       iso8601.date(from: "2020-08-13T19:10:08Z"))
        XCTAssertEqual(res.repository?.forkCount, 6480)
        XCTAssertEqual(res.repository?.mergedPullRequests.nodes.first!.closedAt,
                       iso8601.date(from: "2020-11-04T21:27:43Z"))
        XCTAssertEqual(res.repository?.name, "Alamofire")
        XCTAssertEqual(res.repository?.owner.name, "Alamofire")
        XCTAssertEqual(res.repository?.owner.login, "Alamofire")
        XCTAssertEqual(res.repository?.owner.avatarUrl, "https://avatars.githubusercontent.com/u/7774181?v=4")
        XCTAssertEqual(res.repository?.openIssues.totalCount, 30)
        XCTAssertEqual(res.repository?.openPullRequests.totalCount, 6)
        XCTAssertEqual(res.repository?.releases.nodes.count, 10)
        XCTAssertEqual(res.repository?.releases.nodes.first, .some(
                        .init(description: "Released on 2020-11-04. All issues associated with this milestone can be found using this [filter](https://github.com/Alamofire/Alamofire/milestone/74?closed=1).\r\n\r\n#### Added\r\n- `URLResponseSerializer` and attendant convenience methods so downloads can produce a non-optional `URL`.\r\n  - Added by[Jon Shier](https://github.com/jshier) in Pull Request [#3343](https://github.com/Alamofire/Alamofire/pull/3343).\r\n\r\n#### Updated\r\n- Handing of `file://` `URL`s, removing error added in 5.3.0 and adding support for `DownloadRequest`.\r\n  - Updated by [Jon Shier](https://github.com/jshier) in Pull Request [#3342](https://github.com/Alamofire/Alamofire/pull/3342).",
                            descriptionHTML: "<p>Released on 2020-11-04. All issues associated with this milestone can be found using this <a href=\"https://github.com/Alamofire/Alamofire/milestone/74?closed=1\">filter</a>.</p>\n<h4>Added</h4>\n<ul>\n<li><code>URLResponseSerializer</code> and attendant convenience methods so downloads can produce a non-optional <code>URL</code>.\n<ul>\n<li>Added by<a href=\"https://github.com/jshier\">Jon Shier</a> in Pull Request <a href=\"https://github.com/Alamofire/Alamofire/pull/3343\" data-hovercard-type=\"pull_request\" data-hovercard-url=\"/Alamofire/Alamofire/pull/3343/hovercard\">#3343</a>.</li>\n</ul>\n</li>\n</ul>\n<h4>Updated</h4>\n<ul>\n<li>Handing of <code>file://</code> <code>URL</code>s, removing error added in 5.3.0 and adding support for <code>DownloadRequest</code>.\n<ul>\n<li>Updated by <a href=\"https://github.com/jshier\">Jon Shier</a> in Pull Request <a href=\"https://github.com/Alamofire/Alamofire/pull/3342\" data-hovercard-type=\"pull_request\" data-hovercard-url=\"/Alamofire/Alamofire/pull/3342/hovercard\">#3342</a>.</li>\n</ul>\n</li>\n</ul>",
                              isDraft: false,
                              publishedAt: iso8601.date(from: "2020-11-04T21:40:10Z")!,
                              tagName: "5.4.0",
                              url: "https://github.com/Alamofire/Alamofire/releases/tag/5.4.0")
        ))
        XCTAssertEqual(res.repository?.stargazerCount, 34720)
        XCTAssertEqual(res.repository?.isInOrganization, true)
        // derived properties
        XCTAssertEqual(res.repository?.lastIssueClosedAt,
                       iso8601.date(from: "2020-11-24T16:00:07Z"))
        // merged date is latest - expect that one to be reported back
        XCTAssertEqual(res.repository?.lastPullRequestClosedAt,
                       iso8601.date(from: "2020-11-04T21:27:43Z"))
    }

    func test_fetchMetadata_badRequest() throws {
        Current.githubToken = { "secr3t" }
        let client = MockClient { _, resp in
            resp.status = .badRequest
        }

        XCTAssertThrowsError(
            try Github.fetchMetadata(client: client,
                                     owner: "alamofire",
                                     repository: "alamofire").wait()
        ) {
            guard case Github.Error.requestFailed(.badRequest) = $0 else {
                XCTFail("unexpected error: \($0.localizedDescription)")
                return
            }
        }
    }

    func test_fetchMetadata_badUrl() throws {
        let pkg = Package(url: "https://foo/bar")
        let client = MockClient { _, resp in
            resp.status = .ok
        }
        XCTAssertThrowsError(try Github.fetchMetadata(client: client, package: pkg).wait()) {
            guard case Github.Error.invalidURI = $0 else {
                XCTFail("unexpected error: \($0.localizedDescription)")
                return
            }
        }
    }
    
    func test_fetchMetadata_badData() throws {
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/foo/bar")
        let client = MockClient { _, resp in
            resp.status = .ok
            resp.body = makeBody("bad data")
        }

        // MUT
        XCTAssertThrowsError(try Github.fetchMetadata(client: client, package: pkg).wait()) {
            // validation
            guard case DecodingError.dataCorrupted = $0 else {
                XCTFail("unexpected error: \($0.localizedDescription)")
                return
            }
        }
    }
    
    func test_fetchMetadata_rateLimiting_429() throws {
        // Github doesn't actually send a 429 when you hit the rate limit
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/foo/bar")
        let client = MockClient { _, resp in
            resp.status = .tooManyRequests
        }

        // MUT
        XCTAssertThrowsError(try Github.fetchMetadata(client: client, package: pkg).wait()) {
            // validation
            guard case Github.Error.requestFailed(.tooManyRequests) = $0 else {
                XCTFail("unexpected error: \($0.localizedDescription)")
                return
            }
        }
    }
    
    func test_isRateLimited() throws {
        do {
            let res = ClientResponse(status: .forbidden,
                                     headers: .init([("X-RateLimit-Remaining", "0")]))
            XCTAssertTrue(Github.isRateLimited(res))
        }
        do {
            let res = ClientResponse(status: .forbidden,
                                     headers: .init([("x-ratelimit-remaining", "0")]))
            XCTAssertTrue(Github.isRateLimited(res))
        }
        do {
            let res = ClientResponse(status: .forbidden,
                                     headers: .init([("X-RateLimit-Remaining", "1")]))
            XCTAssertFalse(Github.isRateLimited(res))
        }
        do {
            let res = ClientResponse(status: .forbidden,
                                     headers: .init([("unrelated", "0")]))
            XCTAssertFalse(Github.isRateLimited(res))
        }
        do {
            let res = ClientResponse(status: .ok,
                                     headers: .init([("X-RateLimit-Remaining", "0")]))
            XCTAssertFalse(Github.isRateLimited(res))
        }
    }
    
    func test_fetchMetadata_rateLimiting_403() throws {
        // Github sends a 403 and a rate limit remaining header
        //   X-RateLimit-Limit: 60
        //   X-RateLimit-Remaining: 56
        // Ensure we record it as a rate limit error and raise a Rollbar item
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/foo/bar")
        let client = MockClient { _, resp in
            resp.status = .forbidden
            resp.headers.add(name: "X-RateLimit-Remaining", value: "0")
        }
        var reportedLevel: AppError.Level? = nil
        var reportedError: Error? = nil
        Current.reportError = { _, level, error in
            reportedLevel = level
            reportedError = error
            return self.future(())
        }
        
        // MUT
        XCTAssertThrowsError(try Github.fetchMetadata(client: client, package: pkg).wait()) {
            // validation
            XCTAssertNotNil(reportedError)
            XCTAssertEqual(reportedLevel, .critical)
            guard case Github.Error.requestFailed(.tooManyRequests) = $0 else {
                XCTFail("unexpected error: \($0.localizedDescription)")
                return
            }
        }
    }

    func test_apiUri() throws {
        let pkg = Package(url: "https://github.com/foo/bar")
        XCTAssertEqual(try Github.apiUri(for: pkg, resource: .license).string,
                       "https://api.github.com/repos/foo/bar/license")
        XCTAssertEqual(try Github.apiUri(for: pkg, resource: .readme).string,
                       "https://api.github.com/repos/foo/bar/readme")
    }

    func test_fetchLicense() throws {
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/PSPDFKit/PSPDFKit-SP")
        let data = try XCTUnwrap(try loadData(for: "github-license-response.json"))
        let client = MockClient { _, resp in
            resp.status = .ok
            resp.body = makeBody(data)
        }

        // MUT
        let res = try Github.fetchLicense(client: client, package: pkg).wait()

        // validate
        XCTAssertEqual(res?.htmlUrl, "https://github.com/PSPDFKit/PSPDFKit-SP/blob/master/LICENSE")
    }

    func test_fetchLicense_notFound() throws {
        // https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/761
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/foo/bar")
        let client = MockClient { _, resp in resp.status = .notFound }

        // MUT
        let res = try Github.fetchLicense(client: client, package: pkg).wait()

        // validate
        XCTAssertEqual(res, nil)
    }

    func test_fetchReadme() throws {
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/daveverwer/leftpad")
        let data = try XCTUnwrap(try loadData(for: "github-readme-response.json"))
        let client = MockClient { _, resp in
            resp.status = .ok
            resp.body = makeBody(data)
        }

        // MUT
        let res = try Github.fetchReadme(client: client, package: pkg).wait()

        // validate
        XCTAssertEqual(res?.downloadUrl, "https://raw.githubusercontent.com/daveverwer/LeftPad/master/README.md")
    }

    func test_fetchReadme_notFound() throws {
        // setup
        Current.githubToken = { "secr3t" }
        let pkg = Package(url: "https://github.com/daveverwer/leftpad")
        let client = MockClient { _, resp in resp.status = .notFound }

        // MUT
        let res = try Github.fetchReadme(client: client, package: pkg).wait()

        // validate
        XCTAssertEqual(res?.downloadUrl, nil)
    }

}
