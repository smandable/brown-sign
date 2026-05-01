//
//  HiddenLandmarksView.swift
//  BrownSign
//
//  Modal sheet listing landmarks the user has swipe-hidden from the
//  Nearby tab. Mirrors History's interaction model: swipe-to-restore on
//  every row, an Edit/Done button on the trailing toolbar, "Restore
//  All" on the leading toolbar in edit mode (same slot History uses for
//  "Delete All"). Tapping Done after editing also dismisses the sheet —
//  the user's mental model treats this view as an editing card.
//

import SwiftUI
import SwiftData
import UIKit

struct HiddenLandmarksView: View {
    @Query(sort: \HiddenLandmark.dateHidden, order: .reverse)
    private var hidden: [HiddenLandmark]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive
    @State private var showRestoreAllConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if hidden.isEmpty {
                    ContentUnavailableView(
                        "No hidden landmarks",
                        systemImage: "eye",
                        description: Text("Landmarks you hide from Nearby will appear here.")
                    )
                } else {
                    List {
                        ForEach(hidden) { item in
                            // Custom edit-mode affordance: a green eye
                            // button on the leading side replaces the
                            // iOS-default red delete minus that
                            // .onDelete would emit. The action is
                            // restoration, not deletion, so the visual
                            // language has to read "bring back", not
                            // "destroy".
                            HStack(spacing: 12) {
                                if editMode.isEditing {
                                    Button {
                                        restore(item)
                                    } label: {
                                        Image(systemName: "eye.fill")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 22, height: 22)
                                            // Filled brand-green —
                                            // uses AccentButton (more
                                            // saturated) instead of
                                            // AccentColor so the white
                                            // eye keeps proper
                                            // contrast in dark mode.
                                            .background(Circle().fill(Color("AccentButton")))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Restore \(item.title)")
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                }
                                HiddenLandmarkRow(item: item)
                            }
                            .listRowBackground(Color("CardBackground"))
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    restore(item)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(Color("AccentButton"))
                            }
                        }
                    }
                    // Plain style so rows extend full-width within
                    // the padded frame; inset-grouped doubles up
                    // margins with .padding(.horizontal).
                    .listStyle(.plain)
                    .animation(.default, value: editMode.isEditing)
                    // Hide iOS's default page bg and replace with
                    // parchment so the swipe-action area matches the
                    // row color (no seam).
                    .scrollContentBackground(.hidden)
                    .background(Color("CardBackground"))
                    // Round corners so the sheet's list reads as a
                    // parchment card on the system page bg.
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // Match the picker/search field margin used by the
                    // Nearby and History lists so this sheet lines up
                    // visually with the rest of the app.
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Hidden Landmarks")
            .navigationBarTitleDisplayMode(.inline)
            // Apply the editMode binding at the NavigationStack level so
            // BOTH the List rows and the toolbar items share the same
            // state — without this, the EditButton in the toolbar
            // doesn't see the binding and tapping it does nothing.
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Mirrors History's layout: "Restore All" lives in
                    // the same slot as History's "Delete All" — only
                    // visible while editing.
                    if editMode.isEditing && !hidden.isEmpty {
                        // Forest green (app accent) — restore is an
                        // additive, recovery action, not a destructive
                        // one (despite living in the slot History uses
                        // for "Delete All").
                        Button("Restore All") {
                            showRestoreAllConfirmation = true
                        }
                        .tint(Color.accentColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !hidden.isEmpty {
                        Button {
                            if editMode.isEditing {
                                // User finished editing — drop edit
                                // mode and close the sheet so they're
                                // back at the Nearby list, matching
                                // their mental model of this as an
                                // editing card.
                                editMode = .inactive
                                dismiss()
                            } else {
                                withAnimation { editMode = .active }
                            }
                        } label: {
                            if editMode.isEditing {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            } else {
                                Text("Edit")
                            }
                        }
                        .accessibilityLabel(editMode.isEditing ? "Done" : "Edit")
                    }
                }
            }
            .confirmationDialog(
                "Restore all hidden landmarks?",
                isPresented: $showRestoreAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore All") { restoreAll() }
                    .tint(Color.accentColor)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All \(hidden.count) hidden landmarks will reappear in Nearby.")
            }
            // Tint at the dialog's container level too — confirmation
            // dialog buttons render in a system sheet that takes its
            // accent color from the presenting view, not always the
            // per-button tint.
            .tint(Color.accentColor)
        }
    }

    private func restore(_ item: HiddenLandmark) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func restoreAll() {
        for item in hidden {
            modelContext.delete(item)
        }
        try? modelContext.save()
        editMode = .inactive
    }
}

// MARK: - Row

/// Hidden-landmark row — built to look identical to NearbyRow so the
/// "Hidden Landmarks" sheet feels like the same kind of list, just
/// filtered to items the user has set aside. 56pt thumbnail, bold
/// title, two-line summary, and a caption tag for the hide date.
private struct HiddenLandmarkRow: View {
    let item: HiddenLandmark

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Label(
                    "Hidden \(item.dateHidden.formatted(.dateTime.month(.abbreviated).day().year()))",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = item.articleImageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let urlString = item.articleImageURLString,
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    Color.secondary.opacity(0.1)
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.brown.opacity(0.18))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "signpost.right.fill")
                    .font(.title2)
                    .foregroundStyle(.brown)
            }
    }
}
