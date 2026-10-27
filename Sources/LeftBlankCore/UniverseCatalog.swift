import Foundation

/// Metadata from Typst's official preview index. Browsing never downloads package code.
public struct UniversePackage: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let description: String
    public let authors: [String]
    private let licenseValue: String
    public var license: String {
        licenseValue.isEmpty ? L10n.text("Unspecified") : licenseValue
    }

    public let keywords: [String]
    public let categories: [String]
    public let disciplines: [String]
    public let compiler: String?
    public let template: UniverseTemplateMetadata?

    public var isTemplate: Bool {
        template != nil
    }

    public var thumbnailURL: URL? {
        guard isValid, let template, template.isValid, template.thumbnail != nil else {
            return nil
        }
        return URL(string: "https://packages.typst.org/preview/thumbnails/\(name)-\(version)-small.webp")
    }

    public var id: String {
        name
    }

    public var reference: String {
        "@preview/\(name):\(version)"
    }

    public var documentationURL: URL {
        URL(string: "https://typst.app/universe/package/")!.appendingPathComponent(
            name,
            isDirectory: true,
        ).appendingPathComponent(version, isDirectory: true)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case description
        case authors
        case keywords
        case categories
        case disciplines
        case compiler
        case template
        case licenseValue = "license"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        authors = try values.decodeIfPresent([String].self, forKey: .authors) ?? []
        licenseValue = try values.decodeIfPresent(String.self, forKey: .licenseValue) ?? ""
        keywords = try values.decodeIfPresent([String].self, forKey: .keywords) ?? []
        categories = try values.decodeIfPresent([String].self, forKey: .categories) ?? []
        disciplines = try values.decodeIfPresent([String].self, forKey: .disciplines) ?? []
        compiler = try values.decodeIfPresent(String.self, forKey: .compiler)
        // Bad optional metadata must not hide an otherwise usable package.
        template = try? values.decodeIfPresent(UniverseTemplateMetadata.self, forKey: .template)
    }

    public func pinnedImport() throws -> Snippet {
        guard isValid else {
            throw UniverseError.invalidPackage
        }
        return Snippet(text: "#import \"\(reference)\"\n")
    }

    public func isCompatible(with compilerVersion: String) -> Bool {
        guard let compiler, let required = UniverseVersion(compiler),
              let installed = UniverseVersion(compilerVersion)
        else {
            return true
        }
        return installed >= required
    }

    var isValid: Bool {
        name.count <= 128 && name
            .range(of: "^[a-z][a-z0-9]*(-[a-z0-9]+)*\\z", options: .regularExpression) != nil &&
            UniverseVersion(version) != nil
    }
}

private struct UniverseVersion: Comparable {
    let components: [Int]
    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, value.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48 ... 57).contains($0) } })
        else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else {
            return nil
        }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct UniverseCategory: Identifiable, Sendable {
    public let id: String
    private let titleKey: String
    public var title: String {
        L10n.text(titleKey)
    }

    public var searchTerms: String {
        L10n.searchTerms(titleKey)
    }

    public static let all: [Self] = [
        .init(id: "", titleKey: "All Packages"), .init(id: "visualization", titleKey: "Drawing & Visualization"),
        .init(id: "components", titleKey: "Components"), .init(id: "text", titleKey: "Text"),
        .init(id: "layout", titleKey: "Layout"), .init(id: "model", titleKey: "Document Structure"),
        .init(id: "presentation", titleKey: "Presentations"), .init(id: "paper", titleKey: "Papers"),
        .init(id: "thesis", titleKey: "Theses"), .init(id: "report", titleKey: "Reports"),
        .init(id: "book", titleKey: "Books"), .init(id: "poster", titleKey: "Posters"),
        .init(id: "cv", titleKey: "CVs"), .init(id: "flyer", titleKey: "Flyers"),
        .init(id: "office", titleKey: "Office"), .init(id: "languages", titleKey: "Language"),
        .init(id: "integration", titleKey: "Integrations"), .init(id: "scripting", titleKey: "Scripting"),
        .init(id: "utility", titleKey: "Utilities"), .init(id: "fun", titleKey: "Fun"),
    ]
    public static func title(for id: String) -> String {
        all.first { $0.id == id }?.title ?? id
    }
}

public struct UniverseCatalogSnapshot: Sendable {
    public enum Source: Sendable { case network, cache, offlineCache, bundled }
    public let packages: [UniversePackage]
    public let fetchedAt: Date
    public let source: Source
    private let index: UniverseSearchIndex

    public init(packages: [UniversePackage], fetchedAt: Date, source: Source) {
        self.packages = packages
        self.fetchedAt = fetchedAt
        self.source = source
        index = UniverseSearchIndex(packages: packages)
    }

    public func search(_ query: String, category: String = "") -> [UniversePackage] {
        index.search(query, category: category)
    }

    public func discover(
        _ query: String,
        mode: UniverseDiscoveryMode,
        group: String = "",
        compilerVersion: String? = nil,
    ) -> [UniversePackage] {
        index.search(query, mode: mode, group: group, compilerVersion: compilerVersion)
    }
}

