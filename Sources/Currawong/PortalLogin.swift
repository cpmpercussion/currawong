// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - The seam

/// Exchanges an allstarlink.org portal login for a Web Transceiver token, in the
/// app's own vocabulary.
///
/// Mirrors the library's `WebTransceiverTokenSource`, which only
/// `CompositionRoot.swift` may name, and keeps the tests off the network.
protocol PortalLogin: Sendable {
    /// - Parameters:
    ///   - callsign: the portal account's callsign.
    ///   - password: the **portal** password, not a node secret.
    /// - Returns: the token, as the portal returned it.
    /// - Throws: ``PortalLoginFailure``.
    func token(callsign: String, password: String) async throws -> String
}

/// Why a portal login failed, in terms the operator can act on. Library
/// cases that mean the same to them are merged; the mapping is
/// `PortalLoginFailure.init(_:)` in `CompositionRoot`.
enum PortalLoginFailure: Error, Equatable, CustomStringConvertible {
    /// Not accepted. The one case worth re-prompting for.
    case wrongPassword

    /// The endpoint no longer understands the request (OQ-10 caveat 2).
    case endpointChanged

    /// The portal refused for a reason not seen before, carried verbatim.
    case refused(String)

    /// Unreachable, or answered with something other than its JSON.
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

/// The state of "log in to the portal and get a token" (APP-12). A
/// controller, not view state, so the round trip survives the pane going away.
///
/// The password is cleared on success and after a wrong password; other
/// failures keep it for a retry. The token is stable, so nothing re-fetches it.
@MainActor
final class PortalLoginController: ObservableObject {
    /// Typed into the password field.
    @Published var password = ""

    /// Whether a login is in flight.
    @Published private(set) var isWorking = false

    /// The last failure, ready to show. Cleared when another attempt starts.
    @Published private(set) var failure: String?

    /// Whether a login has succeeded this run.
    @Published private(set) var didSucceed = false

    /// `false` when no ``PortalLogin`` was supplied; the pane then offers only
    /// the paste field.
    var isAvailable: Bool { login != nil }

    private let login: (any PortalLogin)?
    private var task: Task<Void, Never>?

    init(login: (any PortalLogin)? = nil) {
        self.login = login
    }

    /// Fetches a token and hands it to `apply`, which is where it is stored.
    ///
    /// - Parameters:
    ///   - callsign: the operator's. An empty one is refused, not sent.
    ///   - apply: receives the token on success. The controller does not store
    ///     it: the Keychain slot has one owner, ``RadioSession``.
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

    /// Abandons a login in flight, keeping the typed password for a retry.
    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    /// Clears the last failure.
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
