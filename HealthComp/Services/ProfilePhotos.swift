import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One stored photo: `<owner>/<version>.jpg` in the private `profile-photos`
/// bucket. A new photo always gets a new version, so a version's bytes never
/// change and can be cached for good.
struct ProfilePhotoReference: Hashable, Sendable {
    let ownerProfileID: UUID
    let version: UUID

    var objectPath: String {
        "\(ownerProfileID.uuidString.lowercased())/\(version.uuidString.lowercased()).jpg"
    }
}

enum ProfilePhotoFailure: Error, Equatable, Sendable {
    case unreadableImage
    case invalidCrop
    case encodingFailed
}

/// Turns a picked photo into the only shape the app uploads: a 512 px square
/// JPEG with no metadata. The pixels are redrawn into a fresh bitmap, so
/// nothing from the original file (EXIF, GPS, TIFF, IPTC, XMP, maker notes)
/// can reach the encoder.
enum ProfilePhotoImage {
    static let side = 512
    /// The bucket's limit (migration 2900).
    static let maxBytes = 512 * 1024

    /// The picked file, decoded upright and at most `maxPixelSize` on its long
    /// side, so a huge photo never sits in memory at full size. Crop
    /// rectangles are in this image's pixels.
    static func uprightImage(from data: Data, maxPixelSize: Int = 2048) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { throw ProfilePhotoFailure.unreadableImage }
        return image
    }

    /// `crop` is the square under the circle, in `image`'s pixels (origin top
    /// left). Whatever of it lies outside the image is ignored.
    static func jpeg(from image: CGImage, crop: CGRect, quality: CGFloat = 0.8) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = crop.standardized.intersection(bounds).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cropped = image.cropping(to: rect)
        else { throw ProfilePhotoFailure.invalidCrop }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw ProfilePhotoFailure.encodingFailed }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let square = context.makeImage() else { throw ProfilePhotoFailure.encodingFailed }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ProfilePhotoFailure.encodingFailed }
        CGImageDestinationAddImage(destination, square, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageMetadataShouldExcludeGPS: true,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProfilePhotoFailure.encodingFailed }
        let data = output as Data
        if data.count > maxBytes {
            guard quality > 0.3 else { throw ProfilePhotoFailure.encodingFailed }
            return try jpeg(from: image, crop: crop, quality: quality - 0.2)
        }
        return data
    }

    /// Only what this app would have uploaded is decoded for display: one
    /// JPEG frame, at most 512 px a side, within the bucket's size limit.
    static func isAcceptableDownload(_ data: Data) -> Bool {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return (1...side).contains(width) && (1...side).contains(height)
    }
}

/// Photos on disk for the signed-in account, under its
/// `AuthenticatedProfileStorage` root, so sign-out and account deletion
/// remove them with everything else. Files are `<owner>_<version>.jpg`;
/// `<owner>.reported` marks a person whose photo you reported here.
struct ProfilePhotoCache: Sendable {
    let directory: URL

    func data(for reference: ProfilePhotoReference) -> Data? {
        try? Data(contentsOf: fileURL(reference))
    }

    /// Any cached version of this person's photo, without the network.
    func latestData(owner: UUID) -> Data? {
        files(owner: owner).lazy.compactMap { try? Data(contentsOf: $0) }.first
    }

    /// Keeps only this version of the owner's photo.
    func store(_ data: Data, for reference: ProfilePhotoReference) throws {
        try data.write(to: fileURL(reference), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        for file in files(owner: reference.ownerProfileID) where file != fileURL(reference) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func remove(owner: UUID) {
        for file in files(owner: owner) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// After a lookup of `owners`: drops every cached photo that is no longer
    /// the visible version (removed, changed, blocked or reported).
    func retain(_ references: [ProfilePhotoReference], among owners: [UUID]) {
        let current = Set(references.map { fileURL($0) })
        for owner in owners {
            for file in files(owner: owner) where !current.contains(file) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func markReported(owner: UUID) throws {
        try Data().write(to: reportedURL(owner), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func isReported(owner: UUID) -> Bool {
        FileManager.default.fileExists(atPath: reportedURL(owner).path)
    }

    private func fileURL(_ reference: ProfilePhotoReference) -> URL {
        directory.appendingPathComponent(
            "\(reference.ownerProfileID.uuidString.lowercased())_\(reference.version.uuidString.lowercased()).jpg"
        )
    }

    private func reportedURL(_ owner: UUID) -> URL {
        directory.appendingPathComponent("\(owner.uuidString.lowercased()).reported")
    }

    private func files(owner: UUID) -> [URL] {
        let prefix = "\(owner.uuidString.lowercased())_"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
}
