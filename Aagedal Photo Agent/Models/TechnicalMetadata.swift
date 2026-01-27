import Foundation

struct TechnicalMetadata {
    var camera: String?
    var lens: String?
    var captureDate: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var bitDepth: Int?
    var colorSpace: String?

    // C2PA
    var hasC2PA: Bool
    var c2paClaimGenerator: String?
    var c2paAction: String?
    var c2paHashAlgorithm: String?

    var resolution: String? {
        guard let w = imageWidth, let h = imageHeight else { return nil }
        return "\(w) x \(h)"
    }

    init(from dict: [String: Any]) {
        // Camera: combine Make + Model, avoiding duplication
        let make = (dict["Make"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (dict["Model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let make, let model {
            if model.lowercased().hasPrefix(make.lowercased()) {
                camera = model
            } else {
                camera = "\(make) \(model)"
            }
        } else {
            camera = model ?? make
        }

        lens = dict["LensModel"] as? String
        captureDate = dict["DateTimeOriginal"] as? String

        // Focal length
        if let fl = dict["FocalLength"] as? Double {
            let rounded = fl.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", fl) : String(format: "%.1f", fl)
            focalLength = "\(rounded) mm"
        } else if let fl = dict["FocalLength"] as? String {
            focalLength = fl
        }

        // Aperture
        if let fn = dict["FNumber"] as? Double {
            aperture = fn.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "f/%.0f", fn) : String(format: "f/%.1f", fn)
        }

        // Shutter speed
        if let et = dict["ExposureTime"] as? Double {
            if et >= 1 {
                shutterSpeed = String(format: "%.1f s", et)
            } else {
                let denom = Int(round(1.0 / et))
                shutterSpeed = "1/\(denom) s"
            }
        }

        // ISO
        if let isoVal = dict["ISO"] as? Int {
            iso = String(isoVal)
        } else if let isoVal = dict["ISO"] as? Double {
            iso = String(Int(isoVal))
        }

        // Resolution — prefer EXIF, fall back to File
        imageWidth = dict["ImageWidth"] as? Int ?? dict["File:ImageWidth"] as? Int
        imageHeight = dict["ImageHeight"] as? Int ?? dict["File:ImageHeight"] as? Int

        // Bit depth
        if let bps = dict["BitsPerSample"] as? Int {
            bitDepth = bps
        } else if let bpsArr = dict["BitsPerSample"] as? [Int], let first = bpsArr.first {
            bitDepth = first
        }

        // Color space
        if let cs = dict["ColorSpace"] as? Int {
            switch cs {
            case 1: colorSpace = "sRGB"
            case 2: colorSpace = "Adobe RGB"
            case 0xFFFF: colorSpace = "Uncalibrated"
            default: colorSpace = "Unknown (\(cs))"
            }
        } else if let cs = dict["ColorSpace"] as? String {
            colorSpace = cs
        }

        // C2PA — detect from JUMD/C2PA keys returned by -JUMBF:All
        hasC2PA = dict.keys.contains { $0.hasPrefix("JUMD") || $0.hasPrefix("C2PA") || $0 == "Claim_generator" }

        // Claim generator (ExifTool returns as "Claim_generator")
        c2paClaimGenerator = dict["Claim_generator"] as? String
            ?? dict["Claim_Generator_InfoName"] as? String

        // Action (e.g. "c2pa.created" → "Created")
        if let action = dict["ActionsAction"] as? String {
            c2paAction = action
                .replacingOccurrences(of: "c2pa.", with: "")
                .capitalized
        }

        // Hash algorithm
        c2paHashAlgorithm = dict["Alg"] as? String
    }
}
