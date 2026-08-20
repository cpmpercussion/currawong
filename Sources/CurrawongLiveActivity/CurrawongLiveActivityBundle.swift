// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WidgetKit

/// **SF-4.** The widget extension's entry point.
///
/// One widget, and it is not a home-screen widget: `ActivityConfiguration` makes
/// it a Live Activity, which is the only thing in this bundle. If a second one is
/// ever added, it goes here beside the first.
@main
struct CurrawongLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TransmitActivityWidget()
    }
}
