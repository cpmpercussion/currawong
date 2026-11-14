// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a call could not be placed, in the operator's terms.
///
/// The library's errors say what happened on the wire. This says what to
/// check. Where one symptom has several causes the library cannot tell apart,
/// ``advice`` names all of them rather than guessing one.
struct ConnectFailure: Error, Equatable, CustomStringConvertible {
    /// What to check, in a sentence or two.
    let advice: String

    /// The library's own account of the failure, kept for a bug report.
    let detail: String

    var description: String { "\(advice)\n\nDetail: \(detail)." }
}
