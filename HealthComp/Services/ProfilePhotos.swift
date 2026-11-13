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

/// Your own photo as the server has it. `removedByReview`: a reviewer removed
/// the last one; Account says so until you set or remove a photo.
struct OwnProfilePhoto: Equatable, Sendable {
    let reference: ProfilePhotoReference?
    let removedByReview: Bool
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
        let data = try withoutMetadataSegments(output as Data)
        if data.count > maxBytes {
            guard quality > 0.3 else { throw ProfilePhotoFailure.encodingFailed }
            return try jpeg(from: image, crop: crop, quality: quality - 0.2)
        }
        return data
    }

    /// ImageIO always writes its own small Exif (APP1: color space and size)
    /// and an empty Photoshop block (APP13), even for a fresh bitmap. Every
    /// APPn segment but JFIF (APP0) is dropped, so the file is pixels only.
    static func withoutMetadataSegments(_ jpeg: Data) throws -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.starts(with: [0xFF, 0xD8]) else { throw ProfilePhotoFailure.encodingFailed }
        var kept: [UInt8] = [0xFF, 0xD8]
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] != 0xDA {
            let end = index + 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
            guard end <= bytes.count else { throw ProfilePhotoFailure.encodingFailed }
            if !(0xE1...0xEF).contains(bytes[index + 1]) { kept += bytes[index..<end] }
            index = end
        }
        guard index + 1 < bytes.count, bytes[index] == 0xFF, bytes[index + 1] == 0xDA else {
            throw ProfilePhotoFailure.encodingFailed
        }
        return Data(kept + bytes[index...])
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
        latest(owner: owner)?.data
    }

    /// The same, with the version its file name records.
    func latest(owner: UUID) -> (data: Data, version: UUID)? {
        let prefix = owner.uuidString.lowercased().count + 1
        return files(owner: owner).lazy.compactMap { url -> (data: Data, version: UUID)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard let version = UUID(uuidString: String(name.dropFirst(prefix))),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (data, version)
        }.first
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
        let current = Set(references.map { fileURL($0).lastPathComponent })
        let prefixes = Set(owners.map { "\($0.uuidString.lowercased())_" })
        // One listing, not one per owner. Names are `<owner>_<version>.jpg`.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".jpg") && !current.contains(name) {
            guard let separator = name.firstIndex(of: "_"),
                  prefixes.contains(String(name[...separator]))
            else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
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
