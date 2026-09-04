import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// `TechnicalMetadata.init(from:)` turns a raw EXIF/ImageIO dictionary into the formatted
/// strings shown in the inspector. The formatting (focal length, aperture, reciprocal
/// shutter speed) and the crash-hardening around corrupt numeric fields are the parts most
/// worth pinning down. Passing `fileURL: nil` keeps these tests pure (no CGImageSource I/O);
/// the native bit-depth/color-space path is only taken when a URL is supplied.
@Suite("TechnicalMetadata")
struct TechnicalMetadataTests {

    private func meta(_ dict: [String: Any]) -> TechnicalMetadata {
        TechnicalMetadata(from: dict, fileURL: nil)
    }

    // MARK: - Camera make/model combination

    @Test("Model already prefixed with make is not duplicated")
    func cameraNoDuplication() {
        let m = meta(["Make": "Canon", "Model": "Canon EOS 5D Mark IV"])
        #expect(m.camera == "Canon EOS 5D Mark IV")
    }

    @Test("Make + model are joined when model lacks the make prefix")
    func cameraJoined() {
        let m = meta(["Make": "SONY", "Model": "ILCE-7M4"])
        #expect(m.camera == "SONY ILCE-7M4")
    }

    @Test("Make-prefix dedup is case-insensitive")
    func cameraDedupCaseInsensitive() {
        let m = meta(["Make": "CANON", "Model": "Canon EOS R5"])
        #expect(m.camera == "Canon EOS R5")
    }

    @Test("Only make or only model still produces a camera string")
    func cameraPartial() {
        #expect(meta(["Make": "Canon"]).camera == "Canon")
        #expect(meta(["Model": "EOS R5"]).camera == "EOS R5")
        #expect(meta([:]).camera == nil)
    }

    @Test("Surrounding whitespace in make/model is trimmed")
    func cameraTrimmed() {
        let m = meta(["Make": "  Nikon  ", "Model": "  Z 9  "])
        #expect(m.camera == "Nikon Z 9")
    }

    // MARK: - Focal length

    @Test("Integer focal length drops the decimal")
    func focalLengthInteger() {
        #expect(meta(["FocalLength": 50.0]).focalLength == "50 mm")
    }

    @Test("Fractional focal length keeps one decimal")
    func focalLengthFractional() {
        #expect(meta(["FocalLength": 35.5]).focalLength == "35.5 mm")
    }

    @Test("String focal length passes through unchanged")
    func focalLengthString() {
        #expect(meta(["FocalLength": "24-70mm"]).focalLength == "24-70mm")
    }

    // MARK: - Aperture

    @Test("Integer aperture renders as f/N")
    func apertureInteger() {
        #expect(meta(["FNumber": 2.0]).aperture == "f/2")
    }

    @Test("Fractional aperture renders as f/N.n")
    func apertureFractional() {
        #expect(meta(["FNumber": 2.8]).aperture == "f/2.8")
        #expect(meta(["FNumber": 11.0]).aperture == "f/11")
    }

    // MARK: - Shutter speed

    @Test("Sub-second exposures render as a reciprocal fraction")
    func shutterReciprocal() {
        #expect(meta(["ExposureTime": 0.5]).shutterSpeed == "1/2 s")
        #expect(meta(["ExposureTime": 0.001]).shutterSpeed == "1/1000 s")
        #expect(meta(["ExposureTime": 1.0 / 8000.0]).shutterSpeed == "1/8000 s")
    }

    @Test("Exposures of a second or more render in seconds")
    func shutterSeconds() {
        #expect(meta(["ExposureTime": 1.0]).shutterSpeed == "1.0 s")
        #expect(meta(["ExposureTime": 2.0]).shutterSpeed == "2.0 s")
    }

    @Test("Corrupt exposure times are rejected without trapping", arguments: [
        0.0, -0.5, Double.infinity, -Double.infinity, Double.nan
    ])
    func shutterCorrupt(_ value: Double) {
        // 1/et on a 0 / non-finite exposure would trap in Int(.infinity); the guard must
        // drop it to nil instead.
        #expect(meta(["ExposureTime": value]).shutterSpeed == nil)
    }

    // MARK: - ISO

    @Test("ISO accepts both Int and Double encodings")
    func isoNumericForms() {
        #expect(meta(["ISO": 400]).iso == "400")
        #expect(meta(["ISO": 800.0]).iso == "800")
    }

    @Test("Non-finite ISO is rejected", arguments: [Double.infinity, Double.nan])
    func isoCorrupt(_ value: Double) {
        #expect(meta(["ISO": value]).iso == nil)
    }

    // MARK: - White balance

