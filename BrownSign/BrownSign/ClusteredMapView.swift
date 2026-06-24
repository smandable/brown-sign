//
//  ClusteredMapView.swift
//  BrownSign
//
//  Shared MKMapView wrapper used by both the Nearby and History maps.
//  Replaces the SwiftUI `Map` so we get native annotation clustering
//  (MKMarkerAnnotationView.clusteringIdentifier) with a custom brown
//  numbered bubble, and — the reason for the rewrite — cluster-tap to
//  ZOOM INTO the cluster's members (MKClusterAnnotation.memberAnnotations
//  → showAnnotations).
//
//  Chrome stays in SwiftUI: the callout card, loading pill, and zoom/
//  radius control are overlaid by the parent. The map only reports a
//  selected landmark id (binding) and end-of-USER-gesture pan centers
//  (so Nearby can refetch), with the programmatic-vs-user pan filter
//  ported from the old SwiftUI map's pendingProgrammaticMoves counter.
//

import SwiftUI
import MapKit
import UIKit

// MARK: - Annotation

/// One landmark pin. Carries the source object's id so a tap can be mapped
/// back to the LandmarkResult / LandmarkLookup the parent owns.
final class LandmarkAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(id: String, coordinate: CLLocationCoordinate2D, title: String?) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
    }
}

// MARK: - Cluster bubble

/// Custom view for an `MKClusterAnnotation`: a brown bubble (MapClusterBubble)
/// with a white ring and the member count, its size scaling with the count.
final class ClusterBubbleView: MKAnnotationView {
    static let reuseID = "cluster"

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let count = cluster.memberAnnotations.count
        let diameter = Self.diameter(for: count)
        image = Self.bubbleImage(count: count, diameter: diameter)
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        centerOffset = .zero
        // Circular collision so neighbouring bubbles don't overlap-jitter.
        collisionMode = .circle
        // Soft halo.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        displayPriority = .defaultHigh
        // Tapping a cluster zooms into its members (handled in didSelect), so
        // don't pop a native callout.
        canShowCallout = false
    }

    /// Bubble diameter grows in steps with the member count.
    private static func diameter(for count: Int) -> CGFloat {
        switch count {
        case ..<10: return 40
        case ..<50: return 48
        case ..<100: return 56
        default: return 66
        }
    }

    private static func bubbleImage(count: Int, diameter d: CGFloat) -> UIImage {
        let ring: CGFloat = 2.5
        let brown = UIColor(named: "MapClusterBubble")
            ?? UIColor(red: 0.420, green: 0.271, blue: 0.149, alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: d, height: d))
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: d, height: d).insetBy(dx: ring / 2, dy: ring / 2)
            cg.setFillColor(brown.cgColor)
            cg.fillEllipse(in: rect)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(ring)
            cg.strokeEllipse(in: rect)

            let text = count > 999 ? "999+" : "\(count)"
            let fontSize: CGFloat = count < 100 ? d * 0.40 : d * 0.30
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let ns = text as NSString
            let size = ns.size(withAttributes: attrs)
            ns.draw(
                at: CGPoint(x: (d - size.width) / 2, y: (d - size.height) / 2),
                withAttributes: attrs
            )
        }
    }
}

// MARK: - Map

struct ClusteredMapView: UIViewRepresentable {
    /// The landmark pins to show. Diffed by id so the map isn't torn down
    /// each update.
    var annotations: [LandmarkAnnotation]
    /// Selected landmark id. Set when a single pin is tapped (drives the
    /// parent's callout card); cleared by the parent when the card is
    /// dismissed, which deselects the pin here.
    @Binding var selectedID: String?
    /// Region the map opens on (set once, on first layout).
    var initialRegion: MKCoordinateRegion
    /// Bump to recenter. When it changes, the map animates to
    /// `recenterRegion` (or fits all annotations if nil).
    var recenterToken: Int = 0
    var recenterRegion: MKCoordinateRegion? = nil
    /// Region the lower-left "locate me" button jumps to — the user at the
    /// current radius (Nearby) or all pins (History). Used INSTEAD of the
    /// current zoom, so recentering after zooming into a cluster doesn't keep
    /// that extreme zoom.
    var recenterTarget: MKCoordinateRegion? = nil
    /// Called at the end of a USER pan/zoom gesture with the new center.
    /// Programmatic moves (initial fit, recenter, cluster-tap zoom) are
    /// filtered out. Nil on maps that don't refetch (History).
    var onUserPan: ((CLLocationCoordinate2D) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true

        // Detect genuine user pan/zoom so the programmatic-vs-user filter is
        // robust: a user gesture ALWAYS reports + resets the counter (mirroring
        // the old map's positionedByUser), so a programmatic setRegion that
        // produces no regionDidChange can't leave the counter stuck and swallow
        // the next real pan. Non-blocking — they recognize simultaneously with
        // the map's own gestures.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.userGestured))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.userGestured))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: Coordinator.pinReuseID)
        map.register(ClusterBubbleView.self,
                     forAnnotationViewWithReuseIdentifier: ClusterBubbleView.reuseID)

        // Custom recenter-on-me button, top-trailing. A single programmatic
        // recenter on the user (keeping the current zoom) — counter-bumped so
        // it never reads as a user pan, so no refetch and no follow-mode. Styled
        // to match the white map controls.
        context.coordinator.mapView = map
        let recenter = UIButton(type: .system)
        recenter.setImage(
            UIImage(systemName: "dot.scope",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)),
            for: .normal
        )
        recenter.tintColor = .label
        recenter.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        recenter.layer.cornerRadius = 12
        recenter.layer.borderWidth = 0.5
        recenter.layer.borderColor = UIColor.label.withAlphaComponent(0.08).cgColor
        recenter.layer.shadowColor = UIColor.black.cgColor
        recenter.layer.shadowOpacity = 0.15
        recenter.layer.shadowRadius = 4
        recenter.layer.shadowOffset = CGSize(width: 0, height: 2)
        recenter.translatesAutoresizingMaskIntoConstraints = false
        recenter.accessibilityLabel = "Recenter on my location"
        recenter.addTarget(context.coordinator,
                           action: #selector(Coordinator.recenterTapped),
                           for: .touchUpInside)
        map.addSubview(recenter)
        context.coordinator.recenterButton = recenter
        NSLayoutConstraint.activate([
            recenter.widthAnchor.constraint(equalToConstant: 44),
            recenter.heightAnchor.constraint(equalToConstant: 44),
            recenter.leadingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            // Lower-left, raised off the bottom to clear the Apple Maps
            // attribution that sits in the bottom-left corner.
            recenter.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        ])

