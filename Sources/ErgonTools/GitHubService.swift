import Ergon
import Foundation

/// GitHub as a descriptor rather than as code.
///
/// It is the first real service on the remote path and it earns that place by
/// being awkward in the right ways: nested response objects, arrays that need
/// trimming before a small model can read them, wire names that differ from
/// the names a model reasons about, and an endpoint that takes a bearer token
/// when you have one. Public reads work without a credential, so the path can
/// be proved end to end before any OAuth exists.
///
/// Nothing here is Swift-specific. The same values, expressed as JSON, are
/// what a downloaded descriptor will carry.
public func gitHubService(credentialName: String? = nil) -> ServiceDescriptor {
    ServiceDescriptor(
        name: "GitHub",
        baseURL: URL(string: "https://api.github.com")!,
        authentication: credentialName.map { .bearer(credential: $0) } ?? .none,
        headers: [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ],
        operations: [
            ServiceOperation(
                name: "searchRepositories",
                description: "Search public GitHub repositories by keyword.",
                path: "/search/repositories",
                parameters: [
                    ServiceParameter(SchemaProperty(name: "query",
                                                    description: "What to search for, like 'swift http client'",
                                                    schema: .string(oneOf: [])),
                                     in: .query, wireName: "q"),
                ],
                fixedQuery: ["sort": "stars", "order": "desc", "per_page": "5"],
                projection: ResponseProjection(
                    itemsPath: "items",
                    fields: [
                        ProjectionField(label: "Repo", path: "full_name"),
                        ProjectionField(label: "Stars", path: "stargazers_count"),
                        ProjectionField(label: "About", path: "description"),
                    ],
                    maximumItems: 5)),

            ServiceOperation(
                name: "listIssues",
                description: "List the open issues of a GitHub repository.",
                path: "/repos/{owner}/{repo}/issues",
                parameters: [
                    ServiceParameter(SchemaProperty(name: "owner",
                                                    description: "Owner of the repository, like 'apple'",
                                                    schema: .string(oneOf: [])), in: .path),
                    ServiceParameter(SchemaProperty(name: "repo",
                                                    description: "Repository name, like 'swift'",
                                                    schema: .string(oneOf: [])), in: .path),
                ],
                fixedQuery: ["state": "open", "per_page": "5"],
                projection: ResponseProjection(
                    fields: [
                        ProjectionField(label: "Issue", path: "[0].title"),
                        ProjectionField(label: "Number", path: "[0].number"),
                        ProjectionField(label: "Opened by", path: "[0].user.login"),
                    ])),
        ])
}

extension ErgonToolkit {
    /// GitHub domain, built from the descriptor. Public reads need no
    /// credential; pass one to raise the rate limit and reach private repos.
    public static func gitHub(credentials: any CredentialStore = InMemoryCredentials([:]),
                              credentialName: String? = nil) -> Toolset {
        Toolset(name: "github",
                description: "GitHub repositories and issues. Examples: search for a swift http library, what are the open issues on apple/swift, find a repo about payments",
                dynamicTools: gitHubService(credentialName: credentialName).tools(credentials: credentials),
                instructions: """
                Reply in the language of the request. Use the tools to answer and report exactly what they return, including repository names and numbers, unchanged.
                Never invent a repository, a star count, or an issue.
                Keep replies to one or two short sentences.
                """)
    }
}
