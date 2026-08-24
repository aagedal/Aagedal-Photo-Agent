import Foundation

/// XMP namespace constants and IIM-to-XMP mapping.
public enum XMPNamespace: Sendable {
    public static let xmpIdentifier = "http://ns.adobe.com/xap/1.0/\0"

    public static let dc        = "http://purl.org/dc/elements/1.1/"
    public static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    public static let iptcCore  = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
    public static let iptcExt   = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    public static let xmp       = "http://ns.adobe.com/xap/1.0/"
    public static let xmpRights = "http://ns.adobe.com/xap/1.0/rights/"
    public static let rdf       = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let mwgRegions = "http://www.metadataworkinggroup.com/schemas/regions/"
    public static let plus      = "http://ns.useplus.org/ldf/xmp/1.0/"
    public static let stArea    = "http://ns.adobe.com/xmp/sType/Area#"
    public static let stDim     = "http://ns.adobe.com/xmp/sType/Dimensions#"
    public static let exif      = "http://ns.adobe.com/exif/1.0/"
    public static let tiff      = "http://ns.adobe.com/tiff/1.0/"
    public static let aux       = "http://ns.adobe.com/exif/1.0/aux/"
    public static let exifEX    = "http://cipa.jp/exif/1.0/"
    public static let xmpMM     = "http://ns.adobe.com/xap/1.0/mm/"
    public static let stEvt     = "http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"
    public static let stRef     = "http://ns.adobe.com/xap/1.0/sType/ResourceRef#"
    public static let pdf       = "http://ns.adobe.com/pdf/1.3/"
    public static let crs       = "http://ns.adobe.com/camera-raw-settings/1.0/"
    public static let xmpDM     = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
    /// Adobe Lightroom — `lr:hierarchicalSubject` (Bag of "Family|Vacation|Beach"-style
    /// pipe-delimited paths) is how Lightroom Classic and Photo Mechanic store
    /// hierarchical keywords.
    public static let lr        = "http://ns.adobe.com/lightroom/1.0/"
    /// Creative Commons rights namespace (cc:license, cc:attributionURL, etc.).
    public static let cc        = "http://creativecommons.org/ns#"
    /// Publishing Requirements for Industry Standard Metadata — used by news
    /// wire services and DAMs alongside IPTC photometadata.
    public static let prism     = "http://prismstandard.org/namespaces/basic/2.0/"
    /// C2PA / CAI provenance carried in XMP (claim generators, hard bindings).
    /// Survives even when the JUMBF block is stripped from the carrier file.
    public static let c2pa      = "http://ns.c2pa.org/c2pa/1.0/"

    // MARK: - Google Spatial / MotionPhoto namespaces (https://developers.google.com/streetview/spherical-metadata)

    /// Google panorama metadata — full/cropped image dimensions, projection
    /// type, initial view direction. Standard for 360 / spherical images
    /// (Pixel, Ricoh Theta, Insta360, GoPro Max).
    public static let gPano     = "http://ns.google.com/photos/1.0/panorama/"
    /// Google MotionPhoto / spatial-media schema (`GCamera:MicroVideo`,
    /// `GCamera:MotionPhoto`, etc.). Embedded MOVs in Pixel / Samsung
    /// MotionPhoto JPEGs and HEICs.
    public static let gCamera   = "http://ns.google.com/photos/1.0/camera/"
    /// Spatial-audio companion to `gCamera`.
    public static let gAudio    = "http://ns.google.com/photos/1.0/audio/"
    /// Google motion-photo image-track schema (start frame, MIME, etc.).
    public static let gImage    = "http://ns.google.com/photos/1.0/image/"
    /// Google depth-map schema — depth/format/units for portrait-mode photos
    /// (Pixel "Photos by Google" depth maps, ARCore output).
    public static let gDepth    = "http://ns.google.com/photos/1.0/depthmap/"
    /// Google focus / refocus namespace (blur radius, focal-table metadata).
    public static let gFocus    = "http://ns.google.com/photos/1.0/focus/"

    /// Mapping from IPTC IIM tags to XMP namespace + property.
    public static let iimToXMP: [IPTCTag: (namespace: String, property: String)] = [
        .objectName:                    (dc, "title"),
        .keywords:                      (dc, "subject"),
        .specialInstructions:           (photoshop, "Instructions"),
        .dateCreated:                   (photoshop, "DateCreated"),
        .byline:                        (dc, "creator"),
        .bylineTitle:                   (photoshop, "AuthorsPosition"),
        .city:                          (photoshop, "City"),
        .sublocation:                   (iptcCore, "Location"),
        .provinceState:                 (photoshop, "State"),
        .countryPrimaryLocationCode:    (iptcCore, "CountryCode"),
        .countryPrimaryLocationName:    (photoshop, "Country"),
        .originalTransmissionReference: (photoshop, "TransmissionReference"),
        .headline:                      (photoshop, "Headline"),
        .credit:                        (photoshop, "Credit"),
        .source:                        (photoshop, "Source"),
        .copyrightNotice:               (dc, "rights"),
        .captionAbstract:               (dc, "description"),
        .writerEditor:                  (photoshop, "CaptionWriter"),
    ]

    /// Reverse lookup: find namespace URI from prefix (e.g. "dc" → "http://purl.org/dc/elements/1.1/").
    public static func namespace(for prefix: String) -> String? {
        prefixes.first { $0.value == prefix }?.key
    }

    /// Namespace prefix mappings for XMP serialization.
    public static let prefixes: [String: String] = [
        dc: "dc",
        photoshop: "photoshop",
        iptcCore: "Iptc4xmpCore",
        iptcExt: "Iptc4xmpExt",
        xmp: "xmp",
        xmpRights: "xmpRights",
        rdf: "rdf",
        plus: "plus",
        mwgRegions: "mwg-rs",
        stArea: "stArea",
        stDim: "stDim",
        exif: "exif",
        tiff: "tiff",
        aux: "aux",
        exifEX: "exifEX",
        xmpMM: "xmpMM",
        stEvt: "stEvt",
        stRef: "stRef",
        pdf: "pdf",
        crs: "crs",
        xmpDM: "xmpDM",
        lr: "lr",
        cc: "cc",
        prism: "prism",
        c2pa: "c2pa",
        gPano: "GPano",
        gCamera: "GCamera",
        gAudio: "GAudio",
        gImage: "GImage",
        gDepth: "GDepth",
        gFocus: "GFocus",
    ]
}
