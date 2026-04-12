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

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        VStack(spacing: 20) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            ))) {
                Marker(name, coordinate: coordinate)
                    .tint(.brown)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
                        VStack(spacing: 6) {
                            Image(systemName: "map.fill")
                                .font(.title2)
                            Text("Google")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
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
                        VStack(spacing: 6) {
                            Image(systemName: "location.north.fill")
                                .font(.title2)
                            Text("Waze")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }

                Button {
                    MapsLauncher.openInAppleMaps(latitude: latitude, longitude: longitude, name: name)
                    dismiss()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "map")
                            .font(.title2)
                        Text("Apple")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }

            Button("Cancel", role: .cancel) { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
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

    static func openInAppleMaps(latitude: Double, longitude: Double, name: String) {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(
            string: "https://maps.apple.com/?daddr=\(latitude),\(longitude)&dirflg=d&t=m&q=\(encodedName)"
        ) else { return }
        UIApplication.shared.open(url)
    }
}
