//
//  LandmarkTextField.swift
//  BrownSign
//
//  A UIViewRepresentable wrapping UITextField directly, bypassing
//  SwiftUI's TextField/TextEditor entirely. This avoids the gesture
//  conflicts that SwiftUI's text views have inside ScrollView —
//  tap-to-focus, cursor placement, text selection, and the
//  magnifying loupe all work natively because UIKit handles them.
//
//  Includes a keyboard accessory toolbar with a dismiss button (⌨↓)
//  and a search button (magnifying glass).
//

import SwiftUI
import UIKit

struct LandmarkTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSearch: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = "Type landmark text here"
        tf.font = .preferredFont(forTextStyle: .body)
        tf.borderStyle = .none
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .words
        tf.returnKeyType = .search
        tf.clearButtonMode = .never
        tf.delegate = context.coordinator
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged),
            for: .editingChanged
        )
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Keyboard accessory bar
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.tintColor = .tintColor
        let dismiss = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            style: .plain,
            target: context.coordinator,
            action: #selector(Coordinator.dismissTapped)
        )
        let flex = UIBarButtonItem(
            barButtonSystemItem: .flexibleSpace,
            target: nil,
            action: nil
        )
        let search = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            style: .prominent,
            target: context.coordinator,
            action: #selector(Coordinator.searchTapped)
        )
        bar.items = [dismiss, flex, search]
        tf.inputAccessoryView = bar

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: LandmarkTextField
        init(_ parent: LandmarkTextField) { self.parent = parent }

        @objc func textChanged(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSearch()
            return true
        }

        @objc func dismissTapped() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }

        @objc func searchTapped() {
            parent.onSearch()
        }
    }
}
