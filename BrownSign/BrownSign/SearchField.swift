//
//  SearchField.swift
//  BrownSign
//
//  Inline filter text field used under the List/Map picker on Nearby
//  and History. Live, partial-match filtering is handled by the parent
//  via the bound `text` — this view just provides the chrome (icon,
//  placeholder, clear button) and a stable look that matches list
//  insets in both tabs.
//

import SwiftUI

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    /// Tracks whether our TextField owns the keyboard. We attach the
    /// keyboard accessory toolbar conditionally on this so the "Done"
    /// button only appears when the field is the first responder —
    /// otherwise SwiftUI hangs the toolbar over every keyboard in the
    /// scene and clobbers other text inputs.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { isFocused = false }
                .toolbar {
                    if isFocused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { isFocused = false }
                                .fontWeight(.semibold)
                        }
                    }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
