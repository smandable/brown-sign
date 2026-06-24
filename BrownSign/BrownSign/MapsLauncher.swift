//
//  MapsLauncher.swift
//  BrownSign
//
//  Thin helpers for opening driving directions in the user's preferred
//  maps app. Checks `canOpenURL` for third-party apps so the dialog
//  can hide options the user doesn't have installed.
//
//  NOTE: for `canOpenGoogleMaps` / `canOpenWaze` to ever return true,
//  the schemes `comgooglemaps` and `waze` must be listed in the app's
//  `LSApplicationQueriesSchemes` (Target → Info tab). Without that,
//  iOS sandboxing makes canOpenURL always return false for
//  third-party schemes and only the Apple Maps option will appear.
//

import Foundation
import SwiftUI
import UIKit
import MapKit
import CoreLocation

// MARK: - Directions sheet with inline map preview

/// A compact bottom sheet that shows a MapKit preview of the landmark
/// and buttons for each installed navigation app. Present via
/// `.sheet(isPresented:) { DirectionsSheet(...) }` instead of a plain
/// `.confirmationDialog`, which can't host custom views.
struct DirectionsSheet: View {
    let latitude: Double
    let longitude: Double
    let name: String

    @Environment(\.dismiss) private var dismiss

    /// The sheet's own corner radius.
    private let cardCornerRadius: CGFloat = 22
    /// The inset map preview reads a touch tighter than the sheet at the same
    /// value (the nested-rounded-rect illusion: the corner gap is wider than
    /// the edge gap), so it's bumped a few points to *look* like it matches.
    private let mapPreviewCornerRadius: CGFloat = 24

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        // ScrollView so the action buttons and Cancel stay reachable at
        // accessibility text sizes, where the stack outgrows the fixed
        // 460pt detent and used to clip with no way to scroll.
        ScrollView {
        VStack(spacing: 20) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            ))) {
                Marker(name, coordinate: coordinate)
                    .tint(Color("BrandBrown"))
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: mapPreviewCornerRadius, style: .continuous))
            .allowsHitTesting(false)

            VStack(spacing: 4) {
                Text("Get directions to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                if MapsLauncher.canOpenGoogleMaps {
                    Button {
                        MapsLauncher.openInGoogleMaps(latitude: latitude, longitude: longitude)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "map.fill")
                                .font(.callout)
                            // Product name, not company name — "Google"
                            // alone under a generic map glyph didn't say
                            // what would open.
                            Text("Google Maps")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }

                if MapsLauncher.canOpenWaze {
                    Button {
                        MapsLauncher.openInWaze(latitude: latitude, longitude: longitude)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "location.north.fill")
                                .font(.callout)
                            Text("Waze")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }

                Button {
                    MapsLauncher.openInAppleMaps(latitude: latitude, longitude: longitude)
                    dismiss()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "map")
                            .font(.callout)
                        Text("Apple Maps")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 1)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }

            Button("Cancel", role: .cancel) { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        // A touch more above the map than the sides so it clears the grabber;
        // bottom stays tight since the Cancel row carries its own space.
        .padding(.top, 20)
        .padding(.bottom, 6)
        }
        // .height(460) fits the default text sizes; .large gives
        // accessibility sizes room to expand into, with the ScrollView
        // covering whatever still doesn't fit.
        .presentationDetents([.height(460), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(cardCornerRadius)
    }
}

// MARK: - Launchers

@MainActor
enum MapsLauncher {
    static var canOpenGoogleMaps: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static var canOpenWaze: Bool {
        guard let url = URL(string: "waze://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static func openInGoogleMaps(latitude: Double, longitude: Double) {
        guard let url = URL(
            string: "comgooglemaps://?daddr=\(latitude),\(longitude)&directionsmode=driving"
        ) else { return }
        UIApplication.shared.open(url)
    }

    static func openInWaze(latitude: Double, longitude: Double) {
        guard let url = URL(
            string: "waze://?ll=\(latitude),\(longitude)&navigate=yes"
        ) else { return }
        UIApplication.shared.open(url)
    }

    static func openInAppleMaps(latitude: Double, longitude: Double) {
        // `daddr=lat,lng` + `dirflg=d` is the documented driving-directions
        // form. A `q=` label was previously appended too, but with a
        // coordinate `daddr` (and no `ll`) Apple Maps ignores it, so it was
        // dead weight.
        guard let url = URL(
            string: "https://maps.apple.com/?daddr=\(latitude),\(longitude)&dirflg=d&t=m"
        ) else { return }
        UIApplication.shared.open(url)
    }
}
