import SwiftUI
import UIKit
import Photos

/// Async PhotoKit thumbnail for grids and review lists.
struct AssetThumbnailView: View {
    let localId: String
    var side: CGFloat = 96

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: localId) {
            image = await Self.loadThumbnail(localId: localId, side: side)
        }
    }

    static func loadThumbnail(localId: String, side: CGFloat) async -> UIImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        let scale = await MainActor.run { UIScreen.main.scale }
        let target = CGSize(width: side * scale, height: side * scale)
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFill, options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !resumed, image != nil, !degraded {
                    resumed = true
                    continuation.resume(returning: image)
                } else if !resumed, !degraded {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
