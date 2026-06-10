//
//  BrownSignWidgets.swift
//  BrownSignWidgets
//
//  The app's first widget extension. Currently holds only the scan
//  control; Home Screen widgets would join this bundle (bundle order
//  = gallery order).
//

import WidgetKit
import SwiftUI

@main
struct BrownSignWidgets: WidgetBundle {
    var body: some Widget {
        ScanSignControl()
    }
}

/// Control Center / Lock Screen / Action button control that opens
/// the app straight into the scan camera — the launcher for the
/// app's most time-critical moment: the sign sliding past.
///
/// `ScanSignIntent` is compiled into both the app and this
/// extension (the system requires dual membership to open the app);
/// its `perform()` runs in the app process and drives AppRouter.
struct ScanSignControl: ControlWidget {
    static let kind = "com.seanmandable.brownsign.scan-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ScanSignIntent()) {
                Label("Scan a Sign", systemImage: "camera.viewfinder")
            }
        }
        .displayName("Scan a Sign")
        .description("Open the camera to scan a roadside sign.")
    }
}
