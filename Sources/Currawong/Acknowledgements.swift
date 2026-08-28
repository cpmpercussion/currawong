// SPDX-License-Identifier: Apache-2.0

import Foundation

/// **APP-26.** What Currawong ships that is not Currawong, and what each licence
/// requires be said about it.
///
/// ## Why this is a value type and not a screen
///
/// Three of the four entries below carry an obligation that is discharged by
/// *displaying* something, and two of those obligations are conditions on the
/// right to distribute at all. That makes the text data rather than decoration:
/// it is asserted in tests (``AcknowledgementsTests``), and the version numbers
/// are cross-checked against the artefacts they describe by
/// `scripts/check-licence-notices.sh`, which CI runs. A licence notice naming
/// the wrong version of the thing it is a notice for is worse than none.
///
/// ## The one that constrains the build
///
/// Codec2 is LGPL-2.1 and everything else here is permissive. `LP-4` resolves
/// that by linking it dynamically and never statically, which is what
/// ``Acknowledgement/Linkage/dynamicFramework`` records — see `docs/LICENSING.md`
/// for the reasoning and `docs/CODEC2.md` for the mechanics. The Mac build
/// distributed outside the App Store additionally makes the substitution the
/// LGPL exists to protect actually performable; ``relinkingNotice`` is the text
/// that says so.
struct Acknowledgement: Identifiable, Equatable {
    var id: String { name }

    /// As the upstream project calls itself.
    let name: String

    /// The exact version shipped, not a range. Checked against the artefact.
    let version: String

    /// Whose copyright it is. Required verbatim by the libgsm terms and by
    /// LGPL-2.1 §1.
    let copyright: String

    /// SPDX identifier, so the string in the UI and the string a tool would
    /// match on are the same string.
    let licence: String

    /// Where the corresponding source is obtainable. For the LGPL component
    /// this is not a courtesy — it is part of how §6 is satisfied.
    let sourceURL: String

    /// How the code reaches the app binary. The distinction is load-bearing for
    /// exactly one entry and harmless for the rest.
    let linkage: Linkage

    /// The notice the licence itself asks for, in the licence's own terms.
    /// Not a paraphrase and not a summary — a paraphrase of a notice is not the
    /// notice.
    let notice: String

    enum Linkage: Equatable {
        /// Ours, under this repository's own licence.
        case ourCode
        /// Compiled into the app binary. Permissible only for permissive terms.
        case staticallyLinked
        /// A separate dynamic framework inside the app bundle, replaceable by
        /// the user. What `LP-4` requires of an LGPL dependency.
        case dynamicFramework

        var description: String {
            switch self {
            case .ourCode: return "Part of Currawong"
            case .staticallyLinked: return "Compiled into the app"
            case .dynamicFramework: return "Dynamically linked framework"
            }
        }
    }
}

/// The list, and the statements that are about the set rather than one member.
enum Acknowledgements {
    /// Currawong's own terms. Stated alongside the rest because "which licence
    /// is the app itself under" is the first question an acknowledgements screen
    /// is opened to answer, and answering it only in a repository nobody has
    /// cloned is not answering it.
    static let apache2SourceURL = "https://github.com/cpmpercussion/currawong"

    /// The version of `swift-hamvoip` this app is built against.
    ///
    /// **Kept in step with `project.yml`'s `from:` by hand**, and that coupling
    /// is checked rather than trusted: `scripts/check-licence-notices.sh` fails
    /// if the two disagree, and CI runs it. There is no runtime way to read an
    /// SPM pin out of a built app, so the alternative to a checked constant is
    /// an unchecked one.
    static let libraryVersion = "0.5.4"

    /// Codec2's version, likewise checked — against `LICENCE-NOTICE.txt` inside
    /// the XCFramework that is actually embedded, which is the artefact this
    /// string makes a claim about.
    static let codec2Version = "1.2.0"

    /// The pinned upstream commit. The LGPL wants the *corresponding* source,
    /// so a tag is not quite enough on a repository where a tag could move.
    static let codec2Commit = "06d4c11e699b0351765f10398abb4f663a984f36"

