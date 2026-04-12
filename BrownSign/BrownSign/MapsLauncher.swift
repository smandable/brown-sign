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
import UIKit
import MapKit
import CoreLocation

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
        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}
