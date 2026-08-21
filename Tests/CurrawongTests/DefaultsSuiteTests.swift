// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **The UI tests' isolation hook.** These assert on the decision, not on the
/// launch: the arguments themselves are `xcodebuild`'s job, and what can go wrong
/// here is the app reading the operator's defaults when a test asked it not to,
/// or the other way round.
final class DefaultsSuiteTests: XCTestCase {

    /// A stand-in for the argument domain. `UserDefaults(suiteName:)` gives a
    /// real, writable domain, which is what `resolve(reading:)` reads from.
    private var source: UserDefaults!
    private let sourceName = "au.charlesmartin.currawong.tests.source"
    private let targetName = "au.charlesmartin.currawong.tests.target"

    override func setUp() {
        source = UserDefaults(suiteName: sourceName)
        source.removePersistentDomain(forName: sourceName)
        UserDefaults(suiteName: targetName)?.removePersistentDomain(forName: targetName)
    }

    override func tearDown() {
        source.removePersistentDomain(forName: sourceName)
        UserDefaults(suiteName: targetName)?.removePersistentDomain(forName: targetName)
    }

    /// The ordinary launch. Nothing on the command line, so the operator's own
    /// defaults — and this is the assertion that matters most, because the app
    /// silently reading a throwaway suite would look exactly like an operator
    /// losing every channel.
    func testWithNoArgumentTheOperatorsOwnDefaultsAreUsed() {
        XCTAssertEqual(DefaultsSuite.resolve(reading: source), .standard)
    }

    func testAnEmptySuiteNameIsIgnored() {
        source.set("", forKey: DefaultsSuite.suiteArgument)
        XCTAssertEqual(DefaultsSuite.resolve(reading: source), .standard)
    }

    func testANamedSuiteIsUsedInsteadOfStandard() throws {
        source.set(targetName, forKey: DefaultsSuite.suiteArgument)

        let resolved = DefaultsSuite.resolve(reading: source)
        XCTAssertNotEqual(resolved, .standard)

        // Identity by behaviour rather than by pointer: what the app writes has
        // to land in the suite the argument named, and nowhere else.
        resolved.set("landed", forKey: "probe")
        XCTAssertEqual(UserDefaults(suiteName: targetName)?.string(forKey: "probe"), "landed")
        XCTAssertNil(UserDefaults.standard.string(forKey: "probe"))
    }

    /// The reset is the point of the whole thing: a run that died before its
    /// cleanup must not be able to leave a row for the next run to trip over.
    func testTheResetArgumentEmptiesTheSuiteBeforeItIsRead() throws {
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        target.set("left behind", forKey: "leftover")

        source.set(targetName, forKey: DefaultsSuite.suiteArgument)
        source.set(true, forKey: DefaultsSuite.resetArgument)

        let resolved = DefaultsSuite.resolve(reading: source)

        XCTAssertNil(resolved.string(forKey: "leftover"))
    }

    /// Without the reset the suite persists, which is what makes it usable for a
    /// test that wants to launch the app twice and check something survived.
    func testWithoutTheResetArgumentTheSuiteKeepsWhatWasThere() throws {
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        target.set("kept", forKey: "leftover")

        source.set(targetName, forKey: DefaultsSuite.suiteArgument)

        XCTAssertEqual(DefaultsSuite.resolve(reading: source).string(forKey: "leftover"), "kept")
    }
}
