import UniformTypeIdentifiers

enum SupportedImageFormats {
    static let all: Set<UTType> = [
        .jpeg,
        .png,
        .tiff,
        .heic,
        .heif,
        .rawImage,
        .bmp,
        .gif,
        .webP,
        UTType("public.avif") ?? .image,
        UTType("public.jxl") ?? .image,
        UTType("com.adobe.raw-image") ?? .rawImage,
        UTType("com.canon.cr2-raw-image") ?? .rawImage,
        UTType("com.canon.cr3-raw-image") ?? .rawImage,
        UTType("com.nikon.nrw-raw-image") ?? .rawImage,
        UTType("com.nikon.raw-image") ?? .rawImage,
        UTType("com.sony.arw-raw-image") ?? .rawImage,
        UTType("com.fuji.raw-image") ?? .rawImage,
        UTType("com.adobe.dng-raw-image") ?? .rawImage,
        UTType("com.panasonic.rw2-raw-image") ?? .rawImage,
        UTType("com.olympus.raw-image") ?? .rawImage,
    ]

    static let fileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif",
        "bmp", "gif", "webp", "avif", "jxl",
        "raw", "cr2", "cr3", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw",
    ]

    static let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw",
    ]

    static let jpegExtensions: Set<String> = [
        "jpg", "jpeg",
    ]

    static func isSupported(url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func isRaw(url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func isJPEG(url: URL) -> Bool {
        jpegExtensions.contains(url.pathExtension.lowercased())
    }
}