    @Test("Numeric white balance maps 0=Auto, non-zero=Manual")
    func whiteBalanceNumeric() {
        #expect(meta(["WhiteBalance": 0]).whiteBalance == "Auto")
        #expect(meta(["WhiteBalance": 1]).whiteBalance == "Manual")
    }

    @Test("String white balance passes through")
    func whiteBalanceString() {
        #expect(meta(["WhiteBalance": "Daylight"]).whiteBalance == "Daylight")
    }

    // MARK: - Lens ID

    @Test("Lens ID prefers a text description")
    func lensIDString() {
        #expect(meta(["LensID": "Canon RF 50mm F1.2"]).lensID == "Canon RF 50mm F1.2")
    }

    @Test("Numeric lens ID is used, but sentinel/zero values are ignored")
    func lensIDNumericSentinels() {
        #expect(meta(["LensID": 123]).lensID == "123")
        #expect(meta(["LensID": 65535]).lensID == nil) // "unknown" sentinel
        #expect(meta(["LensID": 0]).lensID == nil)
    }

    // MARK: - Dimensions

    @Test("EXIF dimensions take precedence over File dimensions")
    func dimensionsPreferExif() {
        let m = meta([
            "ImageWidth": 6000, "ImageHeight": 4000,
            "File:ImageWidth": 100, "File:ImageHeight": 50
        ])
        #expect(m.imageWidth == 6000)
        #expect(m.imageHeight == 4000)
    }

    @Test("File dimensions are used when EXIF dimensions are absent")
    func dimensionsFallBackToFile() {
        let m = meta(["File:ImageWidth": 1920, "File:ImageHeight": 1080])
        #expect(m.imageWidth == 1920)
        #expect(m.imageHeight == 1080)
    }

    // MARK: - Bit depth (EXIF fallback path, fileURL == nil)

    @Test("Bit depth reads a scalar BitsPerSample")
    func bitDepthScalar() {
        #expect(meta(["BitsPerSample": 16]).bitDepth == 16)
    }

    @Test("Bit depth reads the first element of a BitsPerSample array")
    func bitDepthArray() {
        #expect(meta(["BitsPerSample": [8, 8, 8]]).bitDepth == 8)
    }

    // MARK: - Color space (EXIF fallback path, fileURL == nil)

    @Test("ICC profile description wins over the numeric ColorSpace tag")
    func colorSpaceProfileWins() {
        let m = meta(["ProfileDescription": "Display P3", "ColorSpace": 1])
        #expect(m.colorSpace == "Display P3")
    }

    @Test("Numeric ColorSpace tag maps to known names")
    func colorSpaceNumeric() {
        #expect(meta(["ColorSpace": 1]).colorSpace == "sRGB")
        #expect(meta(["ColorSpace": 2]).colorSpace == "Adobe RGB")
        #expect(meta(["ColorSpace": 0xFFFF]).colorSpace == "Uncalibrated")
        #expect(meta(["ColorSpace": 99]).colorSpace == "Unknown (99)")
    }

    // MARK: - Resolution (orientation swap)

    @Test("Resolution swaps width/height for transposed orientations 5–8")
    func resolutionOrientationSwap() {
        let m = meta(["ImageWidth": 4000, "ImageHeight": 3000])
        #expect(m.resolution(orientation: 1) == "4000 x 3000")
        #expect(m.resolution(orientation: 3) == "4000 x 3000")
        for transposed in [5, 6, 7, 8] {
            #expect(m.resolution(orientation: transposed) == "3000 x 4000")
        }
    }

    @Test("Resolution is nil when dimensions are missing")
    func resolutionMissing() {
        #expect(meta([:]).resolution(orientation: 1) == nil)
        #expect(meta(["ImageWidth": 4000]).resolution(orientation: 1) == nil)
    }

    // MARK: - C2PA detection

    @Test("dictHasC2PA detects JUMD/C2PA/Claim_generator keys")
    func dictHasC2PA() {
        #expect(TechnicalMetadata.dictHasC2PA(["JUMDc2pa": 1]))
        #expect(TechnicalMetadata.dictHasC2PA(["C2PA.assertions": 1]))
        #expect(TechnicalMetadata.dictHasC2PA(["Claim_generator": "c2pa-rs"]))
        #expect(!TechnicalMetadata.dictHasC2PA(["Make": "Canon"]))
        #expect(!TechnicalMetadata.dictHasC2PA([:]))
    }

    @Test("init mirrors dictHasC2PA into hasC2PA and reads claim/edited fields")
    func c2paFieldsFromInit() {
        let m = meta([
            "Claim_generator": "c2pa-rs/0.1",
            "AuthorName": "Truls",
            "Relationship": "parentOf"
        ])
        #expect(m.hasC2PA) // Claim_generator key
        #expect(m.c2paClaimGenerator == "c2pa-rs/0.1")
        #expect(m.c2paAuthor == "Truls")
        #expect(m.c2paEdited)
    }

