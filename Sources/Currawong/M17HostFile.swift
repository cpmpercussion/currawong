// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reads the M17 Project's published reflector host file.
///
/// Its `reflectors` array mixes two shapes, told apart by `modules` rather
/// than the designator prefix: native M17 reflectors list module letters and
/// a `port`; URF multiprotocol reflectors list module objects with a `mode`
/// and no port. Only URF modules in `M17` or `All` (transcoding) mode are
/// offered; any other mode would fail or link into silence.
///
/// The `encrypted` field is not decoded: it usually lists every letter,
/// meaning "permitted", not "encrypted". FR-2.5 forbids an encryption UI.
enum M17HostFile {
    /// Where the published list lives.
    static let url = URL(string: "https://m17-project.github.io/hostfiles/M17Hosts.json")!

    /// The port for entries that carry none (URF): the M17 default.
    static let defaultPort: UInt16 = 17000

    /// Module modes on a multiprotocol reflector that an M17 client can use.
    private static let usableModes: Set<String> = ["M17", "ALL"]

    /// The URL schemes a dashboard link may use. The link comes from a third
    /// party and becomes tappable, so anything but a web page is refused.
    /// `http` is allowed because many dashboards use it, and the browser, not
    /// this app, opens it.
    private static let dashboardSchemes: Set<String> = ["http", "https"]

    /// A tappable dashboard link from the listing's `url` field, if it is one.
    /// Internal so the rule is testable.
    static func dashboard(from listed: String?) -> URL? {
        guard let text = listed?.nonEmpty,
            let url = URL(string: text),
            let scheme = url.scheme?.lowercased(),
            dashboardSchemes.contains(scheme),
            // A scheme with no host would open an error page.
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Parses the host file. Entries with no host or address are kept, and
    /// the row says so, rather than silently missing from the list.
    ///
    /// - Throws: ``ReflectorDirectoryError/malformed(detail:)`` if the file is
    ///   not JSON in the documented shape.
    static func parse(_ data: Data) throws -> [M17Reflector] {
        let decoded: HostFile
        do {
            decoded = try JSONDecoder().decode(HostFile.self, from: data)
        } catch {
            throw ReflectorDirectoryError.malformed(detail: "\(error)")
        }
        return decoded.reflectors.compactMap(\.reflector)
    }

    // MARK: - The file's own shape

    private struct HostFile: Decodable {
        var reflectors: [Entry]
    }

    private struct Entry: Decodable {
        var designator: String
        var name: String?
        var dns: String?
        var ipv4: String?
        var port: UInt16?
        var sponsor: String?
        var country: String?
        var url: String?
        var modules: Modules?
        var enabledModes: [String]?

        enum CodingKeys: String, CodingKey {
            case designator, name, dns, ipv4, port, sponsor, country, url, modules
            case enabledModes = "enabled_modes"
        }

        /// The app's version of this entry, or `nil` if there is no M17 module
        /// on it to offer.
        var reflector: M17Reflector? {
            let modules = usableModules
            guard !modules.isEmpty else { return nil }

            return M17Reflector(
                designator: designator,
                name: name,
                // A name first (see `M17Reflector.host`); both may be absent.
                host: dns?.nonEmpty ?? ipv4?.nonEmpty ?? "",
                port: port ?? M17HostFile.defaultPort,
                sponsor: sponsor?.nonEmpty,
                country: country?.nonEmpty,
                modules: modules,
                dashboard: M17HostFile.dashboard(from: url),
                isMultiprotocol: isMultiprotocol)
        }

        /// A URF entry is one that describes its modules as objects.
        private var isMultiprotocol: Bool {
            if case .detailed = modules { return true }
            return false
        }

        private var usableModules: [ReflectorModule] {
            switch modules {
            case .letters(let letters):
                return letters.map { ReflectorModule(letter: $0, note: nil) }

            case .detailed(let described):
                return described.compactMap { module in
                    guard let mode = module.mode,
                        M17HostFile.usableModes.contains(mode.uppercased())
                    else { return nil }
                    // A bare "All" reads as a module's name.
                    let note = mode.uppercased() == "ALL" ? "All modes" : mode
                    return ReflectorModule(letter: module.module, note: note)
                }

            case nil:
                return []
            }
        }
    }

    /// `modules` is an array of letters on a native M17 reflector and an array
    /// of objects on a URF one.
    private enum Modules: Decodable {
        case letters([String])
        case detailed([DescribedModule])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let letters = try? container.decode([String].self) {
                self = .letters(letters)
                return
            }
            self = .detailed(try container.decode([DescribedModule].self))
        }
    }

    private struct DescribedModule: Decodable {
        var module: String
        var mode: String?
    }
}

extension String {
    /// The trimmed string, or `nil` when empty: the host file uses `null` and
    /// `""` interchangeably for "not given".
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Fetches the reflector list over HTTPS. Separate from parsing so the
/// parsing rules are testable without a network.
struct HostFileReflectorDirectory: ReflectorDirectory {
    private let url: URL
    private let load: @Sendable (URL) async throws -> (Data, URLResponse)

    init(
        url: URL = M17HostFile.url,
        load: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            // Ephemeral, so Refresh never gets a cached file.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            return try await URLSession(configuration: configuration).data(from: url)
        }
    ) {
        self.url = url
        self.load = load
    }

    func reflectors() async throws -> [M17Reflector] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReflectorDirectoryError.unreachable(detail: "\(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReflectorDirectoryError.unreachable(
                detail: "the server answered \(http.statusCode)")
        }

        return try M17HostFile.parse(data)
    }
}
