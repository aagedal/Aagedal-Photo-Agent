import Foundation

/// Type-erased container for parsed image file data.
public enum ImageContainer: Sendable {
    case jpeg(JPEGFile)
    case tiff(TIFFFile)
    case png(PNGFile)
    case jpegXL(JXLFile)
    case avif(AVIFFile)
    case heif(HEIFFile)
    case webp(WebPFile)
    case cr3(CR3File)
    case pdf(PDFFile)
    case psd(PSDFile)
    case gif(GIFFile)
    case bmp(BMPFile)
    case svg(SVGFile)
}
