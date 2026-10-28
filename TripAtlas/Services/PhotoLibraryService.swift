import Photos
import UIKit

/// Доступ к медиатеке: разрешения и выборка геотегированных фото.
enum PhotoLibraryService {

    static var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Все фото и видео с геолокацией, по возрастанию даты. Вызывать не на главном потоке.
    static func fetchGeotaggedSamples() -> [PhotoSample] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)

        var samples: [PhotoSample] = []
        samples.reserveCapacity(result.count / 2)
        result.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            let c = location.coordinate
            guard CLLocationCoordinate2DIsValid(c), !(c.latitude == 0 && c.longitude == 0) else { return }
            let date = asset.creationDate ?? location.timestamp
            samples.append(PhotoSample(id: asset.localIdentifier, date: date,
                                       latitude: c.latitude, longitude: c.longitude))
        }
        return samples
    }

    /// Геотегированные фото с указанными идентификаторами.
    static func samples(for ids: [String]) -> [PhotoSample] {
        var samples: [PhotoSample] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            let c = location.coordinate
            samples.append(PhotoSample(id: asset.localIdentifier,
                                       date: asset.creationDate ?? location.timestamp,
                                       latitude: c.latitude, longitude: c.longitude))
        }
        return samples
    }
}

/// Загрузка превью и полноразмерных изображений из PhotoKit.
final class ImageLoader {
    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()
    private let assetCache = NSCache<NSString, PHAsset>()

    private func asset(for id: String) -> PHAsset? {
        if let cached = assetCache.object(forKey: id as NSString) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        assetCache.setObject(asset, forKey: id as NSString)
        return asset
    }

    func image(for id: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        guard let asset = asset(for: id) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // обработчик вызывается один раз
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true       // фото из iCloud

        return await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(for: asset, targetSize: targetSize,
                                 contentMode: contentMode, options: options) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
