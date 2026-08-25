import AppKit
import Foundation

enum AnalysisOpenStreetMapSnapshotError: Error {
    case invalidViewport
    case tooManyTiles
    case invalidTile
}

/// Downloads the small, visible OpenStreetMap tile set needed for one report figure.
/// Requests identify the application but deliberately use an ephemeral, cache-free session so a
/// report request does not leave a durable local tile history. The resulting PDF always includes
/// OpenStreetMap attribution next to the image.
@MainActor
enum AnalysisOpenStreetMapSnapshotter {
    private static let tileSize = 256.0
    private static let session: URLSession = {
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "AagedalPhotoAgent/\(appVersion) (PDF map export; contact: aagedal.no)",
        ]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func image(
        viewport: AnalysisMapViewport,
        pixelSize: CGSize
    ) async throws -> NSImage {
        guard viewport.isValid, pixelSize.width > 0, pixelSize.height > 0 else {
            throw AnalysisOpenStreetMapSnapshotError.invalidViewport
        }

        let longitudeSpan = min(360, max(0.000_001, viewport.longitudeDelta))
        let north = min(85.051_128_78, viewport.center.latitude + viewport.latitudeDelta / 2)
        let south = max(-85.051_128_78, viewport.center.latitude - viewport.latitudeDelta / 2)
        let normalizedYTop = mercatorY(latitude: north)
        let normalizedYBottom = mercatorY(latitude: south)
        let normalizedYSpan = max(0.000_001, normalizedYBottom - normalizedYTop)
        let horizontalZoom = log2(pixelSize.width * 360 / (tileSize * longitudeSpan))
        let verticalZoom = log2(pixelSize.height / (tileSize * normalizedYSpan))
        let zoom = min(18, max(0, Int(floor(min(horizontalZoom, verticalZoom)))))
        let tileCountAtZoom = 1 << zoom
        let worldPixels = tileSize * Double(tileCountAtZoom)

        let centerX = (viewport.center.longitude + 180) / 360 * worldPixels
        let xSpan = longitudeSpan / 360 * worldPixels
        let xMin = centerX - xSpan / 2
        let xMax = centerX + xSpan / 2
        let yMin = normalizedYTop * worldPixels
        let yMax = normalizedYBottom * worldPixels
        let tileXMin = Int(floor(xMin / tileSize))
        let tileXMax = Int(floor((xMax - 0.001) / tileSize))
        let tileYMin = max(0, Int(floor(yMin / tileSize)))
        let tileYMax = min(tileCountAtZoom - 1, Int(floor((yMax - 0.001) / tileSize)))
        let numberOfTiles = (tileXMax - tileXMin + 1) * (tileYMax - tileYMin + 1)
        guard numberOfTiles > 0, numberOfTiles <= 64 else {
            throw AnalysisOpenStreetMapSnapshotError.tooManyTiles
        }

        let downloadSession = session
        let tileData = try await withThrowingTaskGroup(
            of: (x: Int, y: Int, data: Data).self
        ) { group in
            for x in tileXMin...tileXMax {
                for y in tileYMin...tileYMax {
                    let wrappedX = ((x % tileCountAtZoom) + tileCountAtZoom) % tileCountAtZoom
                    group.addTask {
                        let url = URL(string:
                            "https://tile.openstreetmap.org/\(zoom)/\(wrappedX)/\(y).png"
                        )!
                        let (data, response) = try await downloadSession.data(from: url)
                        guard (response as? HTTPURLResponse)?.statusCode == 200,
                              !data.isEmpty else {
                            throw AnalysisOpenStreetMapSnapshotError.invalidTile
                        }
                        return (x, y, data)
                    }
                }
            }
            var result: [(x: Int, y: Int, data: Data)] = []
            for try await tile in group { result.append(tile) }
            return result
        }

        let canvasWidth = CGFloat(tileXMax - tileXMin + 1) * tileSize
        let canvasHeight = CGFloat(tileYMax - tileYMin + 1) * tileSize
        let canvas = NSImage(size: CGSize(width: canvasWidth, height: canvasHeight))
        canvas.lockFocus()
        for tile in tileData {
            guard let image = NSImage(data: tile.data) else {
                throw AnalysisOpenStreetMapSnapshotError.invalidTile
            }
            let x = CGFloat(tile.x - tileXMin) * tileSize
            let top = CGFloat(tile.y - tileYMin) * tileSize
            image.draw(
                in: CGRect(x: x, y: canvasHeight - top - tileSize, width: tileSize, height: tileSize),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
        }
        canvas.unlockFocus()

        let cropFromLeft = CGFloat(xMin - Double(tileXMin) * tileSize)
        let cropFromTop = CGFloat(yMin - Double(tileYMin) * tileSize)
        let cropWidth = CGFloat(max(1, xMax - xMin))
        let cropHeight = CGFloat(max(1, yMax - yMin))
        let cropRect = CGRect(
            x: cropFromLeft,
            y: canvasHeight - cropFromTop - cropHeight,
            width: cropWidth,
            height: cropHeight
        )
        let output = NSImage(size: pixelSize)
        output.lockFocus()
        canvas.draw(in: CGRect(origin: .zero, size: pixelSize), from: cropRect, operation: .copy, fraction: 1)
        output.unlockFocus()
        return output
    }

    private static func mercatorY(latitude: Double) -> Double {
        let clamped = min(85.051_128_78, max(-85.051_128_78, latitude))
        let radians = clamped * .pi / 180
        return (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
    }
}
