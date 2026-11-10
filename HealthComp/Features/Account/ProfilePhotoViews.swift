import SwiftUI
import UIKit

// MARK: - Photos on screen

/// A decoded photo you may see. A new version is a new value, so it
/// crossfades over the old one.
struct ProfilePhoto: Equatable, @unchecked Sendable {
    /// Nil when it came from this iPhone's cache, before the server said
    /// which version is current.
    let version: UUID?
    let image: UIImage

    /// Decodes ahead of display; call it off the main actor.
    init?(jpeg: Data, version: UUID?) {
        guard let image = UIImage(data: jpeg)?.preparingForDisplay() else { return nil }
        self.version = version
        self.image = image
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.image === rhs.image
    }
}

/// Every photo the signed-in person may see, by profile id. Anyone missing
/// shows their initial. Set once near the root; the default is empty, so a
/// host without it (widgets, previews) draws initials.
struct ProfilePhotoImages: Equatable, Sendable {
    var ownID: UUID?
    var photos: [UUID: ProfilePhoto] = [:]

    func photo(_ owner: UUID?) -> ProfilePhoto? {
        owner.flatMap { photos[$0] }
    }

    var own: ProfilePhoto? { photo(ownID) }
}

private struct ProfilePhotoImagesKey: EnvironmentKey {
    static let defaultValue = ProfilePhotoImages()
}

extension EnvironmentValues {
    var profilePhotos: ProfilePhotoImages {
        get { self[ProfilePhotoImagesKey.self] }
        set { self[ProfilePhotoImagesKey.self] = newValue }
    }
}

extension LocalCompetitionPresentation {
    /// The other person's account, for their photo. Nil for practice,
    /// simulated and pending opponents, who never have one.
    var opponentProfileID: UUID? {
        RemoteCompetitionOpponentIdentity.profileID(opponentIdentity)
    }
}

/// A person's photo in a circle, over the initial that shows until it lands
/// and whenever there is none. `isYou` uses your own photo and adds the
/// amber ring. A photo that arrives after first paint fades in; one already
/// in memory is there on the first frame. Reduce Motion shows it at once.
/// Always hidden from VoiceOver: the name next to it says who it is.
/// A bot is a rounded square and never has a photo or the amber ring.
struct PersonAvatar: View {
    let name: String
    /// Their profile id; ignored when `isYou`.
    var photo: UUID? = nil
    let size: CGFloat
    var isYou = false
    var isBot = false
    /// The initial's font at this call site.
    var initialFont: Font = .headline.weight(.heavy).width(.condensed)

    @Environment(\.profilePhotos) private var photos
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = photos.photo(isYou ? photos.ownID : photo)
        ZStack {
            Text(name.first.map { String($0).uppercased() } ?? "")
                .font(initialFont)
                .foregroundStyle(isYou ? Theme.you : Theme.ink)
            if let shown {
                Image(uiImage: shown.image)
                    // A toolbar would tint it otherwise.
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .overlay {
                        // Amber is always you; theirs keeps a pale photo's edge.
                        Circle().strokeBorder(
                            isYou ? Theme.youFill : Theme.ink.opacity(0.1),
                            lineWidth: isYou ? 2 : 1
                        )
                    }
                    .id(shown.version)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.control)
        .clipShape(isBot ? AnyShape(RoundedRectangle(cornerRadius: size * 0.28)) : AnyShape(Circle()))
        .animation(reduceMotion ? nil : Motion.fade, value: shown)
        .accessibilityHidden(true)
    }
}

// MARK: - Move and Scale

