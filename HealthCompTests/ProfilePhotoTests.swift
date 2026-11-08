import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HealthComp

final class ProfilePhotoImageTests: XCTestCase {
    func testCropIsRedrawnAs512PixelJPEGWithNoMetadata() throws {
        let original = try Self.photo(width: 1200, height: 900, orientation: 1)
        let image = try ProfilePhotoImage.uprightImage(from: original)
        let jpeg = try ProfilePhotoImage.jpeg(from: image, crop: CGRect(x: 300, y: 50, width: 800, height: 800))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 512)
        XCTAssertLessThanOrEqual(jpeg.count, ProfilePhotoImage.maxBytes)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        XCTAssertNil(properties[kCGImagePropertyMakerAppleDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        XCTAssertNil(exif[kCGImagePropertyExifLensModel])
        let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] } ?? []
        XCTAssertEqual(tags.count, 0, "no XMP or other metadata tags")
        // No APP1 (EXIF, XMP) or APP13 (IPTC) segment at all, and none of the
        // original's strings.
        let markers = try Self.segmentMarkers(jpeg)
        XCTAssertFalse(markers.contains(0xE1), "APP1 present: \(markers)")
        XCTAssertFalse(markers.contains(0xED), "APP13 present: \(markers)")
        for secret in ["HealthCompTestCamera", "secret-comment", "Somewhere"] {
            XCTAssertNil(jpeg.range(of: Data(secret.utf8)), secret)
        }
        // The original really carried them, so the checks above mean something.
        let input = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil)), 0, nil
        ) as? [CFString: Any])
        XCTAssertNotNil(input[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(input[kCGImagePropertyTIFFDictionary])
        XCTAssertTrue(ProfilePhotoImage.isAcceptableDownload(jpeg))
    }

    func testUprightImageAppliesOrientationAndBoundsSize() throws {
        let rotated = try Self.photo(width: 1200, height: 900, orientation: 6)
        let image = try ProfilePhotoImage.uprightImage(from: rotated, maxPixelSize: 600)
        XCTAssertEqual(image.width, 450)
        XCTAssertEqual(image.height, 600)
    }

    func testCropOutsideTheImageIsRejectedAndPartialCropIsClamped() throws {
        let image = try ProfilePhotoImage.uprightImage(from: try Self.photo(width: 400, height: 400, orientation: 1))
        XCTAssertThrowsError(try ProfilePhotoImage.jpeg(from: image, crop: CGRect(x: 500, y: 500, width: 100, height: 100))) {
            XCTAssertEqual($0 as? ProfilePhotoFailure, .invalidCrop)
        }
        let clamped = try ProfilePhotoImage.jpeg(from: image, crop: CGRect(x: -50, y: -50, width: 300, height: 300))
        XCTAssertTrue(ProfilePhotoImage.isAcceptableDownload(clamped))
        XCTAssertThrowsError(try ProfilePhotoImage.uprightImage(from: Data("not an image".utf8)))
    }

    func testDownloadsMustLookLikeAnUpload() throws {
        XCTAssertFalse(ProfilePhotoImage.isAcceptableDownload(try Self.photo(width: 1024, height: 1024, orientation: 1)))
        XCTAssertFalse(ProfilePhotoImage.isAcceptableDownload(try Self.photo(width: 64, height: 64, orientation: 1, type: .png)))
        XCTAssertFalse(ProfilePhotoImage.isAcceptableDownload(Data("<html>".utf8)))
        XCTAssertFalse(ProfilePhotoImage.isAcceptableDownload(Data(count: ProfilePhotoImage.maxBytes + 1)))
        XCTAssertTrue(ProfilePhotoImage.isAcceptableDownload(
            ProfilePhotoTestLabServer.fixtureJPEG(red: 0.2, green: 0.4, blue: 0.6)
        ))
    }

    /// A noisy test photo carrying EXIF, GPS, TIFF and IPTC metadata.
    static func photo(width: Int, height: Int, orientation: Int, type: UTType = .jpeg) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                     blue: .random(in: 0...1, using: &generator), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "HealthCompTestCamera", kCGImagePropertyTIFFModel: "Model 1"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:01 09:41:00",
                kCGImagePropertyExifUserComment: "secret-comment",
                kCGImagePropertyExifLensModel: "Lens",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Somewhere"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The marker byte of every segment before the scan data.
    static func segmentMarkers(_ jpeg: Data) throws -> [UInt8] {
        let bytes = [UInt8](jpeg)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8])
        var markers: [UInt8] = []
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            markers.append(marker)
            if marker == 0xDA { break }
            index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
        }
        XCTAssertEqual(markers.last, 0xDA, "reached the scan")
        return markers
    }
}

final class ProfilePhotoCacheTests: XCTestCase {
    private let owner = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "a1000000-0000-4000-8000-000000000002")!

    func testCacheKeepsOneVersionPerOwnerAndDropsWhatIsNoLongerVisible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-photo-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProfilePhotoCache(directory: directory)
        let first = ProfilePhotoReference(ownerProfileID: owner, version: UUID())
        let second = ProfilePhotoReference(ownerProfileID: owner, version: UUID())
        let theirs = ProfilePhotoReference(ownerProfileID: other, version: UUID())

        XCTAssertNil(cache.data(for: first))
        try cache.store(Data("one".utf8), for: first)
        try cache.store(Data("theirs".utf8), for: theirs)
        XCTAssertEqual(cache.data(for: first), Data("one".utf8))
        try cache.store(Data("two".utf8), for: second)
        XCTAssertNil(cache.data(for: first), "a new version replaces the old file")
        XCTAssertEqual(cache.latestData(owner: owner), Data("two".utf8))

        // A lookup that no longer returns `other` (removed, blocked, reported)
        // drops their file; an owner that wasn't looked up is left alone.
        cache.retain([second], among: [other])
        XCTAssertNil(cache.latestData(owner: other))
        XCTAssertEqual(cache.data(for: second), Data("two".utf8))
        cache.retain([], among: [owner])
        XCTAssertNil(cache.latestData(owner: owner))

        try cache.store(Data("theirs".utf8), for: theirs)
        cache.remove(owner: other)
        XCTAssertNil(cache.data(for: theirs))
        XCTAssertFalse(cache.isReported(owner: other))
        try cache.markReported(owner: other)
        XCTAssertTrue(cache.isReported(owner: other))
    }

    func testSignOutTeardownRemovesTheAccountsPhotos() async throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-photo-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let storage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: JSONCompetitionEventStoreFileProtection { _, _ in }
        )
        let paths = try await storage.mount(owner)
        let cache = ProfilePhotoCache(directory: paths.profilePhotosDirectory)
        let reference = ProfilePhotoReference(ownerProfileID: other, version: UUID())
        try cache.store(Data("photo".utf8), for: reference)
        XCTAssertEqual(cache.data(for: reference), Data("photo".utf8))
        try await storage.teardown(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.profilePhotosDirectory.path))
        XCTAssertNil(cache.data(for: reference))
    }
}
