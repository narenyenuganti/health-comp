import CoreGraphics
import Foundation

#if DEBUG
/// The Test Lab's stand-in for the photo server: in memory, with the same
/// rules the app relies on (a hidden or missing photo is simply absent, a
/// report hides that person's photo, a new photo is a new version). Pass its
/// methods to `CompetitionClient`'s photo closures.
final class ProfilePhotoTestLabServer: @unchecked Sendable {
    private let lock = NSLock()
    private let ownProfileID: UUID
    private let latency: Duration
    private var photos: [UUID: (reference: ProfilePhotoReference, data: Data)] = [:]
    /// People whose photo you can't see: blocked either way, or never played.
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

    /// Lands after `latency`, so the fade over the initials can be seen.
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

    /// A solid 512 px fixture photo with a lighter top half, encoded the
    /// way the app encodes uploads.
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
import UIKit

extension ProfilePhotoTestLabServer {
    /// Fictional faces drawn in code; no real person's photo or external asset.
    @MainActor static func illustratedPortrait(_ variant: Int) -> Data {
        let side = CGFloat(ProfilePhotoImage.side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { renderer in
            let context = renderer.cgContext
            let traits = UITraitCollection(userInterfaceStyle: .light)
            func color(_ value: Color) -> CGColor { UIColor(value).resolvedColor(with: traits).cgColor }
            func ellipse(_ rect: CGRect, _ value: Color) {
                context.setFillColor(color(value)); context.fillEllipse(in: rect)
            }
            context.setFillColor(color([Theme.youFill, Theme.stand, Theme.exercise, Theme.move][variant % 4]))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ellipse(CGRect(x: -100, y: -170, width: 600, height: 600), Theme.ground.opacity(0.25))
            ellipse(CGRect(x: 70, y: 365, width: 372, height: 320), Theme.ink)
            context.setFillColor(color(Theme.ground))
            context.fill(CGRect(x: 225, y: 310, width: 62, height: 95))
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
                context.setStrokeColor(color(Theme.ink)); context.setLineWidth(7)
                context.strokeEllipse(in: CGRect(x: 179, y: 228, width: 58, height: 53))
                context.strokeEllipse(in: CGRect(x: 277, y: 228, width: 58, height: 53))
                context.move(to: CGPoint(x: 237, y: 251)); context.addLine(to: CGPoint(x: 277, y: 251)); context.strokePath()
            }
            context.setStrokeColor(color(Theme.ink)); context.setLineWidth(7); context.setLineCap(.round)
            context.move(to: CGPoint(x: 231, y: 315))
            context.addQuadCurve(to: CGPoint(x: 281, y: 315), control: CGPoint(x: 256, y: 337)); context.strokePath()
        }
        guard let cgImage = image.cgImage else { return Data() }
        return (try? ProfilePhotoImage.jpeg(from: cgImage, crop: CGRect(x: 0, y: 0, width: side, height: side))) ?? Data()
    }
}
#endif