    @Test("Non-edited relationship leaves c2paEdited false")
    func c2paNotEdited() {
        #expect(meta(["Relationship": "componentOf"]).c2paEdited == false)
        #expect(meta([:]).c2paEdited == false)
    }

    // MARK: - hasCameraInfo

    @Test("hasCameraInfo is true when any camera/exposure field is present")
    func hasCameraInfoTrue() {
        #expect(meta(["ISO": 100]).hasCameraInfo)
        #expect(meta(["Make": "Canon"]).hasCameraInfo)
        #expect(meta(["FNumber": 2.8]).hasCameraInfo)
    }

    @Test("hasCameraInfo is false for a dict with no camera fields")
    func hasCameraInfoFalse() {
        #expect(meta(["ImageWidth": 4000, "ImageHeight": 3000]).hasCameraInfo == false)
    }

    // MARK: - Merging

    @Test("mergingCameraFields adopts camera/exposure, keeps own image/C2PA fields")
    func mergeCameraFields() {
        let base = meta(["ImageWidth": 6000, "ImageHeight": 4000,
                         "BitsPerSample": 14, "JUMDc2pa": 1])
        let other = meta(["Make": "Sony", "Model": "ILCE-7M4", "ISO": 100])
        let merged = base.mergingCameraFields(from: other)

        #expect(merged.camera == "Sony ILCE-7M4")
        #expect(merged.iso == "100")
        // Own technical fields are preserved.
        #expect(merged.imageWidth == 6000)
        #expect(merged.bitDepth == 14)
        #expect(merged.hasC2PA)
    }

    @Test("mergingTechnicalExtras overlays MakerNote extras, fills only missing fields")
    func mergeTechnicalExtras() {
        let base = meta(["Make": "Canon", "Model": "Canon EOS R5", "LensModel": "RF 24-70"])
        let other = meta([
            "ShutterCount": 12345,
            "CameraTemperature": 30,
            "LensModel": "Should not override",
            "SerialNumber": "SN-1"
        ])
        let merged = base.mergingTechnicalExtras(from: other)

        // Always-overlaid MakerNote-only extras.
        #expect(merged.shutterCount == 12345)
        #expect(merged.cameraTemperature == 30)
        // Existing lens is kept; missing serial is filled.
        #expect(merged.lens == "RF 24-70")
        #expect(merged.serialNumber == "SN-1")
        // Own camera identity is untouched.
        #expect(merged.camera == "Canon EOS R5")
    }
}

@Suite("Technical metadata fast-read filesystem boundary")
struct TechnicalMetadataFastLoadServiceTests {
    @Test("a complete fast snapshot is read away from the main actor")
    @MainActor
    func completeSnapshotRunsOffMainActor() async {
        let imageURL = URL(fileURLWithPath: "/virtual/technical.raw")
        let requestID = UUID()
        let expected = TechnicalMetadata(from: ["Make": "Canon"], fileURL: nil)
        let probe = TechnicalMetadataFastAccessProbe(metadata: expected)
        let service = TechnicalMetadataFastLoadService(access: .init(read: probe.read))

        let result = await Task {
            await service.load(
                imageURL: imageURL,
                hasC2PA: true,
                requestID: requestID
            )
        }.value

        guard case .loaded(let snapshot) = result else {
            Issue.record("Expected a loaded technical-metadata snapshot")
            return
        }
        #expect(snapshot.requestID == requestID)
        #expect(snapshot.imageURL == imageURL)
        #expect(snapshot.metadata.camera == "Canon")
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation performs no ImageIO or attribute read")
    func preCancellation() async {
        let requestID = UUID()
        let probe = TechnicalMetadataFastAccessProbe(
            metadata: TechnicalMetadata(from: [:], fileURL: nil)
        )
        let service = TechnicalMetadataFastLoadService(access: .init(read: probe.read))
        let task = Task {
            await Task.yield()
            return await service.load(
                imageURL: URL(fileURLWithPath: "/virtual/cancelled.raw"),
                hasC2PA: false,
                requestID: requestID
            )
        }
        task.cancel()

        let result = await task.value
        guard case .cancelledBeforeRead(let completedRequestID) = result else {
            Issue.record("Expected pre-read cancellation")
            return
        }
        #expect(completedRequestID == requestID)
        #expect(probe.invocationCount == 0)
    }

    @Test("cancellation after a non-preemptible fast read is explicit")
    func cancellationAfterRead() async {
        let imageURL = URL(fileURLWithPath: "/virtual/slow.raw")
        let requestID = UUID()
        let service = TechnicalMetadataFastLoadService(access: .init { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return TechnicalMetadata(from: [:], fileURL: nil)
        })

        let result = await Task {
            await service.load(
                imageURL: imageURL,
                hasC2PA: false,
                requestID: requestID
            )
        }.value

        guard case .cancelledAfterRead(let completedRequestID, let completedImageURL) = result else {
            Issue.record("Expected post-read cancellation")
            return
        }
        #expect(completedRequestID == requestID)
        #expect(completedImageURL == imageURL)
    }

    @Test("ContentView awaits serialized facts and gates both publications by request identity")
    func contentViewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadTechnicalMetadata()"))
        let functionEnd = try #require(source.range(
            of: "    private func loadScopeImage(",
            range: functionStart.upperBound..<source.endIndex
        ))
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(functionSource.contains("await TechnicalMetadataFastLoadService.shared.load("))
        #expect(functionSource.contains("technicalMetadataRequestID == requestID"))
        #expect(functionSource.contains("snapshot.imageURL == url"))
        #expect(!functionSource.contains("Task.detached"))
        #expect(!functionSource.contains("TechnicalMetadata.fromImageIO"))
    }
}

