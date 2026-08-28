// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-26.** The acknowledgements, tested because two of the four licences
/// make displaying a notice a condition of the right to distribute at all.
///
/// These are not tests of prose. Each one asserts something a licence asks for
/// by name, so that the day somebody tidies the wording, the thing that fails is
/// a test rather than a distribution. The version numbers are checked against
/// the artefacts they describe by `scripts/check-licence-notices.sh`, which is
/// the half of this that a unit test cannot do — a test bundle has no view of
/// `project.yml` or of the XCFramework.
final class AcknowledgementsTests: XCTestCase {

    // MARK: - The set

    func testEveryComponentIsFullyAttributed() {
        XCTAssertFalse(Acknowledgements.components.isEmpty)

        for component in Acknowledgements.components {
            XCTAssertFalse(component.name.isEmpty, "a component with no name")
            XCTAssertFalse(component.version.isEmpty, "\(component.name): no version")
            XCTAssertFalse(component.licence.isEmpty, "\(component.name): no licence")
            XCTAssertFalse(component.copyright.isEmpty, "\(component.name): no copyright")
            XCTAssertFalse(component.notice.isEmpty, "\(component.name): no notice")
            XCTAssertNotNil(
                URL(string: component.sourceURL),
                "\(component.name): \(component.sourceURL) is not a URL")
            XCTAssertTrue(
                component.copyright.lowercased().contains("copyright"),
                "\(component.name): the copyright line does not say copyright")
        }
    }

    func testTheComponentsAreTheThingsTheAppActuallyShips() {
        let names = Set(Acknowledgements.components.map(\.name))

        // The app links the library's four products, the library vendors libgsm
        // for EchoLink, and the app embeds Codec2 for M17. Anything added to
        // `project.yml`'s dependencies belongs here too, and this is the test
        // that notices it was not.
        XCTAssertTrue(names.contains("Currawong"))
        XCTAssertTrue(names.contains("swift-hamvoip"))
        XCTAssertTrue(names.contains("Codec2"))
        XCTAssertTrue(names.contains("libgsm (GSM 06.10)"))

        // swift-argument-parser is *not* here, and that is correct rather than
        // an omission: it is a dependency of the library's `hamvoip-cli`
        // executable target only, and the app depends on RadioCore, IAX2Kit,
        // M17Kit and EchoLinkKit. Acknowledging code we do not ship would be its
        // own small dishonesty.
        XCTAssertFalse(names.contains("swift-argument-parser"))
    }

    func testIdentifiersAreUniqueSoTheListCanBeDisclosedRowByRow() {
        let ids = Acknowledgements.components.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids: \(ids)")
    }

    // MARK: - Codec2, the one with conditions

    private func codec2() throws -> Acknowledgement {
        try XCTUnwrap(Acknowledgements.components.first { $0.name == "Codec2" })
    }

    func testCodec2IsDeclaredLGPLAndDynamicallyLinked() throws {
        let codec2 = try codec2()
        XCTAssertEqual(codec2.licence, "LGPL-2.1")
        // LP-4. The linkage is the whole reason this dependency is shippable, so
        // it is recorded as data rather than left to the prose.
        XCTAssertEqual(codec2.linkage, .dynamicFramework)
    }

    /// LGPL-2.1 §6 wants a notice that the library is used and that the library
    /// and its use are covered by the licence. Both halves.
    func testCodec2NoticeCarriesTheStatementSection6Requires() throws {
        let notice = try codec2().notice
        XCTAssertTrue(
            notice.contains("Currawong uses the Codec2 library"),
            "the notice must say the library is used")
        XCTAssertTrue(
            notice.contains("covered by the GNU Lesser General Public License"),
            "the notice must say the library and its use are covered by the LGPL")
        XCTAssertTrue(
            notice.contains("version 2.1"),
            "the notice must name the version of the licence")
        XCTAssertTrue(
            notice.contains("never statically linked"),
            "LP-4 is a promise to the reader, not only to the build")
        XCTAssertTrue(
            notice.contains("COPYING"),
            "the notice must say where the licence text is")
    }

