import XCTest
@testable import OffloadPro

final class AssetSizerTests: XCTestCase {
    typealias Resource = AssetSnapshot.ResourceInfo

    /// §1.3: plain photo — single original resource.
    func testPlainPhoto() {
        let resources = [Resource(kind: .photo, filename: "IMG_0001.HEIC", fileSize: 2_400_000)]
        XCTAssertEqual(AssetSizer.originalBytes(of: resources), 2_400_000)
    }

    /// §1.3: Live Photo — photo + paired video both count.
    func testLivePhotoSumsPairedVideo() {
        let resources = [
            Resource(kind: .photo, filename: "IMG_0002.HEIC", fileSize: 2_000_000),
            Resource(kind: .pairedVideo, filename: "IMG_0002.MOV", fileSize: 1_500_000),
        ]
        XCTAssertEqual(AssetSizer.originalBytes(of: resources), 3_500_000)
    }

    /// §1.3: edited photo — count-original policy: the original (photo) and
    /// the render (fullSizePhoto) both persist on disk; adjustment data
    /// is excluded.
    func testEditedPhotoCountsOriginalPolicy() {
        let resources = [
            Resource(kind: .photo, filename: "IMG_0003.HEIC", fileSize: 2_000_000),
            Resource(kind: .fullSizePhoto, filename: "IMG_0003_edited.JPG", fileSize: 3_000_000),
            Resource(kind: .adjustmentData, filename: "Adjustments.plist", fileSize: 5_000),
        ]
        XCTAssertEqual(AssetSizer.originalBytes(of: resources), 5_000_000)
    }

    /// §1.3: 4K video — single large original.
    func test4KVideo() {
        let resources = [Resource(kind: .video, filename: "IMG_0004.MOV", fileSize: 3_200_000_000)]
        XCTAssertEqual(AssetSizer.originalBytes(of: resources), 3_200_000_000)
    }

    /// Missing fileSize forces the fallback path (returns nil).
    func testMissingFileSizeReturnsNil() {
        let resources = [
            Resource(kind: .photo, filename: "IMG_0005.HEIC", fileSize: nil),
        ]
        XCTAssertNil(AssetSizer.originalBytes(of: resources))
    }

    func testNoOriginalResourcesReturnsNil() {
        let resources = [Resource(kind: .adjustmentData, filename: "Adjustments.plist", fileSize: 5_000)]
        XCTAssertNil(AssetSizer.originalBytes(of: resources))
    }
}
