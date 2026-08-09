// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The hand-off between the audio thread and the network client. Its policy —
/// bounded, drop the oldest, count what was dropped — is the difference
/// between a dropout somebody can diagnose and one that gets blamed on the
/// network for weeks.
final class CapturedFrameRelayTests: XCTestCase {
    func testFramesArriveInOrder() async {
        let relay = CapturedFrameRelay()
        for index in 0..<5 {
            relay.submit([Int16(index)])
        }
        relay.finish()

        var received: [Int16] = []
        for await frame in relay.frames {
            received.append(frame[0])
        }

        XCTAssertEqual(received, [0, 1, 2, 3, 4])
        XCTAssertEqual(relay.submittedFrameCount, 5)
        XCTAssertEqual(relay.droppedFrameCount, 0)
    }

    func testOverflowDropsTheOldestAndCountsIt() async {
        let relay = CapturedFrameRelay(capacity: 3)
        for index in 0..<6 {
            relay.submit([Int16(index)])
        }
        relay.finish()

        var received: [Int16] = []
        for await frame in relay.frames {
            received.append(frame[0])
        }

        XCTAssertEqual(received, [3, 4, 5], "the newest audio is what the other operator wants")
        XCTAssertEqual(relay.submittedFrameCount, 6)
        XCTAssertEqual(relay.droppedFrameCount, 3, "a dropout must be a number somebody can read")
    }

    func testFinishEndsTheStream() async {
        let relay = CapturedFrameRelay()
        relay.finish()

        var count = 0
        for await _ in relay.frames { count += 1 }

        XCTAssertEqual(count, 0)
    }
}
