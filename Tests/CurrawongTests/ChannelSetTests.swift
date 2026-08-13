// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// ``ChannelSet`` is the list arithmetic behind APP-4, pulled out of
/// ``RadioSession`` precisely so it can be tested like this: no view model, no
/// audio device, no clock, no network.
///
/// Two things are worth stating up front, because most of these tests are about
/// one or the other:
///
/// 1. **The selection invariant.** `selectedID` is either `nil` or an id that
///    exists in `channels`. A selection pointing at a deleted channel is the bug
///    this type exists to make unrepresentable.
/// 2. **`nil` is not `[]`.** A channel list that has never been written triggers
///    the migration; one the operator emptied must not.
final class ChannelSetTests: XCTestCase {

    private func channel(_ name: String) -> NodeSettings {
        NodeSettings(
            name: name, host: "\(name.lowercased()).example.org", node: "55553",
            username: "vk1xyz", callsign: "VK1XYZ")
    }

    // MARK: - Migration

    /// **The migration.** An operator updating from a build before APP-4 has
    /// exactly one node under the old key and no channel list at all. It must
    /// come forward as their first channel, selected — the alternative is an
    /// app that appears to have forgotten their node.
    func testALegacySingleNodeBecomesTheFirstChannelAndIsSelected() {
        let legacy = channel("Home")
        let store = InMemorySettingsStore(initial: legacy)

        let set = ChannelSet.loaded(from: store)

        XCTAssertEqual(set.channels, [legacy])
        XCTAssertEqual(set.selectedID, legacy.id)
        XCTAssertEqual(set.selected, legacy)
    }

    /// **`nil` is not `[]`, and this is the test that says so.** An operator who
    /// deleted their last channel has said something; resurrecting the old
    /// single node on the next launch would be the app arguing with them.
    func testAnEmptySavedListDoesNotReRunTheMigration() {
        let legacy = channel("Home")
        // Both keys populated: the legacy node is still on disk — it is never
        // deleted, so a downgrade still finds it — and the channel list is
        // present and empty.
        let store = InMemorySettingsStore(initial: legacy, channels: [])

        let set = ChannelSet.loaded(from: store)

        XCTAssertTrue(set.channels.isEmpty, "an emptied list must stay empty")
        XCTAssertNil(set.selectedID)
        XCTAssertNil(set.selected)
    }

    func testAnEmptyStoreLoadsAnEmptySet() {
        let set = ChannelSet.loaded(from: InMemorySettingsStore())

        XCTAssertTrue(set.channels.isEmpty)
        XCTAssertNil(set.selectedID)
    }

    /// A saved list wins over the legacy key outright. Once the migration has
    /// run, the single-node key is history rather than a second source of truth.
    func testASavedListIsPreferredOverTheLegacyNode() {
        let legacy = channel("Home")
        let saved = [channel("Repeater"), channel("Parrot")]
        let store = InMemorySettingsStore(
            initial: legacy, channels: saved, selectedID: saved[1].id)

        let set = ChannelSet.loaded(from: store)

        XCTAssertEqual(set.channels, saved)
        XCTAssertEqual(set.selectedID, saved[1].id)
    }

    /// A stored selection naming a channel that is no longer in the list — the
    /// list was edited by another build, or the write was interrupted — falls
    /// back to the first channel rather than leaving the app with no channel.
    func testAStaleStoredSelectionFallsBackToTheFirstChannel() {
        let saved = [channel("Repeater"), channel("Parrot")]
        let store = InMemorySettingsStore(channels: saved, selectedID: UUID())

        let set = ChannelSet.loaded(from: store)

        XCTAssertEqual(set.selectedID, saved.first?.id)
    }

    func testSavingWritesBothTheListAndTheSelection() {
        let saved = [channel("Repeater"), channel("Parrot")]
        var set = ChannelSet(channels: saved, selectedID: saved[1].id)
        let store = InMemorySettingsStore()

        set.save(to: store)

        XCTAssertEqual(store.savedChannels, saved)
        XCTAssertEqual(store.savedSelectedID, saved[1].id)

        // And an emptied set writes `[]` rather than nothing at all, which is
        // what stops the next launch from re-running the migration.
        set.remove(saved[0].id)
        set.remove(saved[1].id)
        set.save(to: store)
        XCTAssertEqual(store.savedChannels, [])
        XCTAssertNil(store.savedSelectedID)
    }

    // MARK: - The selection invariant

    func testAnEmptySetHasNoSelection() {
        let set = ChannelSet()

        XCTAssertNil(set.selectedID)
        XCTAssertNil(set.selected)
    }

    /// Constructing a set with a selection that is not in the list cannot be
    /// allowed to produce one — this initialiser is reachable from stored data,
    /// which is not under the app's control.
    func testConstructingWithAnUnknownSelectionRepairsIt() {
        let channels = [channel("Repeater"), channel("Parrot")]

        XCTAssertEqual(
            ChannelSet(channels: channels, selectedID: UUID()).selectedID, channels[0].id)
        XCTAssertEqual(ChannelSet(channels: channels, selectedID: nil).selectedID, channels[0].id)
        XCTAssertNil(ChannelSet(channels: [], selectedID: UUID()).selectedID)
    }

    /// A stale id is ignored rather than clearing the selection. The caller has
    /// an out-of-date reference; dropping the operator's current channel over it
    /// would be worse than doing nothing.
    func testSelectingAnUnknownChannelIsIgnored() {
        let channels = [channel("Repeater"), channel("Parrot")]
        var set = ChannelSet(channels: channels, selectedID: channels[1].id)

        set.select(UUID())

        XCTAssertEqual(set.selectedID, channels[1].id)
    }

