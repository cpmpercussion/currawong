// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// Parsing the M17 Project's published reflector host file.
///
/// The samples below are verbatim entries from the real file (fetched
/// 2026-08-16), trimmed to the fields the app reads. Verbatim on purpose: every
/// awkward thing this parser handles is awkward because the real file does it,
/// and a hand-tidied sample would test a file nobody publishes.
final class M17HostFileTests: XCTestCase {
    /// A native M17 reflector: `modules` is an array of letters, and there is a
    /// port.
    func testParsesANativeM17Reflector() throws {
        let reflectors = try M17HostFile.parse(
            Self.hostFile(
                """
                {
                  "designator": "M17-002",
                  "name": null,
                  "dns": null,
                  "ipv4": "89.240.4.99",
                  "modules": ["A"],
                  "encrypted": [],
                  "port": 17000,
                  "sponsor": "cumbriaCQ.com",
                  "country": "GB"
                }
                """))

        let reflector = try XCTUnwrap(reflectors.first)
        XCTAssertEqual(reflector.designator, "M17-002")
        XCTAssertEqual(reflector.host, "89.240.4.99")
        XCTAssertEqual(reflector.port, 17000)
        XCTAssertEqual(reflector.sponsor, "cumbriaCQ.com")
        XCTAssertEqual(reflector.country, "GB")
        XCTAssertEqual(reflector.modules, [ReflectorModule(letter: "A", note: nil)])
        XCTAssertFalse(reflector.isMultiprotocol)

        // `name: null` must not become the string "null" or an empty second
        // half of the title.
        XCTAssertNil(reflector.name)
        XCTAssertEqual(reflector.title, "M17-002")
    }

    /// A URF entry: `modules` is an array of **objects**, and there is **no
    /// port field at all**. Getting this wrong means either failing to decode
    /// the whole file or offering a reflector on port 0.
    func testParsesAMultiprotocolReflectorAndDefaultsItsPort() throws {
        let reflectors = try M17HostFile.parse(Self.hostFile(Self.urfEntry))

        let reflector = try XCTUnwrap(reflectors.first)
        XCTAssertEqual(reflector.designator, "URF018")
        XCTAssertTrue(reflector.isMultiprotocol)
        XCTAssertEqual(
            reflector.port, 17000,
            "a URF entry carries no port; M17's default is the only sensible reading")
    }

    /// The rule that matters most on a bridged reflector: a DMR or D-Star
    /// module is not somewhere an M17 client can go, and offering one would be
    /// a link that fails or, worse, succeeds into silence.
    func testOffersOnlyTheModulesAnM17ClientCanUse() throws {
        let reflectors = try M17HostFile.parse(Self.hostFile(Self.urfEntry))
        let reflector = try XCTUnwrap(reflectors.first)

        XCTAssertEqual(
            reflector.modules.map(\.letter), ["B", "F"],
            "B is transcoding (All) and F is native M17; A, C, D and E are D-Star or DMR")

        XCTAssertEqual(reflector.modules.first?.note, "All modes")
        XCTAssertEqual(reflector.modules.last?.note, "M17")
    }

    /// A bridged reflector with no M17 module on it is not a place this app can
    /// take anybody, so it does not appear in the list at all.
    func testDropsAReflectorWithNoUsableModule() throws {
        let reflectors = try M17HostFile.parse(
            Self.hostFile(
                """
                {
                  "designator": "URF999",
                  "name": "DMR only",
                  "dns": "urf999.example.org",
                  "ipv4": "203.0.113.9",
                  "enabled_modes": ["DMR"],
                  "modules": [
                    { "module": "A", "mode": "DMR", "transcode": false }
                  ]
                }
                """))

        XCTAssertTrue(reflectors.isEmpty)
    }

    /// A host name outlives an address, and the file's own `ipv4` is a cache
    /// refreshed once a day. The resolver on the device is more current.
    func testPrefersTheHostNameOverTheAddress() throws {
        let reflectors = try M17HostFile.parse(
            Self.hostFile(
                """
                {
                  "designator": "M17-AUS",
                  "name": null,
                  "dns": "m17-aus.example.org",
                  "ipv4": "203.0.113.4",
                  "modules": ["A", "B"],
                  "port": 17000,
                  "sponsor": null,
                  "country": "AU"
                }
                """))

        XCTAssertEqual(try XCTUnwrap(reflectors.first).host, "m17-aus.example.org")
    }

