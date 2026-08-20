// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - The seam

/// Exchanges an allstarlink.org portal login for a Web Transceiver token, in the
/// app's own vocabulary.
///
/// The library has this behind its own seam (`WebTransceiverTokenSource`,
/// IAX-13). This protocol exists for the same reason ``ProxyFinder`` and
/// ``NodeLookup`` do: a library type may only be named in
/// `CompositionRoot.swift`, and a view model that named one would put RFC 5456's
/// neighbourhood into the settings screen. It also means every test here runs
/// without a network.
///
/// The token is returned as a `String` rather than a type of its own because
/// that is all the app does with it: store it in the Keychain, and hand it to
/// the library as the calling name (APP-11). ``NodeSettings/isPlausibleWebTransceiverToken(_:)``
/// is the shape check, and it is advisory.
protocol PortalLogin: Sendable {
    /// - Parameters:
    ///   - callsign: portal logins are callsign/password.
    ///   - password: the **portal** password — not a node secret, and not the
    ///     static secret a Web Transceiver call presents.
    /// - Returns: the token, as the portal returned it.
    /// - Throws: ``PortalLoginFailure``.
    func token(callsign: String, password: String) async throws -> String
}

/// Why a portal login failed, in the terms the operator can act on.
///
/// Four cases from the library's five, and the merge is deliberate: `Invalid
/// JSON payload` and `Invalid JSON fields` are the same news to an operator —
/// the login endpoint has changed and nothing they type will help — while
/// "wrong password" is the only one where re-typing is the answer. Keeping them
/// apart in the library and merging them here is the right place for each
/// decision: the library reports what the endpoint said, and the app decides
/// what to do about it.
///
/// The mapping the `CompositionRoot` adapter owes, written down here so it is a
/// decision rather than an improvisation on the day:
///
/// | Library (`WebTransceiverTokenError`) | Here |
/// |---|---|
/// | `.loginFailed` | ``wrongPassword`` |
/// | `.invalidJSONPayload`, `.invalidJSONFields` | ``endpointChanged`` |
/// | `.rejected(message:)` | ``refused(_:)`` with the message |
/// | `.malformedResponse`, `.requestFailed` | ``unreachable(_:)`` |
enum PortalLoginFailure: Error, Equatable, CustomStringConvertible {
    /// The callsign and password were not accepted. The one case worth
    /// re-prompting for.
    case wrongPassword

    /// The endpoint did not recognise a request that has not changed, so the
    /// endpoint has (OQ-10 caveat 2 — AllStarLink has a replacement project
    /// open). Nothing the operator types will fix it.
    case endpointChanged

    /// The portal refused for a reason we have not seen before, carried
    /// verbatim: an uninterpretable message is still the most useful thing to
    /// show somebody.
    case refused(String)

    /// The portal could not be reached, or answered with something that was not
    /// its documented JSON.
    case unreachable(String)

    /// Whether the operator should be asked for their password again.
    var wantsPasswordAgain: Bool { self == .wrongPassword }

    var description: String {
        switch self {
        case .wrongPassword:
            return
                "allstarlink.org did not accept that callsign and password. This is your portal "
                + "login — not a node secret."
        case .endpointChanged:
            return
                "allstarlink.org did not understand the login request, which means its login "
                + "service has changed. Currawong needs an update; a token pasted in by hand "
                + "still works."
        case .refused(let message):
            return "allstarlink.org refused the login: \(message)"
        case .unreachable(let detail):
            return "Could not reach allstarlink.org: \(detail)"
        }
    }
}

// MARK: - The controller

/// The state of "log in to the portal and get a token" (APP-12, pane 1).
///
/// A controller rather than logic in the view, on the same grounds as
/// ``ProxyPicker``: it is a network round trip that must survive the pane being
/// scrolled away from, and its outcome is a credential that has to reach the
/// Keychain rather than a `@State` variable.
///
/// ## The password is not kept
///
/// It is cleared on success, and cleared again when the portal says the login
/// failed. Retaining it would buy a silent re-fetch — and the token is stable
/// across calls, so there is nothing to re-fetch: a token that has stopped
/// working is a token the portal has changed its mind about, and asking again is
/// then the honest thing to do. So the app holds one credential where it could
/// have held two, and the one it holds is the one that is not a login to a web
/// account the operator uses elsewhere.
///
/// AllStarLink have since confirmed *why* the token is stable, which is worth
/// having on the record because this decision rests on it: it changes only when
/// the operator changes their portal password (community thread 24925,
/// 2026-08-18). So the re-prompt above is honest — the one event that
/// invalidates a token is an event the operator performed and can be asked
/// about.
@MainActor
final class PortalLoginController: ObservableObject {
    /// Typed into the password field. Cleared by the controller; see the note
    /// above.
    @Published var password = ""

    /// Whether a login is in flight.
    @Published private(set) var isWorking = false

    /// The last failure, ready to show. Cleared when another attempt starts.
    @Published private(set) var failure: String?

    /// Set when a login has succeeded this run, so the pane can say so without
    /// showing the token twice.
    @Published private(set) var didSucceed = false

    /// Whether logging in is possible at all.
    ///
    /// `false` when no ``PortalLogin`` was supplied, which is how the app ships
    /// until its library dependency carries IAX-13 — see `CompositionRoot`. The
    /// pane then offers only the paste field, rather than a button that cannot
    /// work.
    var isAvailable: Bool { login != nil }

    private let login: (any PortalLogin)?
    private var task: Task<Void, Never>?

    init(login: (any PortalLogin)? = nil) {
        self.login = login
    }

    /// Fetches a token and hands it to `apply`, which is where it is stored.
    ///
    /// - Parameters:
    ///   - callsign: the operator's, from ``OperatorIdentity``. Validated by the
    ///     caller — an empty one is refused here rather than sent.
    ///   - apply: called on the main actor with the token on success. The
    ///     controller deliberately does not store it: the Keychain slot belongs
    ///     to ``RadioSession``, and two owners of one credential is how they
    ///     come to disagree.
    func logIn(callsign: String, apply: @escaping @MainActor (String) -> Void) {
        guard let login, !isWorking else { return }

        let callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callsign.isEmpty else {
            failure = "Enter your callsign first — the portal login is callsign and password."
            return
        }
        guard !password.isEmpty else {
            failure = "Enter your allstarlink.org portal password."
            return
        }

        failure = nil
        didSucceed = false
        isWorking = true
        let password = self.password

        task = Task { [weak self] in
            do {
                let token = try await login.token(callsign: callsign, password: password)
                guard !Task.isCancelled else { return }
                self?.finish(with: token, apply: apply)
            } catch let error as PortalLoginFailure {
                guard !Task.isCancelled else { return }
                self?.fail(with: error)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(with: .unreachable("\(error)"))
            }
        }
    }

    /// Abandons a login in flight. The field keeps what was typed — a cancelled
    /// attempt is usually one about to be retried.
    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    /// Clears the last failure, so a pane can stop showing it once the operator
    /// starts typing again.
    func clearFailure() {
        failure = nil
    }

    private func finish(with token: String, apply: @MainActor (String) -> Void) {
        isWorking = false
        task = nil
        password = ""
        didSucceed = true
        apply(token)
    }

    private func fail(with error: PortalLoginFailure) {
        isWorking = false
        task = nil
        didSucceed = false
        failure = error.description
        if error.wantsPasswordAgain { password = "" }
    }
}