    func testSelectingMovesTheSelection() {
        let channels = [channel("Repeater"), channel("Parrot")]
        var set = ChannelSet(channels: channels, selectedID: channels[0].id)

        set.select(channels[1].id)

        XCTAssertEqual(set.selectedID, channels[1].id)
        XCTAssertEqual(set.selected?.name, "Parrot")
    }

    // MARK: - Adding

    /// Adding selects, because adding a channel is something an operator does
    /// in order to use it.
    func testAddingAppendsAndSelects() {
        let first = channel("Repeater")
        var set = ChannelSet(channels: [first], selectedID: first.id)
        let second = channel("Parrot")

        set.add(second)

        XCTAssertEqual(set.channels.map(\.id), [first.id, second.id])
        XCTAssertEqual(set.selectedID, second.id)
    }

    // MARK: - Updating

    /// An edit changes one channel in place. Neither the order nor the
    /// selection may move — an operator renaming the third channel in a list
    /// should not find it has become the first, or the selected one.
    func testUpdateMatchesByIdAndPreservesOrderAndSelection() {
        let channels = [channel("Repeater"), channel("Parrot"), channel("Echo")]
        var set = ChannelSet(channels: channels, selectedID: channels[2].id)

        var edited = channels[1]
        edited.name = "Parrot (renamed)"
        edited.host = "elsewhere.example.org"
        set.update(edited)

        XCTAssertEqual(set.channels.map(\.id), channels.map(\.id), "order must not move")
        XCTAssertEqual(set.channels[1].name, "Parrot (renamed)")
        XCTAssertEqual(set.channels[1].host, "elsewhere.example.org")
        XCTAssertEqual(set.selectedID, channels[2].id, "selection must not move")
    }

    /// A draft whose channel was deleted has nowhere to be written back to, and
    /// silently doing nothing is the right answer — the alternative is
    /// resurrecting a channel the operator removed.
    func testUpdatingAChannelThatIsNotInTheListDoesNothing() {
        let channels = [channel("Repeater")]
        var set = ChannelSet(channels: channels, selectedID: channels[0].id)

        set.update(channel("Never added"))

        XCTAssertEqual(set.channels, channels)
        XCTAssertEqual(set.selectedID, channels[0].id)
    }

    // MARK: - Removing

    /// The selection moves to the channel that took the deleted one's place —
    /// the one below it — so there is still somewhere to be.
    func testRemovingTheSelectedChannelSelectsTheOneBelowIt() {
        let channels = [channel("A"), channel("B"), channel("C")]
        var set = ChannelSet(channels: channels, selectedID: channels[1].id)

        set.remove(channels[1].id)

        XCTAssertEqual(set.channels.map(\.name), ["A", "C"])
        XCTAssertEqual(set.selectedID, channels[2].id, "the neighbour that took its place")
    }

    /// At the end of the list there is nothing below, so the selection moves up
    /// to the new last channel rather than off the end.
    func testRemovingTheLastSelectedChannelSelectsTheNewLastOne() {
        let channels = [channel("A"), channel("B"), channel("C")]
        var set = ChannelSet(channels: channels, selectedID: channels[2].id)

        set.remove(channels[2].id)

        XCTAssertEqual(set.channels.map(\.name), ["A", "B"])
        XCTAssertEqual(set.selectedID, channels[1].id)
    }

    /// Removing something else leaves the selection exactly where it was.
    func testRemovingAnUnselectedChannelLeavesTheSelectionAlone() {
        let channels = [channel("A"), channel("B"), channel("C")]
        var set = ChannelSet(channels: channels, selectedID: channels[2].id)

        set.remove(channels[0].id)

        XCTAssertEqual(set.channels.map(\.name), ["B", "C"])
        XCTAssertEqual(set.selectedID, channels[2].id)
    }

    /// The only state in which there is no selection: no channels to select.
    func testRemovingTheOnlyChannelLeavesNoSelection() {
        let only = channel("A")
        var set = ChannelSet(channels: [only], selectedID: only.id)

        set.remove(only.id)

        XCTAssertTrue(set.channels.isEmpty)
        XCTAssertNil(set.selectedID)
        XCTAssertNil(set.selected)
    }

    func testRemovingAChannelThatIsNotThereDoesNothing() {
        let channels = [channel("A"), channel("B")]
        var set = ChannelSet(channels: channels, selectedID: channels[0].id)

        set.remove(UUID())

        XCTAssertEqual(set.channels, channels)
        XCTAssertEqual(set.selectedID, channels[0].id)
    }

    /// Emptying the list one channel at a time never passes through a state
    /// with a selection that does not exist — the invariant holds at every step,
    /// not merely at the end.
    func testTheSelectionAlwaysExistsWhileTheListIsEmptiedInAnyOrder() {
        let channels = [channel("A"), channel("B"), channel("C")]

        for order in [[0, 1, 2], [2, 1, 0], [1, 0, 2], [1, 2, 0]] {
            var set = ChannelSet(channels: channels, selectedID: channels[1].id)
            for index in order {
                set.remove(channels[index].id)
                if let selectedID = set.selectedID {
                    XCTAssertTrue(
                        set.channels.contains { $0.id == selectedID },
                        "selection escaped the list removing \(order)")
                } else {
                    XCTAssertTrue(
                        set.channels.isEmpty,
                        "the selection may only be nil when there is nothing to select")
                }
            }
        }
    }

    // MARK: - Reordering

    func testMovingReordersWithoutChangingTheSelection() {
        let channels = [channel("A"), channel("B"), channel("C")]
        var set = ChannelSet(channels: channels, selectedID: channels[0].id)

        set.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(set.channels.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(
            set.selectedID, channels[0].id,
            "dragging a row must not change which channel the operator is on")
    }
}