/// Move and Scale's math in points. `offset` is the photo's centre from the
/// circle's; `zoom` 1 is aspect fill.
struct ProfilePhotoCropGeometry: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    /// The upright photo, in pixels.
    let imageSize: CGSize
    let diameter: CGFloat

    /// Points per pixel at 1×: the short side fills the circle.
    var fillScale: CGFloat {
        diameter / max(min(imageSize.width, imageSize.height), 1)
    }

    func displaySize(zoom: CGFloat) -> CGSize {
        CGSize(width: imageSize.width * fillScale * zoom, height: imageSize.height * fillScale * zoom)
    }

    /// The nearest offset where the photo still covers the circle.
    func clamped(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let size = displaySize(zoom: zoom)
        let x = max((size.width - diameter) / 2, 0)
        let y = max((size.height - diameter) / 2, 0)
        return CGSize(width: min(max(offset.width, -x), x), height: min(max(offset.height, -y), y))
    }

    /// The offset after zooming `from` → `to`, keeping the photo point at
    /// `anchor` (from the circle's centre) still. Not clamped.
    func zooming(_ offset: CGSize, from: CGFloat, to: CGFloat, around anchor: CGPoint = .zero) -> CGSize {
        let ratio = to / from
        return CGSize(
            width: anchor.x - (anchor.x - offset.width) * ratio,
            height: anchor.y - (anchor.y - offset.height) * ratio
        )
    }

    /// The square under the circle, in the photo's pixels, origin top left:
    /// what `ProfilePhotoImage.jpeg(from:crop:)` takes.
    func cropRect(offset: CGSize, zoom: CGFloat) -> CGRect {
        let scale = fillScale * zoom
        let side = diameter / scale
        return CGRect(
            x: imageSize.width / 2 - offset.width / scale - side / 2,
            y: imageSize.height / 2 - offset.height / scale - side / 2,
            width: side,
            height: side
        )
    }

    /// Past a limit the photo follows at a third of the finger.
    static func rubberBand(_ value: CGFloat, to limit: CGFloat) -> CGFloat {
        limit + (value - limit) / 3
    }
}

/// Black and full screen after the picker closes: pinch and drag inside the
/// circle, then Save. It stays up until the upload lands.
struct ProfilePhotoCropView: View {
    let load: @Sendable () async throws -> Data
    let isSaving: Bool
    let saveFailed: Bool
    let save: (Data) -> Void
    let cancel: () -> Void
    let chooseAnother: () -> Void

