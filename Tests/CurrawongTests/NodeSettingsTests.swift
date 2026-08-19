// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// ``NodeSettings`` is a pure value, so this is all arithmetic and string
/// handling — no session, no client, no network.
final class NodeSettingsTests: XCTestCase {
    private let good = NodeSettings(
        host: "node.example.org", port: 4569, node: "55553",
        username: "vk1xyz")

    func testAGoodSetOfSettingsValidates() throws {
        XCTAssertEqual(try good.validated(), good)
    }

    func testWhitespaceIsTrimmed() throws {
        // The id is carried over deliberately: a channel's identity survives
        // being edited, so two values that differ only in whitespace must
        // compare equal *after* validation, and they can only do that if they
        // started with the same id.
        let messy = NodeSettings(
            id: good.id,
            host: " node.example.org\n", port: 4569, node: "\t55553 ",
            username: " vk1xyz ")

        XCTAssertEqual(try messy.validated(), good)
    }

    /// Validation must not mint a new identity. A channel that changed id every
    /// time the operator pressed Connect would be added to the list afresh each
    /// time instead of being updated in place.
    func testValidationPreservesTheChannelIdentity() throws {
        XCTAssertEqual(try good.validated().id, good.id)
    }

    func testTheRequiredFieldsAreRequired() {
        var noHost = good
        noHost.host = "   "
        XCTAssertThrowsError(try noHost.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingHost)
        }