        // First-layout region; the counter swallows the resulting
        // regionDidChange so it isn't reported as a user pan.
        context.coordinator.programmaticMoves += 1
        map.setRegion(initialRegion, animated: false)
        context.coordinator.addAnnotations(annotations, to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.syncAnnotations(annotations, on: map)
        coord.syncSelection(selectedID, on: map)
        coord.handleRecenter(token: recenterToken, region: recenterRegion, on: map)
        // Hide the recenter button while a callout card is up (the card sits at
        // the bottom and would otherwise cover it), mirroring the zoom control.
        coord.recenterButton?.isHidden = selectedID != nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        static let pinReuseID = "landmark"

        /// The redesign mock's hand-drawn signpost glyph: a thin tall post with
        /// a small board pointing LEFT up top and a small board pointing RIGHT
        /// lower down. SF Symbol `signpost.right.and.left.fill` is the same idea
        /// but Apple draws the boards much wider and level; this matches the
        /// mock's narrower, staggered look. Paths transcribed straight from the
        /// mock SVG (24×24 viewBox); rendered white (alwaysOriginal) so it stays
        /// white on the brown marker balloon. Built once, reused per pin.
        static let signpostGlyph: UIImage = {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
            let image = renderer.image { _ in
                UIColor.white.setFill()
                // Post: <rect x=11 y=2 w=2 h=20 rx=1>
                UIBezierPath(
                    roundedRect: CGRect(x: 11, y: 2, width: 2, height: 20),
                    cornerRadius: 1
                ).fill()
                // Left board: M11 5 H4 L1.6 7.4 4 9.8 H11 Z
                let left = UIBezierPath()
                left.move(to: CGPoint(x: 11, y: 5))
                left.addLine(to: CGPoint(x: 4, y: 5))
                left.addLine(to: CGPoint(x: 1.6, y: 7.4))
                left.addLine(to: CGPoint(x: 4, y: 9.8))
                left.addLine(to: CGPoint(x: 11, y: 9.8))
                left.close()
                left.fill()
                // Right board: M13 11 H20 L22.4 13.4 20 15.8 H13 Z
                let right = UIBezierPath()
                right.move(to: CGPoint(x: 13, y: 11))
                right.addLine(to: CGPoint(x: 20, y: 11))
                right.addLine(to: CGPoint(x: 22.4, y: 13.4))
                right.addLine(to: CGPoint(x: 20, y: 15.8))
                right.addLine(to: CGPoint(x: 13, y: 15.8))
                right.close()
                right.fill()
            }
            return image.withRenderingMode(.alwaysOriginal)
        }()

        var parent: ClusteredMapView
        /// Count of programmatic camera moves whose settling
        /// `regionDidChangeAnimated` hasn't been consumed yet — the ported
        /// pan-vs-user filter, so the initial fit / recenter / cluster zoom
        /// never masquerade as a user pan and fire a spurious refetch.
        var programmaticMoves = 0
        /// Set while a user pan/pinch is in progress, so the settle is always
        /// reported as a user move regardless of the counter.
        private var userIsInteracting = false
        private var lastRecenterToken = 0
        /// Weak ref to the map, so the recenter button's action can drive it.
        weak var mapView: MKMapView?
        /// Weak ref to the recenter button, so it can hide behind a callout card.
        weak var recenterButton: UIButton?
        /// id → annotation, so diffing and selection are O(1).
        private var annotationByID: [String: LandmarkAnnotation] = [:]

        init(_ parent: ClusteredMapView) {
            self.parent = parent
            self.lastRecenterToken = parent.recenterToken
        }

        // MARK: annotation diffing

        func addAnnotations(_ items: [LandmarkAnnotation], to map: MKMapView) {
            annotationByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            map.addAnnotations(items)
        }

        func syncAnnotations(_ items: [LandmarkAnnotation], on map: MKMapView) {
            let newByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let newIDs = Set(newByID.keys)
            let oldIDs = Set(annotationByID.keys)
            guard newIDs != oldIDs else { return }

            let removed = annotationByID.filter { !newIDs.contains($0.key) }.map { $0.value }
            let added = newByID.filter { !oldIDs.contains($0.key) }.map { $0.value }
            if !removed.isEmpty { map.removeAnnotations(removed) }
            if !added.isEmpty { map.addAnnotations(added) }
            annotationByID = newByID
        }

        // MARK: selection

        func syncSelection(_ id: String?, on map: MKMapView) {
            // Parent cleared the selection (card dismissed) — deselect on the map.
            if id == nil {
                for selected in map.selectedAnnotations where selected is LandmarkAnnotation {
                    map.deselectAnnotation(selected, animated: true)
                }
            }
        }

        // MARK: recenter

        func handleRecenter(token: Int, region: MKCoordinateRegion?, on map: MKMapView) {
            guard token != lastRecenterToken else { return }
            lastRecenterToken = token
            programmaticMoves += 1
            if let region {
                map.setRegion(region, animated: true)
            } else {
                fitAll(on: map)
            }
        }

        private func fitAll(on map: MKMapView) {
            let pins = map.annotations.filter { $0 is LandmarkAnnotation }
            if pins.isEmpty {
                map.setRegion(parent.initialRegion, animated: true)
            } else {
                map.showAnnotations(pins, animated: true)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // System user-location dot.
            if annotation is MKUserLocation { return nil }

            if annotation is MKClusterAnnotation {
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: ClusterBubbleView.reuseID, for: annotation
                )
            }

            guard annotation is LandmarkAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.pinReuseID, for: annotation
            ) as! MKMarkerAnnotationView
            // Brown signpost teardrop, clustered with its siblings. Plain
            // BrandBrown by Sean's call (the balloon + white glyph carry
            // legibility on the dark map).
            view.clusteringIdentifier = "landmark"
            view.markerTintColor = UIColor(named: "BrandBrown")
            // Custom narrow staggered signpost drawn to match the redesign
            // mock (Apple's signpost.right.and.left.fill is wider/level).
            view.glyphImage = Self.signpostGlyph
            // .defaultHigh, not .defaultLow: low priority kept pins clustered
            // too aggressively (they wouldn't split when zoomed). High priority
            // still clusters genuinely-overlapping pins but declusters as soon
            // as there's room.
            view.displayPriority = .defaultHigh
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                // Tap a cluster → zoom IN tight to its members so they split
                // into individual pins. showAnnotations padded too generously
                // and left close members still clustered; this fits them with
                // only light padding, floored so co-located members still land
                // at a useful street-level zoom (truly identical coords can't
                // separate and stay a cluster, which is correct).
                mapView.deselectAnnotation(cluster, animated: false)
                let coords = cluster.memberAnnotations.map(\.coordinate)
                let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
                let center = CLLocationCoordinate2D(
                    latitude: (lats.min()! + lats.max()!) / 2,
                    longitude: (lons.min()! + lons.max()!) / 2
                )
                let span = MKCoordinateSpan(
                    latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.0008),
                    longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.0008)
                )
                programmaticMoves += 1
                mapView.setRegion(MKCoordinateRegion(center: center, span: span), animated: true)
            } else if let landmark = view.annotation as? LandmarkAnnotation {
                parent.selectedID = landmark.id
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            // User tapped away from a single pin — clear the parent's card,
            // unless the selection already moved to another annotation.
            if view.annotation is LandmarkAnnotation,
               mapView.selectedAnnotations.isEmpty,
               parent.selectedID != nil {
                parent.selectedID = nil
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // A real user gesture always reports and clears any stale pending
            // count (belt and braces, like the old positionedByUser path).
            // Otherwise swallow one programmatic settle; if none is pending,
            // report (covers a programmatic move that produced no settle).
            if userIsInteracting {
                userIsInteracting = false
                programmaticMoves = 0
                parent.onUserPan?(mapView.region.center)
            } else if programmaticMoves > 0 {
                programmaticMoves -= 1
            } else {
                parent.onUserPan?(mapView.region.center)
            }
        }

        @objc func userGestured(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began { userIsInteracting = true }
        }

        @objc func recenterTapped() {
            guard let map = mapView else { return }
            // Bump the counter so the settle isn't reported as a user pan.
            programmaticMoves += 1
            if let target = parent.recenterTarget {
                // Reset to the radius (Nearby) / all-pins (History) overview —
                // NOT the current zoom, which may be a deep cluster zoom.
                map.setRegion(target, animated: true)
            } else if let loc = map.userLocation.location {
                map.setRegion(
                    MKCoordinateRegion(center: loc.coordinate, span: map.region.span),
                    animated: true
                )
            }
        }

        // Our detection gestures must not block MKMapView's own pan/pinch.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
