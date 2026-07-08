import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// PhotoKit authorization flow (§1.2.1). Handles `.limited` explicitly —
/// every downstream feature must keep working with partial access.
@MainActor
final class PhotoAuthService: ObservableObject {
    enum State: Equatable {
        case notDetermined, denied, limited, authorized
    }

    @Published private(set) var state: State

    init() {
        state = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        state = Self.map(status)
    }

    /// Presents the system limited-library picker so the user can extend
    /// their selection ("Limited access: results incomplete" banner action).
    func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func map(_ status: PHAuthorizationStatus) -> State {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }
}