    /// One entry in the published list has neither. It is kept rather than
    /// dropped — an operator who knows the reflector exists should find it in
    /// the list and be told why it is not offered, not conclude the search box
    /// is broken.
    func testKeepsAReflectorWithNoAddressButMarksItUndialable() throws {
        let reflectors = try M17HostFile.parse(
            Self.hostFile(
                """
                {
                  "designator": "M17-XYZ",
                  "name": null,
                  "dns": null,
                  "ipv4": null,
                  "modules": ["A"],
                  "port": 17000,
                  "sponsor": null,
                  "country": null
                }
                """))

        let reflector = try XCTUnwrap(reflectors.first)
        XCTAssertEqual(reflector.host, "")
        XCTAssertFalse(reflector.hasDialableHost)
        XCTAssertEqual(reflector.subtitle, "no address listed")
    }

    /// `null` and `""` are used interchangeably in the file for "not given".
    /// Believing the second produces `M17-XYZ ·  · 203.0.113.4`.
    func testTreatsEmptyStringsAsAbsent() throws {
        let reflectors = try M17HostFile.parse(
            Self.hostFile(
                """
                {
                  "designator": "M17-EMP",
                  "name": "",
                  "dns": "   ",
                  "ipv4": "203.0.113.7",
                  "modules": ["A"],
                  "port": 17000,
                  "sponsor": "",
                  "country": ""
                }
                """))

        let reflector = try XCTUnwrap(reflectors.first)
        XCTAssertEqual(reflector.host, "203.0.113.7", "whitespace-only dns is not a host name")
        XCTAssertNil(reflector.sponsor)
        XCTAssertNil(reflector.country)
        XCTAssertEqual(reflector.subtitle, "203.0.113.7")
    }

    /// Both shapes in one array, which is what the real file is.
    func testParsesBothShapesTogether() throws {
        let reflectors = try M17HostFile.parse(
            Self.hostFile(
                """
                {
                  "designator": "M17-002",
                  "name": null, "dns": null, "ipv4": "89.240.4.99",
                  "modules": ["A"], "port": 17000, "sponsor": null, "country": "GB"
                }
                """, Self.urfEntry))

        XCTAssertEqual(reflectors.map(\.designator), ["M17-002", "URF018"])
    }

