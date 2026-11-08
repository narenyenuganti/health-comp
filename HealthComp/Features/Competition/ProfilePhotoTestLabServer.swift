import CoreGraphics
import Foundation

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
        latency: Duration = .milliseconds(600)
    ) {
        self.ownProfileID = ownProfileID
        self.hidden = hidden
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