    static let components: [Acknowledgement] = [
        Acknowledgement(
            name: "Currawong",
            version: appVersion,
            copyright: "Copyright 2026 Currawong contributors",
            licence: "Apache-2.0",
            sourceURL: apache2SourceURL,
            linkage: .ourCode,
            notice: """
                Licensed under the Apache License, Version 2.0. You may not use this file except \
                in compliance with the License. Unless required by applicable law or agreed to in \
                writing, software distributed under the License is distributed on an "AS IS" \
                BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
                """
        ),

        Acknowledgement(
            name: "swift-hamvoip",
            version: libraryVersion,
            copyright: "Copyright 2026 swift-hamvoip contributors",
            licence: "Apache-2.0",
            sourceURL: "https://github.com/cpmpercussion/swift-hamvoip",
            linkage: .staticallyLinked,
            notice: """
                The IAX2, M17 and EchoLink protocol implementations, the audio pipeline and the \
                transmit watchdog. Clean-room implementations from published specifications and \
                the author's own packet captures. Licensed under the Apache License, Version 2.0.
                """
        ),

        // The only entry whose terms shape the build. Everything about how this
        // app links, embeds and signs the framework follows from these three
        // sentences; see `docs/LICENSING.md`.
        Acknowledgement(
            name: "Codec2",
            version: codec2Version,
            copyright: "Copyright (C) David Rowe and contributors",
            licence: "LGPL-2.1",
            sourceURL: "https://github.com/drowe67/codec2",
            linkage: .dynamicFramework,
            notice: """
                Currawong uses the Codec2 library for M17 digital voice, and Codec2 and its use \
                are covered by the GNU Lesser General Public License, version 2.1. Codec2 is \
                linked dynamically and is never statically linked into Currawong. The complete \
                corresponding source for the exact version shipped — commit \
                \(codec2Commit) — is available from the address above, and the full text of the \
                licence is in the COPYING file inside Codec2.framework in this application \
                bundle. Currawong itself is not covered by the LGPL.
                """
        ),

        Acknowledgement(
            name: "libgsm (GSM 06.10)",
            version: "1.0.22",
            copyright: """
                Copyright 1992, 1993, 1994 by Jutta Degener and Carsten Bormann, \
                Technische Universitaet Berlin
                """,
            licence: "TU-Berlin-2.0",
            sourceURL: "http://www.quut.com/gsm/",
            linkage: .staticallyLinked,
            notice: """
                The GSM 06.10 codec EchoLink carries, vendored in swift-hamvoip. Permission to \
                use, copy, modify, and distribute this software for any purpose with or without \
                fee is hereby granted, provided that this notice is not removed and that neither \
                the authors nor the Technische Universitaet Berlin are deemed to have made any \
                representations as to the suitability of this software for any purpose nor are \
                held responsible for any defects of this software. THERE IS ABSOLUTELY NO \
                WARRANTY FOR THIS SOFTWARE.
                """
        ),
    ]

    /// The LGPL-2.1 §6 statement, and the reason it can be made at all for the
    /// Mac build distributed directly rather than through the App Store.
    ///
    /// §6 permits shipping a work that uses the Library as long as the user may
    /// modify the Library and relink, and using a shared library is §6(b)'s own
    /// suggested route. On a directly distributed Mac app the substitution is
    /// performable rather than nominal, and that was measured rather than
    /// assumed on 2026-08-24: replacing the framework and re-signing the
    /// application produces a bundle that launches and uses the replacement.
    /// Replacing the framework *without* re-signing does not — an application's
    /// signature seals its nested code — which is why the text below says so
    /// instead of stopping at "replace the framework".
    ///
    /// This is the part an App Store build could not offer, where the bundle
    /// cannot be modified at all. See `docs/LICENSING.md`.
    static let relinkingNotice = """
        Codec2 is a separate framework inside this application bundle rather than part of \
        Currawong's own binary, so you may replace it with your own build of Codec2 — modified or \
        not — and Currawong will use yours instead. On macOS, replace \
        Currawong.app/Contents/Frameworks/Codec2.framework, re-sign the application \
        (`codesign --force --deep --sign -`), and launch it. The build script that produced the \
        framework shipped here is in the Currawong repository, and the release this application \
        came from carries a copy of the exact Codec2 source it was built from. The re-signing \
        step is part of the procedure rather than an afterthought: an application's signature \
        seals the files nested inside it, so a replaced framework without a re-signed \
        application is a bundle macOS refuses to start.
        """

    /// `CFBundleShortVersionString (CFBundleVersion)`, or a placeholder when
    /// there is no bundle to read — which is the case in some test hosts.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "unknown"
        }
    }
}