private nonisolated final class TechnicalMetadataFastAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let metadata: TechnicalMetadata
    private var count = 0
    private var observedMainThread = false

    init(metadata: TechnicalMetadata) {
        self.metadata = metadata
    }

    func read(imageURL: URL, hasC2PA: Bool) -> TechnicalMetadata {
        _ = imageURL
        _ = hasC2PA
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return metadata
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

@Suite("SwiftExif technical-metadata snapshot boundary")
struct SwiftExifTechnicalMetadataSnapshotTests {
    @Test("complete technical assembly stays off MainActor and preserves native-read intent")
    @MainActor
    func completeSnapshotRunsOffMainActor() async throws {
        let expected = TechnicalMetadata(from: ["Make": "Nikon"], fileURL: nil)
        let probe = SwiftExifTechnicalMetadataAccessProbe(metadata: expected)
        let service = SwiftExifReadService(
            technicalMetadataAccess: .init(makeSnapshot: probe.makeSnapshot)
        )
        let imageURL = URL(fileURLWithPath: "/virtual/technical-enrichment.nef")

        let metadata = try await service.readTechnicalMetadata(
            url: imageURL,
            includeNativeImageInfo: true
        )

        #expect(metadata.camera == "Nikon")
        #expect(probe.invocationCount == 1)
        #expect(probe.receivedFileURLs == [imageURL])
        #expect(!probe.ranOnMainThread)
    }

    @Test("disabled native enrichment keeps the snapshot filesystem-free")
    @MainActor
    func disabledNativeReadPassesNoFileURL() async throws {
        let expected = TechnicalMetadata(from: ["Make": "Sony"], fileURL: nil)
        let probe = SwiftExifTechnicalMetadataAccessProbe(metadata: expected)
        let service = SwiftExifReadService(
            technicalMetadataAccess: .init(makeSnapshot: probe.makeSnapshot)
        )

        let metadata = try await service.readTechnicalMetadata(
            url: URL(fileURLWithPath: "/virtual/no-native-enrichment.arw"),
            includeNativeImageInfo: false
        )

        #expect(metadata.camera == "Sony")
        #expect(probe.receivedFileURLs == [nil])
        #expect(!probe.ranOnMainThread)
    }

    @Test("read service returns a complete actor-built snapshot")
    func readServiceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/SwiftExifReadService.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(
            of: "    func readTechnicalMetadata(url: URL, includeNativeImageInfo: Bool = true)"
        ))
        let functionEnd = try #require(source.range(
            of: "    /// Read detailed C2PA manifest data.",
            range: functionStart.upperBound..<source.endIndex
        ))
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(functionSource.contains("await lockedReadTechnicalMetadata("))
        #expect(!functionSource.contains("TechnicalMetadata(from:"))
        #expect(!functionSource.contains("lockedReadDict"))
    }
}

private nonisolated final class SwiftExifTechnicalMetadataAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let metadata: TechnicalMetadata
    private var count = 0
    private var fileURLs: [URL?] = []
    private var observedMainThread = false

    init(metadata: TechnicalMetadata) {
        self.metadata = metadata
    }

    func makeSnapshot(dictionary: [String: Any], fileURL: URL?) -> TechnicalMetadata {
        _ = dictionary
        lock.withLock {
            count += 1
            fileURLs.append(fileURL)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return metadata
    }

    var invocationCount: Int { lock.withLock { count } }
    var receivedFileURLs: [URL?] { lock.withLock { fileURLs } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}