    func testRejectsSomethingThatIsNotTheHostFile() {
        XCTAssertThrowsError(try M17HostFile.parse(Data("<html>not json</html>".utf8))) { error in
            guard case ReflectorDirectoryError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    /// An empty list parses. It is `ReflectorBrowser` that decides an empty
    /// list is worth complaining about, because that is a judgement about what
    /// to show rather than about the bytes.
    func testAnEmptyListIsNotAParseFailure() throws {
        XCTAssertEqual(try M17HostFile.parse(Data(#"{"reflectors": []}"#.utf8)).count, 0)
    }

    // MARK: - Against the real file

    /// Parses an actual downloaded copy of the host file, when one is pointed
    /// at by `CURRAWONG_M17_HOSTFILE`.
    ///
    /// Skipped otherwise, the way the library's EL-11 conformance test is
    /// skipped without `HAMVOIP_ECHOLINK_STATION_LIST`: the file is a hundred
    /// kilobytes that changes daily, so it is not committed, and no unit test
    /// downloads it. The samples above are the regression test. This is how you
    /// check that the real thing has not changed shape underneath them:
    ///
    /// ```sh
    /// curl -o /tmp/M17Hosts.json https://m17-project.github.io/hostfiles/M17Hosts.json
    /// TEST_RUNNER_CURRAWONG_M17_HOSTFILE=/tmp/M17Hosts.json make test-macos
    /// ```
    ///
    /// The `TEST_RUNNER_` prefix is not decoration: `xcodebuild` does not pass
    /// its own environment to the test process, and it strips that prefix off
    /// what it does inject. Without it the test silently skips, which looks
    /// exactly like passing.
    ///
    /// Last run 2026-08-16 against 125 entries: 101 native, 24 bridged, all
    /// parsed, one with no address.
    func testParsesARealDownloadedHostFile() throws {
        guard let path = ProcessInfo.processInfo.environment["CURRAWONG_M17_HOSTFILE"] else {
            throw XCTSkip("set CURRAWONG_M17_HOSTFILE to a downloaded M17Hosts.json")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let reflectors = try M17HostFile.parse(data)

        XCTAssertGreaterThan(reflectors.count, 50, "the published list has over a hundred entries")

        for reflector in reflectors {
            XCTAssertFalse(reflector.designator.isEmpty)
            XCTAssertFalse(
                reflector.modules.isEmpty,
                "\(reflector.designator) was kept without a usable module")
            XCTAssertGreaterThan(
                reflector.port, 0, "\(reflector.designator) would be dialled on port 0")
            for module in reflector.modules {
                XCTAssertEqual(
                    module.letter.count, 1,
                    "\(reflector.designator) module \(module.letter) is not a letter")
            }
        }

        XCTAssertTrue(
            reflectors.contains { $0.isMultiprotocol },
            "the list carries URF entries; parsing none of them means the object form broke")
        XCTAssertTrue(
            reflectors.contains { !$0.isMultiprotocol },
            "the list is mostly native M17; parsing none means the letter form broke")
    }

    // MARK: - The fetch around the parse

    /// The transport is injected, so the rules about HTTP are testable without
    /// the internet — the same discipline AU-5 imposes on the radio protocols.
    func testASuccessfulFetchParsesWhatItDownloaded() async throws {
        let directory = HostFileReflectorDirectory(url: Self.url) { url in
            (Self.hostFile(Self.urfEntry), Self.response(200, url))
        }

        let reflectors = try await directory.reflectors()
        XCTAssertEqual(reflectors.map(\.designator), ["URF018"])
    }

    /// A 404 from the CDN is not a parse failure, and telling the operator the
    /// file was malformed would point them at the wrong thing entirely.
    func testANonSuccessStatusIsReportedAsUnreachable() async {
        let directory = HostFileReflectorDirectory(url: Self.url) { url in
            (Data("<html>Not Found</html>".utf8), Self.response(404, url))
        }

        do {
            _ = try await directory.reflectors()
            XCTFail("expected the 404 to be reported")
        } catch let error as ReflectorDirectoryError {
            XCTAssertEqual(error, .unreachable(detail: "the server answered 404"))
        } catch {
            XCTFail("expected a ReflectorDirectoryError, got \(error)")
        }
    }

    func testATransportFailureIsReportedAsUnreachable() async {
        struct Offline: Error {}
        let directory = HostFileReflectorDirectory(url: Self.url) { _ in throw Offline() }

        do {
            _ = try await directory.reflectors()
            XCTFail("expected the failure to be reported")
        } catch let error as ReflectorDirectoryError {
            guard case .unreachable = error else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        } catch {
            XCTFail("expected a ReflectorDirectoryError, got \(error)")
        }
    }

    /// Cancellation is not a fault and must not be reported as one — the
    /// browser distinguishes the two, and a `CancellationError` dressed up as
    /// "could not fetch" would put a failure on screen every time the operator
    /// pressed Cancel.
    func testCancellationIsNotDressedUpAsAFailure() async {
        let directory = HostFileReflectorDirectory(url: Self.url) { _ in throw CancellationError() }

        do {
            _ = try await directory.reflectors()
            XCTFail("expected the cancellation to propagate")
        } catch is CancellationError {
            // As intended.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// The published location, pinned. It is the one thing here that cannot be
    /// checked by a test that does not use the network, so at least the URL
    /// itself does not drift unnoticed.
    func testThePublishedLocationIsTheM17ProjectsOwn() {
        XCTAssertEqual(
            M17HostFile.url.absoluteString,
            "https://m17-project.github.io/hostfiles/M17Hosts.json")
    }

    private static let url = URL(string: "https://example.org/M17Hosts.json")!

    private static func response(_ status: Int, _ url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Samples

    /// Verbatim from the published file, trimmed to the fields the app reads.
    /// Five modules across four modes, which is what makes it the useful case.
    private static let urfEntry = """
        {
          "designator": "URF018",
          "name": "REF018",
          "dns": "ref018.dstar.com.br",
          "ipv4": "189.44.229.62",
          "sponsor": "PY2PE",
          "country": "BR",
          "enabled_modes": ["M17", "D-Star (DPlus)", "D-Star (DExtra)", "D-Star (DCS)"],
          "modules": [
            { "module": "A", "slug": "018-module-a", "mode": "D-Star (DCS)", "transcode": false },
            { "module": "B", "slug": "018-module-b", "mode": "All", "transcode": true },
            { "module": "C", "slug": "018-module-c", "mode": "DMR", "transcode": false },
            { "module": "D", "slug": "018-module-d", "mode": "D-Star (DCS)", "transcode": false },
            { "module": "E", "slug": "018-module-e", "mode": "D-Star (DCS)", "transcode": false },
            { "module": "F", "slug": "018-module-f", "mode": "M17", "transcode": false }
          ],
          "network_type": "business",
          "description": ""
        }
        """

    private static func hostFile(_ entries: String...) -> Data {
        Data(
            """
            {
              "_refcheck_metadata": { "filename": "M17Hosts.json" },
              "reflectors": [\(entries.joined(separator: ","))]
            }
            """.utf8)
    }
}
