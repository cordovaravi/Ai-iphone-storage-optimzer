import XCTest
@testable import OffloadPro

final class ClassificationTests: XCTestCase {
    private func snapshot(
        mediaType: Int = AssetClassifier.mediaTypeImage,
        subtype: Int = 0,
        width: Int = 4032,
        height: Int = 3024,
        duration: Double = 0,
        resources: [AssetSnapshot.ResourceInfo] = [],
        albums: [String] = [],
        camera: String? = "Apple",
        lens: String? = "Wide"
    ) -> AssetSnapshot {
        AssetSnapshot(
            localId: UUID().uuidString,
            mediaType: mediaType,
            subtype: subtype,
            createdAt: Date(),
            modifiedAt: nil,
            width: width,
            height: height,
            duration: duration,
            isBurst: false,
            resources: resources,
            albumNames: albums,
            exif: .init(cameraModel: camera, lensModel: lens)
        )
    }

    /// §1.3: screenshot subtype detected.
    func testScreenshotSubtype() {
        let shot = snapshot(subtype: AssetClassifier.subtypeScreenshot)
        XCTAssertTrue(AssetClassifier.isScreenshot(shot))
        XCTAssertFalse(AssetClassifier.isScreenshot(snapshot()))
    }

    func testScreenRecordingByFilename() {
        let recording = snapshot(
            mediaType: AssetClassifier.mediaTypeVideo,
            resources: [.init(kind: .video, filename: "RPReplay_Final1699999999.MP4", fileSize: 1)]
        )
        XCTAssertTrue(AssetClassifier.isScreenRecording(recording))
    }

    /// §1.3: WhatsApp scorer ≥ 0.8 on WhatsApp-like fixture.
    func testWhatsAppFixtureScoresHigh() {
        let whatsapp = snapshot(
            width: 1280, height: 960,
            resources: [.init(kind: .photo, filename: "IMG-20260701-WA0012.jpg", fileSize: 1)],
            camera: nil, lens: nil
        )
        XCTAssertGreaterThanOrEqual(AssetClassifier.whatsappScore(whatsapp), 0.8)
        XCTAssertTrue(AssetClassifier.isWhatsApp(whatsapp))
    }

    func testWhatsAppAlbumMembershipIsConclusive() {
        let inAlbum = snapshot(albums: ["WhatsApp"])
        XCTAssertEqual(AssetClassifier.whatsappScore(inAlbum), 1.0)
    }

    /// §1.3: DSLR fixture scores < 0.8.
    func testDSLRFixtureScoresLow() {
        let dslr = snapshot(
            width: 6000, height: 4000,
            resources: [.init(kind: .photo, filename: "DSC01234.ARW", fileSize: 1)],
            camera: "Sony A7IV", lens: "FE 24-70"
        )
        XCTAssertLessThan(AssetClassifier.whatsappScore(dslr), 0.8)
        XCTAssertFalse(AssetClassifier.isWhatsApp(dslr))
    }

    func testAccidentalMicroVideo() {
        let accidental = snapshot(mediaType: AssetClassifier.mediaTypeVideo, duration: 0.7)
        XCTAssertTrue(AssetClassifier.isAccidentalVideo(accidental))
        let normal = snapshot(mediaType: AssetClassifier.mediaTypeVideo, duration: 12)
        XCTAssertFalse(AssetClassifier.isAccidentalVideo(normal))
    }
}