public enum UniverseError: LocalizedError {
    case invalidIndex
    case invalidPackage
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidIndex: L10n.text("The Universe index is invalid. Please refresh again later.")
        case .invalidPackage: L10n.text("The package name or version is invalid, so an import cannot be generated.")
        case .unavailable: L10n
            .text("Cannot reach Typst Universe. Refresh when connected; the cached index is still available.")
        }
    }
}

public struct UniverseHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public actor UniverseCatalogStore {
    public typealias Transport = @Sendable (URLRequest) async throws -> UniverseHTTPResponse
    public static let indexURL = URL(string: "https://packages.typst.org/preview/index.json")!
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
    private let cacheURL: URL
    private let transport: Transport
    private let now: @Sendable () -> Date
    private static let maximumBytes = 12 * 1024 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private static let includedSnapshot: UniverseCatalogSnapshot? = {
        guard let url = CoreResources.bundle.url(forResource: "universe-index", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= maximumBytes,
              let saved = try? JSONDecoder().decode(Cache.self, from: data),
              let packages = try? latest(saved.packages)
        else {
            return nil
        }
        return UniverseCatalogSnapshot(packages: packages, fetchedAt: saved.fetchedAt, source: .bundled)
    }()

    public init(
        cacheURL: URL,
        transport: @escaping Transport = UniverseCatalogStore.fetch,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.cacheURL = cacheURL
        self.transport = transport
        self.now = now
    }

    public static func fetch(_ request: URLRequest) async throws -> UniverseHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= maximumBytes else {
            throw UniverseError.invalidIndex
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw UniverseError.invalidIndex
            }
            data.append(byte)
        }
        return UniverseHTTPResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A release snapshot makes search usable on a first launch without a connection.
    /// It never pretends to be a fresh network cache or prevents an online refresh.
    public func bundled() -> UniverseCatalogSnapshot? {
        Self.includedSnapshot
    }

    public func cached() -> UniverseCatalogSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL), data.count <= Self.maximumBytes,
              let saved = try? JSONDecoder().decode(Cache.self, from: data), (1 ... 2).contains(saved.schema),
              let packages = try? Self.latest(saved.packages),
              saved.fetchedAt <= now().addingTimeInterval(300)
        else {
            return nil
        }
        // Keep older offline indexes usable, but refresh their missing template metadata online.
        let fetchedAt = saved
            .schema == 1 ? min(saved.fetchedAt, now().addingTimeInterval(-Self.cacheLifetime - 1)) : saved.fetchedAt
        return UniverseCatalogSnapshot(packages: packages, fetchedAt: fetchedAt, source: .cache)
    }

    public func load(forceRefresh: Bool = false) async throws -> UniverseCatalogSnapshot {
        let fallback = cached()
        if !forceRefresh, let fallback,
           now().timeIntervalSince(fallback.fetchedAt) < Self.cacheLifetime
        {
            return fallback
        }
        do {
            var request = URLRequest(url: Self.indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await transport(request)
            try Task.checkCancellation()
            guard response.statusCode == 200 else {
                throw UniverseError.unavailable
            }
            let packages = try Self.decodeIndex(response.data)
            let snapshot = UniverseCatalogSnapshot(packages: packages, fetchedAt: now(), source: .network)
            let cache = Cache(schema: 2, fetchedAt: snapshot.fetchedAt, packages: packages)
            // A read-only or full cache directory must not prevent online discovery.
            if let data = try? JSONEncoder().encode(cache) {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try? data.write(to: cacheURL, options: .atomic)
            }
            return snapshot
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let fallback {
                return UniverseCatalogSnapshot(
                    packages: fallback.packages,
                    fetchedAt: fallback.fetchedAt,
                    source: .offlineCache,
                )
            }
            if let error = error as? UniverseError {
                throw error
            }
            throw UniverseError.unavailable
        }
    }

    public static func decodeIndex(_ data: Data) throws -> [UniversePackage] {
        guard data.count <= maximumBytes,
              let packages = try? JSONDecoder().decode([UniversePackage].self, from: data)
        else {
            throw UniverseError.invalidIndex
        }
        return try latest(packages)
    }

    private static func latest(_ packages: [UniversePackage]) throws -> [UniversePackage] {
        var result: [String: UniversePackage] = [:]
        for package in packages where package.isValid {
            guard let version = UniverseVersion(package.version) else {
                throw UniverseError.invalidIndex
            }
            if let existing = result[package.name],
               let existingVersion = UniverseVersion(existing.version),
               existingVersion >= version
            {
                continue
            }
            result[package.name] = package
        }
        guard !result.isEmpty else {
            throw UniverseError.invalidIndex
        }
        return result.values.sorted { $0.name < $1.name }
    }

    private struct Cache: Codable { let schema: Int
        let fetchedAt: Date
        let packages: [UniversePackage]
    }
}
