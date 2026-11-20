import ImageIO
import UIKit
import UniformTypeIdentifiers

enum CustomVehiclePhoto {
    private static func file(for vehicle: VehicleIdentity) -> URL {
        let key = LeapCrypto.sha256Hex("\(vehicle.accountID)\n\(vehicle.vin)")
        return URL.applicationSupportDirectory
            .appendingPathComponent("CustomVehiclePhotos", isDirectory: true)
            .appendingPathComponent(key)
    }

    static func load(for vehicle: VehicleIdentity) -> UIImage? {
        guard let data = try? Data(contentsOf: file(for: vehicle)) else { return nil }
        return UIImage(data: data)
    }

    static func prepare(_ data: Data) throws -> Data {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_200
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw LeapError.decode("无法读取所选照片")
        }

        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: hasAlpha = true
        default: hasAlpha = false
        }
        let output = NSMutableData()
        let format = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else {
            throw LeapError.decode("无法处理所选照片")
        }
        CGImageDestinationAddImage(destination, image, hasAlpha ? nil : [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LeapError.decode("无法处理所选照片") }
        return output as Data
    }

    static func save(_ data: Data, for vehicle: VehicleIdentity) throws {
        let url = file(for: vehicle)
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(for vehicle: VehicleIdentity) throws {
        let url = file(for: vehicle)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
