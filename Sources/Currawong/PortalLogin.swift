// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - The seam

/// Exchanges an allstarlink.org portal login for a Web Transceiver token, in the
/// app's own vocabulary.
///
/// Mirrors the library's own seam (`WebTransceiverTokenSource`), for the same
/// reason as ``ProxyFinder`` and ``NodeLookup``: a library type may only be
/// named in `CompositionRoot.swift`. Also lets every test here run without a
/// network.
///
/// The token is a plain `String`, since that is all the app does with one:
/// store it in the Keychain and hand it to the library as the calling name
/// (APP-11). ``NodeSettings/isPlausibleWebTransceiverToken(_:)`` is the shape
/// check, and it is advisory.
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
/// Merges library cases the operator would read as identical news: `Invalid
/// JSON payload` and `Invalid JSON fields` both mean the login endpoint has
/// changed and nothing they type will help, where "wrong password" is the one
/// case where re-typing is the answer.
///
/// The mapping from the library's `WebTransceiverTokenError` is the
/// `PortalLoginFailure.init(_:)` extension in `CompositionRoot`, the one file
/// that may name the library type.
enum PortalLoginFailure: Error, Equatable, CustomStringConvertible {
    /// The callsign and password were not accepted. The one case worth
    /// re-prompting for.
    case wrongPassword

    /// The endpoint no longer recognises a request that has not changed
    /// (OQ-10 caveat 2). Nothing the operator types will fix it.
    case endpointChanged

    /// The portal refused for a reason not seen before, carried verbatim.
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
/// A controller rather than view logic, on the same grounds as ``ProxyPicker``:
/// a network round trip that must survive the pane being scrolled away from,
/// whose outcome is a credential that belongs in the Keychain, not `@State`.
///
/// The password is cleared on success and cleared again on failure, never
/// retained: the token is stable across calls (it changes only when the
/// operator changes their portal password), so there is nothing to silently
/// re-fetch, and re-prompting only asks about an event the operator caused.
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

    /// Whether logging in is possible at all. `false` when no ``PortalLogin``
    /// was supplied, in which case the pane offers only the paste field rather
    /// than a button that cannot work.
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
