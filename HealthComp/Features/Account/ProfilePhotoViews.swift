import SwiftUI

struct ProfilePhoto: Equatable, @unchecked Sendable {
    let version: UUID?
    let image: UIImage

    init?(jpeg: Data, version: UUID?) {
        guard let image = UIImage(data: jpeg)?.preparingForDisplay() else { return nil }
        self.version = version
        self.image = image
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.image === rhs.image
    }
}

struct ProfilePhotoImages: Equatable, Sendable {
    var ownID: UUID?
    var photos: [UUID: ProfilePhoto] = [:]

    func photo(_ owner: UUID?) -> ProfilePhoto? {
        owner.flatMap { photos[$0] }
    }

    var own: ProfilePhoto? { photo(ownID) }
}

extension EnvironmentValues {
    @Entry var profilePhotos = ProfilePhotoImages()
}

extension LocalCompetitionPresentation {
    var opponentProfileID: UUID? {
        RemoteCompetitionOpponentIdentity.profileID(opponentIdentity)
    }
}

struct PersonAvatar: View {
    let name: String
    var photo: UUID? = nil
    let size: CGFloat
    var isYou = false
    var isBot = false
    var initialFont: Font = .headline.weight(.heavy).width(.condensed)

    @Environment(\.profilePhotos) private var photos
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = photos.photo(isYou ? photos.ownID : photo)
        ZStack {
            Text(name.first.map { String($0).uppercased() } ?? "")
                .font(initialFont)
                .lineLimit(1)
                .minimumScaleFactor(0.1)
                .padding(size * 0.15)
                .foregroundStyle(isBot ? Theme.onInk : isYou ? Theme.you : Theme.ink)
            if let shown {
                Image(uiImage: shown.image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .overlay {
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
        .background(isBot ? Theme.ink : Theme.control)
        .clipShape(isBot ? AnyShape(RoundedRectangle(cornerRadius: size * 0.28)) : AnyShape(Circle()))
        .animation(reduceMotion ? nil : Motion.fade, value: shown)
        .accessibilityHidden(true)
    }
}

struct ProfilePhotoCropGeometry: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    let imageSize: CGSize
    let diameter: CGFloat

    var fillScale: CGFloat {
        diameter / max(min(imageSize.width, imageSize.height), 1)
    }

    func displaySize(zoom: CGFloat) -> CGSize {
        CGSize(width: imageSize.width * fillScale * zoom, height: imageSize.height * fillScale * zoom)
    }

    func clamped(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let size = displaySize(zoom: zoom)
        let x = max((size.width - diameter) / 2, 0)
        let y = max((size.height - diameter) / 2, 0)
        return CGSize(width: min(max(offset.width, -x), x), height: min(max(offset.height, -y), y))
    }

    func zooming(_ offset: CGSize, from: CGFloat, to: CGFloat, around anchor: CGPoint = .zero) -> CGSize {
        let ratio = to / from
        return CGSize(
            width: anchor.x - (anchor.x - offset.width) * ratio,
            height: anchor.y - (anchor.y - offset.height) * ratio
        )
    }

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

    static func rubberBand(_ value: CGFloat, to limit: CGFloat) -> CGFloat {
        limit + (value - limit) / 3
    }
}

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
    @State private var releases = 0
    @State private var diameter: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var pan: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = max(min(proxy.size.width, proxy.size.height) - 32, 1)
                circle(side)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .onChange(of: side, initial: true) { _, new in diameter = new }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    if saveFailed || encodeFailed {
                        Text("Couldn’t save your photo. Check your connection and try again.")
                            .font(.callout)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(Motion.appear)
                            .accessibilityIdentifier("account.photo.crop.error")
                    }
                    Text("Friends and people you play can see it, and anyone who finds you in search.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
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
                if pan == .zero { offset = geometry.clamped(offset, zoom: zoom) }
                releases += 1
            }
        let drag = DragGesture()
            .updating($pan) { value, state, _ in state = value.translation }
            .onEnded { value in
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

private struct DecodedPhoto: @unchecked Sendable {
    let image: CGImage
}

private struct ProfilePhotoCropScrim: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -2_000, dy: -2_000))
        path.addEllipse(in: rect)
        return path
    }
}
