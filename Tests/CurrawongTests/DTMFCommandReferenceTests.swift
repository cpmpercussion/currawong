// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The reference sheet is static text, so these tests are about the shape of
/// the table rather than any behaviour: an operator reading a wrong code off
/// this list sends a wrong command to a live node, and nothing downstream will
/// catch it for them.
final class DTMFCommandReferenceTests: XCTestCase {

    private typealias Reference = DTMFCommandReference

    func testEveryCodeStartsWithTheFunctionStartCharacter() {
        for command in Reference.commands {
            XCTAssertTrue(
                command.code.hasPrefix("*"),
                "\(command.code) does not start with the function start character")
        }
    }

    func testCodesAreUnique() {
        let codes = Reference.commands.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "duplicate code in the table")
    }

    /// The node's decoder takes **the first match**, so a code that is a prefix
    /// of a longer one makes the longer one unreachable — the manual calls this
    /// out directly. A table that listed both would be documenting a command
    /// that cannot fire.
    func testNoCodeIsAPrefixOfAnother() {
        for command in Reference.commands {
            for other in Reference.commands where other.code != command.code {
                XCTAssertFalse(
                    other.code.hasPrefix(command.code),
                    "\(command.code) shadows \(other.code): the decoder would never reach the longer code")
            }
        }
    }

    func testEverySummaryIsPresent() {
        for command in Reference.commands {
            XCTAssertFalse(
                command.summary.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(command.code) has no summary")
        }
    }

    /// The four link commands are the whole reason the sheet exists, and the
    /// pairing of code to meaning is the part that must not drift. `*2` and
    /// `*3` in particular are the two it would be worst to swap: one of them
    /// puts you on air into the far node and the other does not.
    func testLinkCommandsCarryTheDocumentedMeanings() {
        XCTAssertEqual(summary(of: "*3"), "Connect — transceive (two-way)")
        XCTAssertEqual(
            summary(of: "*2"), "Connect — monitor only (you hear it, it does not hear you)")
        XCTAssertEqual(summary(of: "*1"), "Disconnect")
        XCTAssertEqual(summary(of: "*4"), "Enter command mode on a remote node")
    }

    func testLinkCommandsTakeANodeArgumentAndStatusCommandsDoNot() {
        for code in ["*1", "*2", "*3", "*4", "*75"] {
            XCTAssertEqual(command(code)?.argument, "node", "\(code) should take a node number")
        }
        for code in ["*70", "*71", "*73", "*80", "*81", "*980"] {
            XCTAssertNil(command(code)?.argument, "\(code) should take no argument")
        }
    }

    func testMandatoryCommandsAreTheOnesEveryNodeShouldHave() {
        let mandatory = Set(Reference.commands(.mandatory).map(\.code))
        XCTAssertEqual(mandatory, ["*1", "*2", "*3", "*4", "*70", "*99"])
    }

    /// Availability partitions the table — a command that fell out of both
    /// groups would be invisible in the sheet while still passing every test
    /// above.
    func testAvailabilityPartitionsTheTable() {
        let grouped = Reference.commands(.mandatory) + Reference.commands(.optional)
        XCTAssertEqual(
            Set(grouped.map(\.code)), Set(Reference.commands.map(\.code)),
            "a command belongs to neither group and would not be shown")
        XCTAssertEqual(grouped.count, Reference.commands.count)
    }

    /// `*` is the first character of every code here, and VoiceOver reads it as
    /// punctuation or skips it. This reuses ``DTMF/spoken(_:)``, the same fix
    /// the keypad already needed.
    func testSpokenLabelsSayStarAndNameTheArgument() {
        XCTAssertEqual(command("*3")?.spoken, "star 3, followed by node")
        XCTAssertEqual(command("*70")?.spoken, "star 7 0")
    }

    func testThereAreOperatingNotes() {
        XCTAssertFalse(Reference.notes.isEmpty)
        for note in Reference.notes {
            XCTAssertFalse(note.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func command(_ code: String) -> Reference.Command? {
        Reference.commands.first { $0.code == code }
    }

    private func summary(of code: String) -> String? {
        command(code)?.summary
    }
}