    /// The LGPL asks for the source that *corresponds* to the binary. A tag is a
    /// name that can be moved; the commit is the thing that cannot.
    func testCodec2NoticeNamesTheExactCommit() throws {
        let commit = Acknowledgements.codec2Commit
        XCTAssertEqual(commit.count, 40, "not a full SHA-1: \(commit)")
        XCTAssertTrue(
            commit.allSatisfy { $0.isHexDigit },
            "not a hexadecimal commit: \(commit)")
        XCTAssertTrue(try codec2().notice.contains(commit))
    }

    /// The point of the whole arrangement: an LGPL library the recipient can
    /// actually replace. If this text goes, the Mac build's licensing rests on
    /// nothing a user is ever told.
    func testTheRelinkingNoticeTellsTheUserHowToSubstituteTheirOwnBuild() {
        let notice = Acknowledgements.relinkingNotice
        XCTAssertTrue(notice.contains("you may replace it with your own build of Codec2"))
        XCTAssertTrue(
            notice.contains("Codec2.framework"),
            "the notice must name the thing to replace")
        XCTAssertTrue(
            notice.contains("codesign"),
            "replacing a framework in a signed app needs a re-sign, and saying so is the difference between a right and a rumour")
        XCTAssertTrue(
            notice.contains("Currawong will use yours"),
            "the notice must state the effect, not only the procedure")
    }

    func testCurrawongIsNotClaimedToBeUnderTheLGPL() throws {
        let currawong = try XCTUnwrap(
            Acknowledgements.components.first { $0.name == "Currawong" })
        XCTAssertEqual(currawong.licence, "Apache-2.0")
        XCTAssertEqual(currawong.linkage, .ourCode)
        // Stated on the Codec2 entry, because that is where a reader would
        // otherwise wonder. §6 permits exactly this and it is worth being
        // explicit about.
        XCTAssertTrue(try codec2().notice.contains("Currawong itself is not covered by the LGPL"))
    }

    // MARK: - libgsm

    func testLibgsmCarriesTheNoticeItsTermsForbidRemoving() throws {
        let gsm = try XCTUnwrap(
            Acknowledgements.components.first { $0.name.hasPrefix("libgsm") })

        // The TU Berlin terms are permissive but conditional: the permission is
        // granted "provided that this notice is not removed". So the notice is
        // the licence, and it must be present verbatim rather than summarised.
        XCTAssertTrue(gsm.notice.contains("this notice is not removed"))
        XCTAssertTrue(gsm.notice.contains("Technische Universitaet Berlin"))
        XCTAssertTrue(gsm.notice.contains("ABSOLUTELY NO WARRANTY"))
        XCTAssertTrue(gsm.copyright.contains("Jutta Degener"))
        XCTAssertTrue(gsm.copyright.contains("Carsten Bormann"))

        // Vendored as source into the library's CGSM target, so it is compiled
        // in. Permissible precisely because the terms are permissive — the same
        // treatment of Codec2 would not be.
        XCTAssertEqual(gsm.linkage, .staticallyLinked)
    }

    // MARK: - The version string

    func testAppVersionIsReadableRatherThanCrashingWithoutABundle() {
        // Reads Bundle.main, which under a test host is the app. The assertion
        // that matters is that it never traps and never returns an empty string,
        // because it is rendered as a headline.
        XCTAssertFalse(Acknowledgements.appVersion.isEmpty)
    }

    func testLibraryVersionLooksLikeAVersion() {
        // The value is checked against `project.yml` by
        // scripts/check-licence-notices.sh; here we only insist it is the kind
        // of string that check can compare.
        let parts = Acknowledgements.libraryVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "expected x.y.z, got \(Acknowledgements.libraryVersion)")
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isNumber) })
    }
}
