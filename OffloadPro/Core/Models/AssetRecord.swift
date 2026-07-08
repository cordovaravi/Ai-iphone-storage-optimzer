import Foundation
import GRDB

/// Row of `asset_index` (§0.3) — one indexed photo-library asset.
struct AssetRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "asset_index"

    var localId: String
    var mediaType: Int
    var subtype: Int
    var bytes: Int64
    var createdAt: Double?
    var width: Int?
    var height: Int?
    var duration: Double?
    var isScreenshot: Bool?
    var isScreenRecording: Bool?
    var isWhatsapp: Bool?
    var sha256: String?
    var phash: Data?
    var blurScore: Double?
    var scannedAt: Double

    enum CodingKeys: String, CodingKey {
        case localId = "local_id"
        case mediaType = "media_type"
        case subtype
        case bytes
        case createdAt = "created_at"
        case width, height, duration
        case isScreenshot = "is_screenshot"
        case isScreenRecording = "is_screen_recording"
        case isWhatsapp = "is_whatsapp"
        case sha256, phash
        case blurScore = "blur_score"
        case scannedAt = "scanned_at"
    }
}

/// UI-facing media categories (F1.4).
enum MediaCategory: String, CaseIterable, Sendable, Identifiable {
    case videos = "Videos"
    case screenshots = "Screenshots"
    case screenRecordings = "Screen Recordings"
    case bursts = "Bursts"
    case livePhotos = "Live Photos"
    case panoramas = "Panoramas"
    case selfies = "Selfies"
    case whatsapp = "WhatsApp Media"
    case raw = "RAW"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .videos: return "video.fill"
        case .screenshots: return "camera.viewfinder"
        case .screenRecordings: return "record.circle"
        case .bursts: return "square.stack.3d.down.right.fill"
        case .livePhotos: return "livephoto"
        case .panoramas: return "pano.fill"
        case .selfies: return "person.crop.square.fill"
        case .whatsapp: return "message.fill"
        case .raw: return "camera.aperture"
        }
    }
}
