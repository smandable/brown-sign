//
//  ScrollViewIntrospection.swift
//  BrownSign
//
//  Resolves the UIScrollView backing a SwiftUI `List` so the Nearby tab can
//  nudge it by a sub-row pixel offset (half a row) on a radius change — a
//  scroll that `List` + `ScrollViewReader.scrollTo` (row-granular) can't
//  express. Self-contained introspection infra; extracted from NearMeView.
//

import SwiftUI
import UIKit

/// Resolves the `UIScrollView` backing the Nearby `List` so a radius increase
/// can nudge the content by an exact pixel offset (half a row) — a sub-row
/// scroll that `List` + `ScrollViewReader.scrollTo` (row-granular) can't
/// express. Placed as a `.background` on the List; it walks up from its marker
/// view and searches each ancestor's subtree for the first scroll view. On a
/// fixed iOS target the collection-view hierarchy is stable enough for this.
/// If it ever fails to resolve, the nudge simply no-ops — the list is otherwise
/// untouched, so scrolling and swipe-to-hide stay fully native.
struct ListScrollViewFinder: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var resolved = false
    }

    func makeUIView(context: Context) -> UIView {
        let marker = UIView(frame: .zero)
        marker.isUserInteractionEnabled = false
        attemptResolve(from: marker, context: context)
        return marker
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attemptResolve(from: uiView, context: context)
    }

    private func attemptResolve(from marker: UIView, context: Context) {
        guard !context.coordinator.resolved else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.resolved,
                  let scrollView = marker.enclosingScrollView() else { return }
            context.coordinator.resolved = true
            onResolve(scrollView)
        }
    }
}

private extension UIView {
    /// Walk up to each ancestor and search its subtree for the first
    /// `UIScrollView` (the List's backing collection view).
    func enclosingScrollView() -> UIScrollView? {
        var ancestor: UIView? = self
        while let current = ancestor {
            if let scrollView = current as? UIScrollView { return scrollView }
            if let scrollView = current.firstScrollViewInSubtree() { return scrollView }
            ancestor = current.superview
        }
        return nil
    }

    func firstScrollViewInSubtree() -> UIScrollView? {
        for subview in subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = subview.firstScrollViewInSubtree() { return nested }
        }
        return nil
    }
}
