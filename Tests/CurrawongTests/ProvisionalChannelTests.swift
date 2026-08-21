// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-22.** The row for a channel that is not in the list yet.
///
/// APP-19 stopped `Add channel` writing a blank channel to storage, which was
/// right about storage and left the button with no visible effect — the row it
/// used to create was the only feedback it had. The maintainer's call
/// (2026-08-21): the row appears at once, marked "Not saved", and **Save or
/// Connect is still what stores it**. Quit without either and it is gone, exactly
/// as a reflector picked out of the directory is.
@MainActor
final class ProvisionalChannelTests: XCTestCase {
    private let allStar = SessionHarness.goodSettings

    // MARK: - The row exists, and says what it is

    func testANewChannelIsAProvisionalRowStraightAway() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        XCTAssertFalse(harness.session.isDraftAnUnsavedChannel, "precondition")

        harness.session.newChannel()

        XCTAssertTrue(
            harness.session.isDraftAnUnsavedChannel,
            "the list has a row to draw, without anything being stored")
        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id])
        XCTAssertEqual(
            harness.settingsStore.savedChannels?.map(\.id), [allStar.id],
            "and nothing new was written — the harness seeds the store with the list")
    }

    /// A brand-new channel has no name, no host and no node, so `displayName` is
    /// empty. "Unnamed channel" reads as a fault for a row the operator has just
    /// created; the form's own placeholder already says "New channel".
    func testAnEmptyChannelIsCalledNewChannelInTheList() {
        XCTAssertEqual(NodeSettings().listDisplayName, "New channel")
    }

    func testANamedChannelKeepsItsName() {
        var settings = NodeSettings()
        settings.name = "Sunday net"
        XCTAssertEqual(settings.listDisplayName, "Sunday net")
    }

    /// A channel with no name but a destination is described by where it goes,
    /// which is `displayName`'s own rule and must not be overridden.
    func testAnUnnamedChannelWithAHostIsStillDescribedByIt() {
        XCTAssertEqual(allStar.listDisplayName, "55553 at node.example.org")
    }

    /// A directory browse puts the form somewhere that is not in the list either,
    /// so it gets the same row. The state is the same state.
    func testABrowsedReflectorIsAlsoAProvisionalRow() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        var reflector = NodeSettings(mode: .m17, host: "m17-cbr.example.org", port: 17_000)
        reflector.module = "A"

        harness.session.chooseChannel(reflector)

        XCTAssertTrue(harness.session.isDraftAnUnsavedChannel)
    }

    // MARK: - Save is what stores it

    func testSavingTurnsTheProvisionalRowIntoAChannel() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.newChannel()
        harness.session.settings.name = "New one"
        harness.session.settings.host = "typed.example.org"

        harness.session.saveDraft()

        XCTAssertFalse(harness.session.isDraftAnUnsavedChannel, "the row is now an ordinary one")
        XCTAssertEqual(harness.session.channels.channels.count, 2)
        XCTAssertEqual(harness.settingsStore.savedChannels?.count, 2)
    }

    // MARK: - Quitting without saving leaves nothing

    func testAProvisionalRowDoesNotSurviveAQuit() {
        let first = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        first.session.newChannel()
        first.session.settings.host = "half-typed.exam"
        first.session.stashDraft()

        let second = SessionHarness(reusing: first)

        XCTAssertEqual(second.session.channels.channels.map(\.id), [allStar.id])
        XCTAssertFalse(
            second.session.isDraftAnUnsavedChannel,
            "and no provisional row came back with it")
        XCTAssertEqual(second.session.settings.id, allStar.id)
        XCTAssertTrue(second.settingsStore.savedDrafts.isEmpty)
    }

    // MARK: - Discard

    func testDiscardingAProvisionalRowGoesBackToTheSelectedChannel() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.newChannel()
        harness.session.settings.host = "half-typed.exam"

        XCTAssertTrue(harness.session.discardDraftChannel())

        XCTAssertFalse(harness.session.isDraftAnUnsavedChannel)
        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(harness.session.settings, allStar, "and unedited")
        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
    }

    /// Discard is for the provisional row only. A stored channel's row is the
    /// channel, and removing it is Delete's job — so this must not be a second,
    /// quieter way of losing one.
    func testDiscardingDoesNothingWhenTheDraftIsAStoredChannel() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.settings.host = "edited.example.org"

        XCTAssertFalse(harness.session.discardDraftChannel())

        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id])
        XCTAssertEqual(
            harness.session.settings.host, "edited.example.org",
            "and the edit in progress is left alone")
    }

    /// Same rule as selecting, adding and deleting: the form must not be pointed
    /// somewhere else while a call is up.
    func testDiscardingIsRefusedWhileConnected() async {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        await harness.connect()
        // A connect adds the channel it dialled, so make a provisional row the
        // only way that is left: point the draft somewhere new by hand.
        harness.session.settings = NodeSettings()

        XCTAssertFalse(harness.session.discardDraftChannel())
        XCTAssertTrue(harness.session.isDraftAnUnsavedChannel)
    }
}