    @State private var image: CGImage?
    @State private var loadFailed = false
    @State private var encodeFailed = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Bumped on every release, so the settle runs through `moving`.
    @State private var releases = 0
    /// The circle as laid out, for Save.
    @State private var diameter: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var pan: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = max(proxy.size.width - 32, 1)
                VStack(spacing: 12) {
                    Spacer(minLength: 16)
                    circle(side)
                    Spacer(minLength: 16)
                    if saveFailed || encodeFailed {
                        Text("Couldn’t save your photo. Check your connection and try again.")
                            .font(.callout)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(Motion.appear)
                            .accessibilityIdentifier("account.photo.crop.error")
                    }
                    Text("Only people you play can see it.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: side, initial: true) { _, new in diameter = new }
            }
            .background(Color.black)
            .clipped()
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("account.photo.crop.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: saveTapped) {
                        BusyLabel("Save", isBusy: isSaving)
                    }
                    .disabled(image == nil || isSaving)
                    .accessibilityValue(isSaving ? "Saving" : "")
                    .accessibilityIdentifier("account.photo.crop.save")
                }
            }
        }
        // Always on black, like the system's own crop.
        .environment(\.colorScheme, .dark)
        .tint(Theme.ink)
        .task { await loadImage() }
    }

    @ViewBuilder
    private func circle(_ diameter: CGFloat) -> some View {
        ZStack {
            if let image {
                let geometry = ProfilePhotoCropGeometry(
                    imageSize: CGSize(width: image.width, height: image.height),
                    diameter: diameter
                )
                let shownZoom = liveZoom
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(
                        width: geometry.displaySize(zoom: shownZoom).width,
                        height: geometry.displaySize(zoom: shownZoom).height
                    )
                    .offset(liveOffset(geometry, zoom: shownZoom))
                    .moving(Motion.settle, value: releases)
                    .frame(width: diameter, height: diameter)
                    .contentShape(Rectangle())
                    .gesture(gestures(geometry))
                    .accessibilityElement()
                    .accessibilityLabel("Photo crop")
                    .accessibilityValue("\(Int((zoom * 100).rounded())) percent")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: setZoom(zoom + 0.25, geometry)
                        case .decrement: setZoom(zoom - 0.25, geometry)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: "Center") {
                        offset = .zero
                        releases += 1
                    }
                    .accessibilityIdentifier("account.photo.crop")
            } else if loadFailed {
                VStack(spacing: 16) {
                    Text("Couldn’t open that photo. Choose another one.")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose Another", action: chooseAnother)
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 240)
                        .accessibilityIdentifier("account.photo.crop.choose-another")
                }
                .padding(32)
            } else {
                // iCloud originals can take a while.
                ProgressView("Loading photo…")
                    .foregroundStyle(Theme.secondary)
                    .tint(Theme.ink)
                    .waitingFade()
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            ZStack {
                ProfilePhotoCropScrim()
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Circle().stroke(Color.white.opacity(0.6), lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var liveZoom: CGFloat {
        let raw = zoom * pinch
        let range = ProfilePhotoCropGeometry.zoomRange
        if raw < range.lowerBound { return ProfilePhotoCropGeometry.rubberBand(raw, to: range.lowerBound) }
        if raw > range.upperBound { return ProfilePhotoCropGeometry.rubberBand(raw, to: range.upperBound) }
        return raw
    }

    private func liveOffset(_ geometry: ProfilePhotoCropGeometry, zoom shownZoom: CGFloat) -> CGSize {
        let zoomed = geometry.zooming(offset, from: zoom, to: shownZoom)
        let raw = CGSize(width: zoomed.width + pan.width, height: zoomed.height + pan.height)
        let held = geometry.clamped(raw, zoom: shownZoom)
        return CGSize(
            width: ProfilePhotoCropGeometry.rubberBand(raw.width, to: held.width),
            height: ProfilePhotoCropGeometry.rubberBand(raw.height, to: held.height)
        )
    }

    private func gestures(_ geometry: ProfilePhotoCropGeometry) -> some Gesture {
        let magnify = MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                let range = ProfilePhotoCropGeometry.zoomRange
                let next = min(max(zoom * value.magnification, range.lowerBound), range.upperBound)
                offset = geometry.zooming(offset, from: zoom, to: next)
                zoom = next
                // A drag still running settles when it lets go.
                if pan == .zero { offset = geometry.clamped(offset, zoom: zoom) }
                releases += 1
            }
        let drag = DragGesture()
            .updating($pan) { value, state, _ in state = value.translation }
            .onEnded { value in
                // While a pinch runs, the pan is in its zoomed points.
                offset.width += value.translation.width / pinch
                offset.height += value.translation.height / pinch
                if pinch == 1 { offset = geometry.clamped(offset, zoom: zoom) }
                releases += 1
            }
        let doubleTap = SpatialTapGesture(count: 2)
            .onEnded { value in
                let anchor = CGPoint(
                    x: value.location.x - geometry.diameter / 2,
                    y: value.location.y - geometry.diameter / 2
                )
                let next: CGFloat = zoom < 2 ? 2 : 1
                offset = geometry.clamped(
                    geometry.zooming(offset, from: zoom, to: next, around: anchor),
                    zoom: next
                )
                zoom = next
                releases += 1
            }
        return SimultaneousGesture(SimultaneousGesture(magnify, drag), doubleTap)
    }

    private func setZoom(_ value: CGFloat, _ geometry: ProfilePhotoCropGeometry) {
        let range = ProfilePhotoCropGeometry.zoomRange
        let next = min(max(value, range.lowerBound), range.upperBound)
        offset = geometry.clamped(geometry.zooming(offset, from: zoom, to: next), zoom: next)
        zoom = next
        releases += 1
    }

    private func loadImage() async {
        do {
            let data = try await load()
            image = try await Task.detached(priority: .userInitiated) {
                DecodedPhoto(image: try ProfilePhotoImage.uprightImage(from: data))
            }.value.image
        } catch {
            loadFailed = true
        }
    }

    private func saveTapped() {
        guard let image else { return }
        let geometry = ProfilePhotoCropGeometry(
            imageSize: CGSize(width: image.width, height: image.height),
            diameter: diameter
        )
        do {
            encodeFailed = false
            save(try ProfilePhotoImage.jpeg(from: image, crop: geometry.cropRect(offset: offset, zoom: zoom)))
        } catch {
            encodeFailed = true
        }
    }
}

/// Carries a decoded photo off the decoding task. CGImage is immutable.
private struct DecodedPhoto: @unchecked Sendable {
    let image: CGImage
}

/// Everything but the circle, for an even-odd fill. Reaches far past its
/// frame, so the photo dims outside the circle up to the screen's edges.
private struct ProfilePhotoCropScrim: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -2_000, dy: -2_000))
        path.addEllipse(in: rect)
        return path
    }
}
