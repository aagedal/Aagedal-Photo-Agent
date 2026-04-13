import Foundation

/// MetadataWriteEngine implementation that delegates to the persistent ExifTool process.
final class ExifToolWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let exifToolService: ExifToolService

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
    }

    func writeFields(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws {
        let tagFields = fields.reduce(into: [String: String]()) { result, pair in
            result[pair.key.exifToolTag] = pair.value
        }
        let extraArgs = maskWriteArgs(from: structuredData.masks) + toneCurveWriteArgs(from: structuredData.toneCurve)
        try await exifToolService.writeFields(tagFields, to: urls, extraArgs: extraArgs)
    }

    func addRemoveListValues(
        add: [MetadataFieldKey: [String]],
        remove: [MetadataFieldKey: [String]],
        to urls: [URL]
    ) async throws {
        let tagAdd = add.reduce(into: [String: [String]]()) { $0[$1.key.exifToolTag] = $1.value }
        let tagRemove = remove.reduce(into: [String: [String]]()) { $0[$1.key.exifToolTag] = $1.value }
        try await exifToolService.addRemoveListValues(add: tagAdd, remove: tagRemove, to: urls)
    }

    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {
        try await exifToolService.writeRating(rating, to: urls)
    }

    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {
        try await exifToolService.writeLabel(label, to: urls)
    }

    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {
        try await exifToolService.writeOrientation(orientation, to: urls)
    }

    func stripIPTCAndXMP(from urls: [URL]) async throws {
        try await exifToolService.stripIPTCAndXMP(from: urls)
    }

    func copyMetadataToRenderedFile(from source: URL, to destination: URL) async throws {
        try await exifToolService.copyMetadataToRenderedFile(from: source, to: destination)
    }

    // MARK: - Structured Data → ExifTool Args

    /// Generate ExifTool args for writing mask data as ACR-compatible MaskGroupBasedCorrections.
    private func maskWriteArgs(from masks: [MaskAdjustment]?) -> [String] {
        let enabledMasks = masks?.filter(\.enabled) ?? []

        // Always clear existing masks first
        var args = ["-struct", "-\(ExifToolWriteTag.crsMaskGroupBasedCorrections)="]

        guard !enabledMasks.isEmpty else { return masks == nil ? [] : args }

        for (index, mask) in enabledMasks.enumerated() {
            let geo = mask.geometry
            let top = geo.centerY - geo.radiusY
            let left = geo.centerX - geo.radiusX
            let bottom = geo.centerY + geo.radiusY
            let right = geo.centerX + geo.radiusX

            let corrSyncID = mask.id.uuidString.replacingOccurrences(of: "-", with: "")
            let maskSyncID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

            let maskStruct = [
                "What=Mask/CircularGradient",
                "Top=\(acrNum(top))",
                "Left=\(acrNum(left))",
                "Bottom=\(acrNum(bottom))",
                "Right=\(acrNum(right))",
                "Angle=\(acrNum(geo.rotation))",
                "Feather=\(acrNum(geo.feather))",
                "Midpoint=50",
                "Roundness=0",
                "Flipped=\(!mask.inverted ? "true" : "false")",
                "MaskActive=true",
                "MaskBlendMode=0",
                "MaskInverted=false",
                "MaskName=Radial Gradient \(index + 1)",
                "MaskSyncID=\(maskSyncID)",
                "MaskValue=1",
                "Version=2",
            ].joined(separator: ",")

            // ACR stores all local adjustments as fractions of their full range (-1..+1).
            let exp = (mask.exposure ?? 0) / 4.0
            let con = Double(mask.contrast ?? 0) / 100.0
            let hi = Double(mask.highlights ?? 0) / 100.0
            let sh = Double(mask.shadows ?? 0) / 100.0
            let wh = Double(mask.whites ?? 0) / 100.0
            let bl = Double(mask.blacks ?? 0) / 100.0
            let sat = Double(mask.saturation ?? 0) / 100.0
            let vib = Double(mask.vibrance ?? 0) / 100.0
            let temp = (mask.temperature ?? 0) / 100.0
            let tint = (mask.tint ?? 0) / 100.0

            let corrParts = [
                "CorrectionActive=true",
                "CorrectionAmount=\(acrNum(mask.amount))",
                "CorrectionName=\(mask.name)",
                "CorrectionSyncID=\(corrSyncID)",
                "What=Correction",
                "CorrectionMasks={\(maskStruct)}",
                "LocalExposure2012=\(acrNum(exp))",
                "LocalContrast2012=\(acrNum(con))",
                "LocalHighlights2012=\(acrNum(hi))",
                "LocalShadows2012=\(acrNum(sh))",
                "LocalWhites2012=\(acrNum(wh))",
                "LocalBlacks2012=\(acrNum(bl))",
                "LocalSaturation=\(acrNum(sat))",
                "LocalVibrance=\(acrNum(vib))",
                "LocalTemperature=\(acrNum(temp))",
                "LocalTint=\(acrNum(tint))",
                // Legacy fields (required by ACR, always 0)
                "LocalExposure=0",
                "LocalContrast=0",
                "LocalBrightness=0",
                "LocalClarity=0",
                "LocalClarity2012=0",
                "LocalSharpness=0",
                "LocalLuminanceNoise=0",
                "LocalMoire=0",
                "LocalDefringe=0",
                "LocalDehaze=0",
                "LocalTexture=0",
                "LocalHue=0",
                "LocalToningHue=0",
                "LocalToningSaturation=0",
            ]

            args.append("-\(ExifToolWriteTag.crsMaskGroupBasedCorrections)={\(corrParts.joined(separator: ","))}")
        }

        return args
    }

    /// Generate ExifTool args for writing tone curve data as ACR-compatible ToneCurvePV2012 lists.
    private func toneCurveWriteArgs(from toneCurve: ToneCurve?) -> [String] {
        // Always clear existing tone curve tags first
        var args = [
            "-\(ExifToolWriteTag.crsToneCurvePV2012)=",
            "-\(ExifToolWriteTag.crsToneCurvePV2012Red)=",
            "-\(ExifToolWriteTag.crsToneCurvePV2012Green)=",
            "-\(ExifToolWriteTag.crsToneCurvePV2012Blue)=",
            "-\(ExifToolWriteTag.crsToneCurveName2012)=",
        ]

        guard let tc = toneCurve, !tc.isEmpty else { return toneCurve == nil ? [] : args }

        args.append(contentsOf: ["-sep", ";"])

        func formatChannel(_ tag: String, _ points: [ToneCurvePoint]?) {
            guard let points, points.count > 2 else { return }
            let joined = points.map { "\(Int(round($0.x * 255))), \(Int(round($0.y * 255)))" }.joined(separator: ";")
            args.append("-\(tag)=\(joined)")
        }

        formatChannel(ExifToolWriteTag.crsToneCurvePV2012, tc.master)
        formatChannel(ExifToolWriteTag.crsToneCurvePV2012Red, tc.red)
        formatChannel(ExifToolWriteTag.crsToneCurvePV2012Green, tc.green)
        formatChannel(ExifToolWriteTag.crsToneCurvePV2012Blue, tc.blue)
        args.append("-\(ExifToolWriteTag.crsToneCurveName2012)=Custom")

        return args
    }
}
