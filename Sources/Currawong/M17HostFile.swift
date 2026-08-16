// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reads the M17 Project's published reflector host file.
///
/// <https://m17-project.github.io/hostfiles/M17Hosts.json> — a JSON file the
/// M17 Project publishes so that clients can offer a reflector list instead of
/// asking an operator to remember host names. The data behind it is DVRef's,
/// republished; the metadata block in the file says so.
///
/// ## Two shapes in one array
///
/// The `reflectors` array holds two kinds of entry, and the difference is not
/// signalled by a type field — it has to be read off the shape of `modules`:
///
/// - **Native M17 reflectors** (`M17-…`) carry `modules` as an array of letter
///   strings, plus `port` and `encrypted`.
/// - **URF reflectors** (`URF…`) are multiprotocol bridges. Their `modules` is
///   an array of objects with a per-module `mode`, and they carry **no `port`
///   at all** — the M17 port is the default 17000.
///
/// Decoding therefore tries the string form and falls back to the object form,
/// rather than trusting the designator prefix, which is a naming convention and
/// not a guarantee.
///
/// ## Which URF modules are usable, and which are not
///
/// A URF module has a `mode`: `M17`, `All`, or something we cannot speak such
/// as `DMR` or `D-Star (DCS)`. Only `M17` and `All` modules are offered. Linking
/// a DMR module from an M17 client would be a connection that either fails or,
/// worse, succeeds into silence.
///
/// ## Encryption is parsed and discarded, deliberately
///
/// Entries carry an `encrypted` array of module letters. It is not decoded here.
/// On most reflectors it lists all twenty-six letters, which reads as "encryption
/// is permitted" rather than "this traffic is encrypted" — so surfacing it would
/// put a scary word on nearly every row while telling the operator nothing about
/// the call they are about to make. The truthful place for this is the library,
/// which reports `playability == .encrypted` for a stream it actually cannot
/// decode. FR-2.5 forbids an encryption UI in any case.
enum M17HostFile {
    /// Where the published list lives.
    static let url = URL(string: "https://m17-project.github.io/hostfiles/M17Hosts.json")!

    /// The port a URF entry's M17 modules are on, since those entries carry no
    /// port of their own. 17000 is the M17 default and what every native entry
    /// in the list but eight uses.
    static let defaultPort: UInt16 = 17000

    /// Module modes on a multiprotocol reflector that an M17 client can use.
    /// `All` is a transcoding module — the far end may be on another mode, but
    /// the reflector will convert.
    private static let usableModes: Set<String> = ["M17", "ALL"]

    /// The URL schemes a dashboard link may use.
    ///
    /// **A filter, not a formality.** Every other field in this file becomes
    /// text on a row; this one becomes something the operator can tap, and the
    /// file is fetched from a third party. Handing an arbitrary string to the
    /// system opener is handing a stranger the choice of which app to launch —
    /// a `mailto:` or a custom scheme belonging to some other application would
    /// go through as readily as a web page. So a dashboard is a web page or it
    /// is nothing.
    ///
    /// `http` is here alongside `https` because roughly half the published
    /// dashboards are plain HTTP and dropping them would quietly remove the
    /// link from half the list. App Transport Security does not object: the URL
    /// is handed to the browser, and nothing in this app connects to it.
    private static let dashboardSchemes: Set<String> = ["http", "https"]

    /// A tappable dashboard link from the listing's `url` field, if it is one.
    ///
    /// Internal rather than private so the rule is testable on its own — what
    /// gets rejected here matters more than what gets through.
    static func dashboard(from listed: String?) -> URL? {
        guard let text = listed?.nonEmpty,
            let url = URL(string: text),
            let scheme = url.scheme?.lowercased(),
            dashboardSchemes.contains(scheme),
            // A scheme and no host is `http:` followed by nothing useful. It
            // would open the browser onto an error page rather than fail here,
            // which is a worse way to find out.
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Parses the host file.
    ///
    /// Entries that survive parsing but have nowhere to connect to — no host
    /// name and no address — are kept rather than dropped, and the row says so.
    /// Dropping them silently would leave an operator who knows a reflector
    /// exists searching a list that does not admit it.
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
                // A name first: see `M17Reflector.host`. Both may be absent —
                // one entry in the published list currently has neither.
                host: dns?.nonEmpty ?? ipv4?.nonEmpty ?? "",
                port: port ?? M17HostFile.defaultPort,
                sponsor: sponsor?.nonEmpty,
                country: country?.nonEmpty,
                modules: modules,
                dashboard: M17HostFile.dashboard(from: url),
                isMultiprotocol: isMultiprotocol)
        }

        /// A URF entry is the one that describes its modules as objects. The
        /// `URF` designator prefix agrees with this today, but the shape is the
        /// thing the decoder actually depends on, so it is the thing this asks.
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
                    // "All modes" rather than the file's bare "All", which on a
                    // row by itself reads as a module named All.
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
    /// The string, or `nil` when it is empty or only whitespace.
    ///
    /// The host file uses `null` and `""` interchangeably for "not given", and
    /// a row reading `M17-XYZ ·  · 1.2.3.4` is the result of believing the
    /// second one.
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Fetches the reflector list over HTTPS.
///
/// The only thing in the app that downloads it. Kept separate from parsing so
/// that every rule about the file's shape is testable against bytes, with no
/// network in the test (AU-5 in spirit — that rule is about the radio protocols,
/// but a unit test that needs the internet is just as flaky).
struct HostFileReflectorDirectory: ReflectorDirectory {
    private let url: URL
    private let load: @Sendable (URL) async throws -> (Data, URLResponse)

    init(
        url: URL = M17HostFile.url,
        load: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            // Not `.shared`: the reflector list is a hundred kilobytes that
            // changes daily, and the shared cache would happily serve a copy
            // from last week to an operator who pressed Refresh precisely
            // because they did not want one.
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
