import CoreGraphics
import Foundation

#if DEBUG
final class ProfilePhotoTestLabServer: @unchecked Sendable {
    private let lock = NSLock()
    private let ownProfileID: UUID
    private let latency: Duration
    private var photos: [UUID: (reference: ProfilePhotoReference, data: Data)] = [:]
    private var hidden: Set<UUID>
    private var reported: Set<UUID> = []

    init(
        ownProfileID: UUID,
        photos: [UUID: Data] = [:],
        hidden: Set<UUID> = [],
        reported: Set<UUID> = [],
        latency: Duration = .milliseconds(600)
    ) {
        self.ownProfileID = ownProfileID
        self.hidden = hidden
        self.reported = reported
        self.latency = latency
        for (owner, data) in photos {
            self.photos[owner] = (ProfilePhotoReference(ownerProfileID: owner, version: UUID()), data)
        }
    }

    func load(_ profileIDs: [UUID]) async throws -> [ProfilePhotoReference] {
        lock.withLock {
            profileIDs.compactMap { id in
                guard id == ownProfileID || (!hidden.contains(id) && !reported.contains(id)) else {
                    return nil
                }
                return photos[id]?.reference
            }
        }
    }

    func own() async throws -> OwnProfilePhoto {
        lock.withLock { OwnProfilePhoto(reference: photos[ownProfileID]?.reference, removedByReview: false) }
    }

    func data(_ reference: ProfilePhotoReference) async throws -> Data {
        try await Task.sleep(for: latency)
        guard let photo = lock.withLock({ photos[reference.ownerProfileID] }),
              photo.reference == reference
        else { throw CompetitionRemoteFailure.notFound }
        return photo.data
    }

    func set(_ jpeg: Data) async throws -> ProfilePhotoReference {
        try await Task.sleep(for: latency)
        let reference = ProfilePhotoReference(ownerProfileID: ownProfileID, version: UUID())
        lock.withLock { photos[ownProfileID] = (reference, jpeg) }
        return reference
    }

    func remove() async throws {
        try await Task.sleep(for: latency)
        _ = lock.withLock { photos.removeValue(forKey: ownProfileID) }
    }

    func report(_ owner: UUID) async throws {
        _ = lock.withLock { reported.insert(owner) }
    }

    func isReported(_ owner: UUID) async -> Bool {
        lock.withLock { reported.contains(owner) }
    }

    static func fixtureJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let side = ProfilePhotoImage.side
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return Data() }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: min(red + 0.25, 1), green: min(green + 0.25, 1), blue: min(blue + 0.25, 1), alpha: 1)
        context.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        guard let image = context.makeImage() else { return Data() }
        return (try? ProfilePhotoImage.jpeg(from: image, crop: CGRect(x: 0, y: 0, width: side, height: side))) ?? Data()
    }
}

import SwiftUI

extension ProfilePhotoTestLabServer {
    @MainActor static func illustratedPortrait(_ variant: Int) -> Data {
        let side = CGFloat(ProfilePhotoImage.side)
        let canvas = Canvas { context, size in
            let background = [Theme.youFill, Theme.stand, Theme.exercise, Theme.move][variant % 4]
            func ellipse(_ rect: CGRect, _ color: Color) {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            ellipse(CGRect(x: -100, y: -170, width: 600, height: 600), Theme.ground.opacity(0.25))
            ellipse(CGRect(x: 70, y: 365, width: 372, height: 320), Theme.ink)
            context.fill(Path(CGRect(x: 225, y: 310, width: 62, height: 95)), with: .color(Theme.ground))
            ellipse(CGRect(x: 137, y: 107, width: 238, height: 260), Theme.ink)
            ellipse(CGRect(x: 151, y: 153, width: 210, height: 222), Theme.ground)
            if variant % 2 == 0 {
                ellipse(CGRect(x: 136, y: 98, width: 163, height: 118), Theme.ink)
                ellipse(CGRect(x: 248, y: 112, width: 126, height: 91), Theme.ink)
            } else {
                ellipse(CGRect(x: 157, y: 97, width: 198, height: 89), Theme.ink)
            }
            ellipse(CGRect(x: 200, y: 249, width: 14, height: 18), Theme.ink)
            ellipse(CGRect(x: 299, y: 249, width: 14, height: 18), Theme.ink)
            if variant > 1 {
                let glassesStyle = StrokeStyle(lineWidth: 7)
                context.stroke(Path(ellipseIn: CGRect(x: 179, y: 228, width: 58, height: 53)), with: .color(Theme.ink), style: glassesStyle)
                context.stroke(Path(ellipseIn: CGRect(x: 277, y: 228, width: 58, height: 53)), with: .color(Theme.ink), style: glassesStyle)
                var bridge = Path()
                bridge.move(to: CGPoint(x: 237, y: 251))
                bridge.addLine(to: CGPoint(x: 277, y: 251))
                context.stroke(bridge, with: .color(Theme.ink), style: glassesStyle)
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 231, y: 315))
            smile.addQuadCurve(to: CGPoint(x: 281, y: 315), control: CGPoint(x: 256, y: 337))
            context.stroke(smile, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { return Data() }
        return (try? ProfilePhotoImage.jpeg(from: cgImage, crop: CGRect(x: 0, y: 0, width: side, height: side))) ?? Data()
    }
}
#endif