        var noNode = good
        noNode.node = ""
        XCTAssertThrowsError(try noNode.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingNode)
        }

        // The callsign is no longer among them: it is app-wide, and
        // `OperatorIdentity.validated()` is what insists on it. See
        // `OperatorIdentityTests`.
    }

    /// A node with no account configured expects no username and no secret,
    /// and the library omits empty fields rather than sending blank ones.
    func testAnEmptyUsernameIsAllowed() throws {
        var anonymous = good
        anonymous.username = ""
        XCTAssertEqual(try anonymous.validated().username, "")
    }

    func testAZeroPortBecomesTheDefault() throws {
        var zeroed = good
        zeroed.port = 0
        XCTAssertEqual(try zeroed.validated().port, NodeSettings.defaultPort)
    }

    func testPortParsing() {
        XCTAssertEqual(NodeSettings.parsePort("4569", for: .allStarLink), 4569)
        XCTAssertEqual(NodeSettings.parsePort(" 4570 ", for: .allStarLink), 4570)
        XCTAssertNil(NodeSettings.parsePort("0", for: .allStarLink))
        XCTAssertNil(NodeSettings.parsePort("70000", for: .allStarLink))
        XCTAssertNil(NodeSettings.parsePort("not a port", for: .allStarLink))
    }

    /// A cleared port field means "this mode's own port", and the three modes do
    /// not share one. Parsing without the mode returned 4569 for all three,
    /// which pointed an EchoLink proxy connection at the IAX2 port.
    func testAClearedPortFieldMeansTheModesOwnDefault() {
        XCTAssertEqual(NodeSettings.parsePort("", for: .allStarLink), 4569)
        XCTAssertEqual(NodeSettings.parsePort("", for: .m17), 17000)
        XCTAssertEqual(NodeSettings.parsePort("", for: .echoLink), 8100)
    }

    /// The identity is stored as typed and only uppercased at `connect()`, so
    /// the account name has to normalise or the two paths disagree: written
    /// under `VK1XYZ`, read back under `vk1xyz`, password apparently forgotten
    /// on every relaunch.
    func testTheSecretAccountIsTheSameWhateverCaseTheCallsignWasTypedIn() {
        var echoLink = good
        echoLink.mode = .echoLink

        let typed = OperatorIdentity(callsign: " vk1xyz ")
        let validated = try? OperatorIdentity(callsign: "vk1xyz").validated()

        XCTAssertEqual(echoLink.secretAccount(for: typed), "echolink:VK1XYZ")
        XCTAssertEqual(
            echoLink.secretAccount(for: typed),
            echoLink.secretAccount(for: validated ?? .empty),
            "the read must land on what the write stored")

        var m17 = good
        m17.mode = .m17
        XCTAssertEqual(
            m17.secretAccount(for: typed), m17.secretAccount(for: validated ?? .empty))
    }

    func testTheSecretAccountIdentifiesTheNodeAndCarriesNoSecret() {
        XCTAssertEqual(good.secretAccount(for: vk1xyz), "vk1xyz@node.example.org:4569/55553")

        var other = good
        other.node = "12345"
        XCTAssertNotEqual(good.secretAccount(for: vk1xyz), other.secretAccount(for: vk1xyz))
    }

    /// The structural guarantee behind "the secret is never in UserDefaults":
    /// the persisted type has no field to put it in.
    ///
    /// Pinned as an exact set rather than a "does not contain" check, so that
    /// adding a field that *should* be a secret fails here rather than passing
    /// quietly. There is no longer a credential-shaped key in the list at all:
    /// `proxyPassword` was the one, and APP-13 moved it to the Keychain.
    func testTheCodableFormHasNoSecretField() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let keys = Set((json as? [String: Any])?.keys.map { $0 } ?? [])

        XCTAssertEqual(
            keys,
            [
                "id", "name", "mode", "host", "port", "node", "module",
                "peer", "directoryServer", "username", "allStarAccess",
            ])
        XCTAssertFalse(
            keys.contains("callsign") || keys.contains("operatorName")
                || keys.contains("location"),
            "callsign, name and location are the operator's and are stored once")
    }

    func testRoundTripsThroughTheDefaultsStore() {
        let defaults = UserDefaults(suiteName: "au.charlesmartin.currawong.tests.\(UUID().uuidString)")!
        let store = UserDefaultsSettingsStore(defaults: defaults)

        XCTAssertNil(store.load())
        store.save(good)
        XCTAssertEqual(store.load(), good)
    }

    // MARK: - Transmit watchdog (SF-1)

    /// **The migration test.** A blob written while the watchdog was still a field
    /// of this type carries a `transmitTimeout` key that the type no longer has.
    /// It must decode as an unknown key rather than as a failure — otherwise
    /// `load()` returns nil and the operator finds their node details wiped by an
    /// app update. What happens to the *value* is
    /// `SettingsStoreTimeoutTests`' business.
    func testATimeoutLeftInAStoredBlobIsIgnoredRatherThanFatal() throws {
        let json = """
            {"host":"node.example.org","port":4569,"node":"55553",\
            "username":"vk1xyz","callsign":"VK1XYZ","transmitTimeout":42}
            """

        let decoded = try JSONDecoder().decode(NodeSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.host, "node.example.org")
        XCTAssertEqual(decoded.node, "55553")
    }

    /// The channel's own name is not part of the node's identity, so renaming it
    /// must not orphan the secret in the Keychain.
    func testRenamingAChannelDoesNotAffectTheKeychainAccount() {
        var renamed = good
        renamed.name = "Sunday net"
        XCTAssertEqual(good.secretAccount(for: vk1xyz), renamed.secretAccount(for: vk1xyz))
    }

    // MARK: - Radio mode (M17)

    /// The operator. App-wide now, so it is a fixture here rather than a field
    /// of each settings value.
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")

    private let m17 = NodeSettings(
        mode: .m17, host: "ref.example.org", port: 17000, module: "A")

    /// **The other migration test.** Settings written before this type had a
    /// mode were written when AllStarLink was all the app could do, so they are
    /// AllStarLink settings — not corrupt ones, and not a wiped node.
    func testSettingsWrittenWithoutAModeDecodeAsAllStarLink() throws {
        let json = """
            {"host":"node.example.org","port":4569,"node":"55553",\
            "username":"vk1xyz","callsign":"VK1XYZ","transmitTimeout":180}
            """

        let decoded = try JSONDecoder().decode(NodeSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.mode, .allStarLink)
        XCTAssertEqual(decoded.module, "")
        // The blob still carries a `callsign`, written before the callsign was
        // hoisted out of this type. It is ignored here rather than failing the
        // decode — the store harvests it once, on the launch after the update.
        // See `SettingsStoreTests`.
        // Compared with the id transplanted rather than field by field: the id
        // is the one thing that cannot match, because a blob written before
        // channels existed has none and is given a fresh one at decode.
        var expected = good
        expected.id = decoded.id
        XCTAssertEqual(decoded, expected)
    }

    /// **Pinned deliberately.** Every secret an operator has already stored is
    /// filed under this exact string; editing the format orphans all of them.
    func testTheAllStarLinkKeychainAccountFormatIsFrozen() {
        XCTAssertEqual(good.secretAccount(for: vk1xyz), "vk1xyz@node.example.org:4569/55553")
    }

    /// An M17 link and an AllStarLink connection to one host are different
    /// entries, and must not be able to name the same Keychain account.
    func testTheKeychainAccountDiffersBetweenModes() {
        var asM17 = good
        asM17.mode = .m17
        asM17.module = "A"

        XCTAssertNotEqual(good.secretAccount(for: vk1xyz), asM17.secretAccount(for: vk1xyz))
    }

    func testTheNodeNumberIsRequiredOnlyInAllStarLinkMode() throws {
        var noNode = good
        noNode.node = ""
        XCTAssertThrowsError(try noNode.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingNode)
        }

        // M17 links a module instead; a node number would be a field the
        // operator fills in for no effect on the wire.
        XCTAssertEqual(try m17.validated().node, "")
    }

    func testTheModuleIsRequiredOnlyInM17Mode() throws {
        var noModule = m17
        noModule.module = "  "
        XCTAssertThrowsError(try noModule.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingModule)
        }

        XCTAssertEqual(try good.validated().module, "")
    }

    func testALowercaseModuleIsNormalisedToUppercase() throws {
        var messy = m17
        messy.module = " b\n"
        XCTAssertEqual(try messy.validated().module, "B")
    }

    func testAModuleThatIsNotASingleLetterIsRejected() {
        for bad in ["AB", "1", "-", "Alpha"] {
            var settings = m17
            settings.module = bad
            XCTAssertThrowsError(try settings.validated(), bad) {
                XCTAssertEqual($0 as? NodeSettings.ValidationError, .invalidModule, bad)
            }
        }
    }

    /// The two modes that dial a host must have one: no host is nowhere to send
    /// to. EchoLink is not among them — it dials an address through an app-wide
    /// proxy and names no host at all (APP-13).
    func testAHostIsRequiredInTheTwoModesThatDialOne() {
        for settings in [good, m17] {
            var noHost = settings
            noHost.host = "   "
            XCTAssertThrowsError(try noHost.validated()) {
                XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingHost)
            }

        }
    }

    // MARK: - Radio mode (EchoLink)

    /// **No host.** The node is `peer` — a literal address, because nothing in
    /// the path resolves a name — and the proxy is app-wide rather than part of
    /// the channel (APP-13).
    private let echoLink = NodeSettings(
        name: "Echo test",
        mode: .echoLink,
        port: 8100,
        node: "*ECHOTEST*",
        peer: "13.57.14.183",
        directoryServer: "192.0.2.1")

    func testAGoodEchoLinkChannelValidates() throws {
        XCTAssertEqual(try echoLink.validated(), echoLink)
    }

    /// The whole reason the station browser exists: an operator cannot be
    /// expected to know a node's current IP address, so an empty `peer` is a
    /// specific complaint rather than a generic "check your settings".
    func testAnEmptyPeerAddressIsRefused() {
        for empty in ["", "   "] {
            var settings = echoLink
            settings.peer = empty
            XCTAssertThrowsError(try settings.validated(), empty) {
                XCTAssertEqual(
                    $0 as? NodeSettings.ValidationError, .missingPeerAddress, empty)
            }
        }
    }

    /// A host name cannot be made to work here by trying harder — the proxy
    /// carries the peer as four raw octets — so it is refused while the operator
    /// is still looking at the field, not later as a failed connection.
    func testAPeerThatIsNotADottedQuadIsRefused() {
        for bad in ["node.example.org", "13.57.14", "13.57.14.183.9", "13.57.14.999", "1.2.3.", "..."]
        {
            var settings = echoLink
            settings.peer = bad
            XCTAssertThrowsError(try settings.validated(), bad) {
                XCTAssertEqual($0 as? NodeSettings.ValidationError, .invalidPeerAddress, bad)
            }
        }
    }

    func testTheDottedQuadRuleMatchesWhatTheLibraryAccepts() {
        XCTAssertTrue(NodeSettings.isDottedQuad("0.0.0.0"))
        XCTAssertTrue(NodeSettings.isDottedQuad("255.255.255.255"))
        XCTAssertTrue(NodeSettings.isDottedQuad("13.57.14.183"))

        XCTAssertFalse(NodeSettings.isDottedQuad("256.0.0.1"), "an octet is 0-255")
        XCTAssertFalse(NodeSettings.isDottedQuad("1.2.3"))
        XCTAssertFalse(NodeSettings.isDottedQuad("1.2.3.4.5"))
        XCTAssertFalse(NodeSettings.isDottedQuad("1.2.3.x"))
        XCTAssertFalse(NodeSettings.isDottedQuad(""))
    }

    /// **Allowed, and it means something.** An empty directory server is "do
    /// not log in to the directory", which is a legitimate experiment: the form
    /// warns about it rather than refusing, because skipping the login only
    /// costs the registration, not the session.
    func testAnEmptyDirectoryServerIsAllowed() throws {
        var settings = echoLink
        settings.directoryServer = "   "
        XCTAssertEqual(try settings.validated().directoryServer, "")
    }

    /// A host name is accepted, and is now what a new EchoLink channel starts
    /// with. The library still takes four octets — the app resolves the name
    /// before it gets there, so the operator does not have to know an address.
    func testAHostNameIsAllowed() throws {
        for good in ["servers.echolink.org", "naeast.echolink.org", "a.b"] {
            var settings = echoLink
            settings.directoryServer = good
            XCTAssertEqual(try settings.validated().directoryServer, good)
        }
    }

    /// Nonsense in the field is a different thing from either. An address with
    /// a dropped or oversized octet is refused here rather than sent to a
    /// resolver that will fail a long way from the typo that caused it — note
    /// `192.0.2`, which is well-formed as a *name* and is caught anyway,
    /// because all-numeric labels are somebody typing an address.
    func testAMalformedDirectoryServerIsRefused() {
        for bad in ["192.0.2", "192.0.2.300", "-lead.example.org", "double..dot.org", "nodots"] {
            var settings = echoLink
            settings.directoryServer = bad
            XCTAssertThrowsError(try settings.validated(), bad) {
                XCTAssertEqual(
                    $0 as? NodeSettings.ValidationError, .invalidDirectoryServer, bad)
            }
        }
    }

    /// **APP-13.** An EchoLink channel names no proxy, and `validated()` is one of
    /// the two places that enforces it. Cleared rather than merely unchecked: a
    /// channel written by a build that did hold a proxy here must not carry it
    /// forward the next time the draft is saved, which is exactly how the old
    /// fault persisted.
    func testValidatingAnEchoLinkChannelClearsAnyProxyItStillCarries() throws {
        var settings = echoLink
        settings.host = "203.0.113.7"
        settings.port = 8100

        let validated = try settings.validated()

        XCTAssertEqual(validated.host, "")
        XCTAssertEqual(validated.port, 8100, "the mode's own port, not a proxy's")
    }

    /// And the host is not demanded of it either — the missing-host complaint
    /// belongs to the two modes that dial one.
    func testAnEchoLinkChannelWithNoHostStillValidates() throws {
        var settings = echoLink
        settings.host = ""

        XCTAssertNoThrow(try settings.validated())
    }

    /// **The EchoLink account form.** Keyed by callsign alone, because the
    /// account password authenticates the *operator* to a directory server —
    /// not this channel to that node. Every EchoLink channel for one callsign
    /// therefore shares an entry, which is what makes deleting a channel unsafe
    /// to pair with deleting its Keychain item; see `RadioSessionChannelTests`.
    func testTheEchoLinkKeychainAccountIsKeyedByCallsignAlone() {
        XCTAssertEqual(echoLink.secretAccount(for: vk1xyz), "echolink:VK1XYZ")

        var elsewhere = echoLink
        elsewhere.host = "other-proxy.example.org"
        elsewhere.peer = "192.0.2.55"
        elsewhere.node = "*ECHOTEST2*"
        XCTAssertEqual(
            echoLink.secretAccount(for: vk1xyz), elsewhere.secretAccount(for: vk1xyz),
            "one account password serves every EchoLink channel for a callsign")
    }

    /// Three modes, three account forms, and no two of them can collide — an
    /// EchoLink channel must never be able to read an AllStarLink node's secret.
    func testTheKeychainAccountDiffersAcrossAllThreeModes() {
        let accounts = Set([good.secretAccount(for: vk1xyz), m17.secretAccount(for: vk1xyz), echoLink.secretAccount(for: vk1xyz)])
        XCTAssertEqual(accounts.count, 3)
    }

    /// An empty port means "this mode's own port", and the mode is what decides
    /// which. Before channels this was always 4569, which would have pointed an
    /// EchoLink session at the IAX2 port.
    func testAnEmptyPortTakesTheModesOwnDefault() throws {
        var echo = echoLink
        echo.port = 0
        XCTAssertEqual(try echo.validated().port, 8100)

        var reflector = m17
        reflector.port = 0
        XCTAssertEqual(try reflector.validated().port, 17000)

        var allStar = good
        allStar.port = 0
        XCTAssertEqual(try allStar.validated().port, 4569)
    }

    // MARK: - Channels (APP-4)

    /// **The third migration test.** A blob written before this type was a
    /// channel has no `id`, no `name` and none of the EchoLink keys. It is one
    /// AllStarLink channel, not a corrupt one — and it must come out with an id,
    /// because everything above `NodeSettings` addresses a channel by id.
    func testAPreChannelBlobStillDecodesAndGetsAnIdentity() throws {
        let json = """
            {"mode":"allStarLink","host":"node.example.org","port":4569,"node":"55553",\
            "module":"","username":"vk1xyz","callsign":"VK1XYZ","transmitTimeout":180}
            """

        let decoded = try JSONDecoder().decode(NodeSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.host, "node.example.org")
        XCTAssertEqual(decoded.name, "")
        XCTAssertEqual(decoded.peer, "")
        XCTAssertEqual(decoded.directoryServer, "")

        // And the id it was given is kept, rather than being re-minted on every
        // decode — otherwise a channel would change identity on every launch.
        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(NodeSettings.self, from: reencoded)
        XCTAssertEqual(again.id, decoded.id)
    }

    /// What the channel list shows. The operator's own name wins; without one,
    /// each mode describes itself with the field that identifies it.
    func testTheDisplayNameFallsBackToWhicheverFieldIdentifiesTheChannel() {
        var named = good
        named.name = "  Home repeater  "
        XCTAssertEqual(named.displayName, "Home repeater")

        XCTAssertEqual(good.displayName, "55553 at node.example.org")
        XCTAssertEqual(m17.displayName, "ref.example.org module A")

        var unnamedEcho = echoLink
        unnamedEcho.name = ""
        XCTAssertEqual(unnamedEcho.displayName, "*ECHOTEST*")

        // An EchoLink channel found by address rather than by callsign has only
        // the address to show.
        unnamedEcho.node = ""
        XCTAssertEqual(unnamedEcho.displayName, "13.57.14.183")
    }

    /// The name is a label, not an identity: renaming a channel must not orphan
    /// its secret or make it a different channel.
    func testRenamingAChannelChangesNeitherItsIdentityNorItsSecretAccount() {
        var renamed = good
        renamed.name = "Something else"

        XCTAssertEqual(renamed.id, good.id)
        XCTAssertEqual(renamed.secretAccount(for: vk1xyz), good.secretAccount(for: vk1xyz))
    }
}
