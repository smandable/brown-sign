//
//  SafariView.swift
//  BrownSign
//
//  Tiny SFSafariViewController wrapper for SwiftUI sheets.
//

import SwiftUI
import SafariServices

/// SFSafariViewController raises NSInvalidArgumentException — an
/// Objective-C exception, i.e. an uncatchable crash from Swift — for any
/// URL whose scheme isn't http or https. The page URLs presented in the
/// app ultimately come from remote API data (Wikipedia, NPS), so gate on
/// this before presenting.
nonisolated func isSafariPresentableURL(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased()
    return scheme == "http" || scheme == "https"
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        // Clamp rather than trust: a non-web URL falls back to the Wikipedia
        // front page — the wrong page beats a crash. Call sites also gate on
        // isSafariPresentableURL, so the fallback should never actually show.
        SFSafariViewController(
            url: isSafariPresentableURL(url) ? url : URL(string: "https://en.wikipedia.org")!
        )
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
