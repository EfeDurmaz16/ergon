import Ergon
import Foundation

/// Loads a service descriptor shipped as JSON.
///
/// The descriptors live as data, not as Swift, which is the point: nothing in
/// a service definition needs a compiler, a macro, or a platform. Reading them
/// from the bundle is the halfway house. Reading them from a server is the
/// same function with a different URL.
public func bundledService(named name: String) throws -> ServiceDescriptor {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw DescriptorError(name, "no bundled descriptor with that name")
    }
    return try ServiceDescriptor(contentsOf: url)
}

extension ErgonToolkit {
    /// GitHub domain, read from `github.json`. Public reads need no credential;
    /// pass one to raise the rate limit and reach private repositories.
    ///
    /// A descriptor that fails to load yields an empty toolset rather than
    /// taking the whole app down: one malformed service must not cost the user
    /// their calendar.
    public static func gitHub(credentials: any CredentialStore = InMemoryCredentials([:])) -> Toolset? {
        guard let descriptor = try? bundledService(named: "github") else { return nil }
        return Toolset(
            name: "github",
            description: "GitHub repositories and issues. Examples: search for a swift http library, what are the open issues on apple/swift, find a repo about payments",
            dynamicTools: descriptor.tools(credentials: credentials),
            instructions: """
            Reply in the language of the request. Use the tools to answer and report exactly what they return, including repository names and numbers, unchanged.
            Never invent a repository, a star count, or an issue.
            Keep replies to one or two short sentences.
            """)
    }
}
