// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// The presentation is a pure function of the state, so it is testable without
/// a view, a client or a network — which is the point of it being a separate
/// type.
final class TransmitStatusPresentationTests: XCTestCase {
    func testIdleIsNotTransmitting() {
        let status = TransmitStatusPresentation(state: .idle)
        XCTAssertFalse(status.isTransmitting)
        XCTAssertEqual(status.label, "Not connected")
    }

    func testReceivingIsNotTransmitting() {
        let status = TransmitStatusPresentation(state: .receiving)
        XCTAssertFalse(status.isTransmitting)
        XCTAssertEqual(status.label, "Receiving")
    }

    /// The one that matters: anything that is on air must report itself as on
    /// air, whatever the associated value. SF-4 hangs off this flag.
    func testTransmittingIsTransmittingRegardlessOfStartTime() {
        for date in [Date(), Date(timeIntervalSince1970: 0), Date.distantPast] {
            let status = TransmitStatusPresentation(state: .transmitting(since: date))
            XCTAssertTrue(status.isTransmitting, "transmitting(since: \(date)) must read as on air")
            XCTAssertEqual(status.label, "Transmitting")
        }
    }

    func testEveryStateProducesNonEmptyText() {
        let states: [TransmitState] = [.idle, .receiving, .transmitting(since: Date())]
        for state in states {
            let status = TransmitStatusPresentation(state: state)
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertFalse(status.detail.isEmpty)
        }
    }
}
