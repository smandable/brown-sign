//
//  ListenControls.swift
//  BrownSign
//
//  Listen on the iPhone: the Nearby toolbar's headphones menu (Play
//  nearby, Narrate as I drive, and transport while something plays) and
//  the detail view's Listen button. Both drive the same LandmarkNarrator
//  as CarPlay and Siri.
//

import SwiftUI

/// The Nearby toolbar's Listen menu.
struct NearbyListenMenu: View {
    /// Starts Play nearby from what the list shows. NearMeView decides
    /// between the moving "nearby" program and playing a panned area's
    /// list in order; nil when there's nothing loaded to play.
    let playNearby: (() -> Void)?

    @State private var showLocationAlert = false
    private let narrator = LandmarkNarrator.shared

    var body: some View {
        Menu {
            if let current = narrator.current {
                Section(current.title) {
                    Button {
                        narrator.togglePlayPause()
                    } label: {
                        Label(narrator.isPlaying ? "Pause" : "Resume",
                              systemImage: narrator.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button {
                        narrator.skipToNext()
                    } label: {
                        Label("Next landmark", systemImage: "forward.fill")
                    }
                    Button {
                        narrator.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            } else {
                Button {
                    playNearby?()
                } label: {
                    Label("Play nearby", systemImage: "play.fill")
                }
                .disabled(playNearby == nil)
            }
            Toggle(isOn: Binding(
                get: { narrator.autoNarrationEnabled },
                set: { enabled in
                    if !narrator.setAutoNarration(enabled) { showLocationAlert = true }
                }
            )) {
                Label("Narrate as I drive", systemImage: "car.fill")
            }
        } label: {
            Image(systemName: narrator.isActive || narrator.autoNarrationEnabled ? "headphones.circle.fill" : "headphones")
        }
        .accessibilityLabel("Listen")
        .alert("Location is off", isPresented: $showLocationAlert) {
            Button("Open Settings") { LocationManager.openAppSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Narrate as I drive needs your location to know which landmarks you're approaching.")
        }
    }
}

/// The detail view's Listen button: an outlined 48pt icon button beside
/// Share, matching it. Toggles to pause while this landmark is playing.
struct LandmarkListenButton: View {
    let lookup: LandmarkLookup

    private let narrator = LandmarkNarrator.shared

    private var isThisPlaying: Bool {
        narrator.current?.id == lookup.pageURLString && narrator.isPlaying
    }

    var body: some View {
        Button {
            narrator.toggle(NarrationItem(lookup: lookup))
        } label: {
            Label(isThisPlaying ? "Pause" : "Listen",
                  systemImage: isThisPlaying ? "pause.fill" : "headphones")
                .labelStyle(.iconOnly)
                .frame(width: 48, height: 28)
        }
        .buttonStyle(.bordered)
        .tint(Color("AccentButton"))
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }
}
