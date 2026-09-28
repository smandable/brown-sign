//
//  AppModelContainer.swift
//  BrownSign
//
//  The one SwiftData container for the whole process. The phone UI and
//  the CarPlay scene both read it: a cold launch from CarPlay never
//  builds the SwiftUI WindowGroup, so a container owned by
//  `.modelContainer(for:)` wouldn't exist there, and two containers on
//  the same store would each hold their own, diverging view of it.
//

import Foundation
import SwiftData

enum AppModelContainer {
    static let shared: ModelContainer = {
        let schema = Schema([LandmarkLookup.self, HiddenLandmark.self])
        do {
            // Default configuration = the same on-disk store the app has
            // always used, so existing History and hidden landmarks carry over.
            return try ModelContainer(for: schema)
        } catch {
            // A store that won't open (a failed migration, a corrupt file)
            // shouldn't crash-loop the app on every launch. Run this
            // session on an in-memory store instead; the file on disk is
            // left untouched for the next launch to retry.
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Couldn't create even an in-memory model container: \(error)")
            }
        }
    }()
}
