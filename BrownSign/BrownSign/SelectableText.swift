//
//  SelectableText.swift
//  BrownSign
//
//  A read-only text view with full iOS text selection: tap to place
//  cursor, double-tap to select a word, triple-tap for paragraph,
//  long-press for the magnifying loupe, drag handles to adjust, copy.
//
//  Backed by UITextView (isEditable=false, isSelectable=true) via
//  UIViewRepresentable, since SwiftUI's Text + .textSelection(.enabled)
//  only supports long-press selection, not tap/drag.
//

import SwiftUI
import UIKit

extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

struct SelectableText: UIViewRepresentable {
    let text: String
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var color: UIColor = .label
    var lineLimit: Int = 0  // 0 = unlimited

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(tv)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        configure(uiView)
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 375
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: fitting.height)
    }

    private func configure(_ tv: UITextView) {
        if tv.text != text { tv.text = text }
        tv.font = font
        tv.textColor = color
        tv.textContainer.maximumNumberOfLines = lineLimit
        tv.textContainer.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
    }
}
