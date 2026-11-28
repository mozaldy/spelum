import Foundation

enum PresentationImportError: LocalizedError, Equatable, Sendable {
    case emptyScript
    case unreadableFile
    case invalidUTF8
    case unreadableOrCorruptPDF
    case emptyPDF
    case lockedPDF
    case invalidDeckPath
    case deckCopyFailed
    case slideCountMismatch(headings: Int, pages: Int)

    var errorDescription: String? {
        switch self {
        case .emptyScript:
            "The script is empty. Paste or import non-empty UTF-8 text."
        case .unreadableFile:
            "The selected file could not be read."
        case .invalidUTF8:
            "The selected file is not valid UTF-8 plain text."
        case .unreadableOrCorruptPDF:
            "The selected PDF could not be opened. Choose a valid PDF export."
        case .emptyPDF:
            "The selected PDF has no pages."
        case .lockedPDF:
            "The selected PDF is password-protected. Export an unlocked PDF and try again."
        case .invalidDeckPath:
            "The slide deck storage path is invalid."
        case .deckCopyFailed:
            "The slide deck could not be copied into Spelum storage."
        case .slideCountMismatch(let headings, let pages):
            if headings == 0 {
                "PDF has \(pages) \(pages == 1 ? "page" : "pages"), " +
                    "but the script has no ## slide headings."
            } else {
                "Script has \(headings) \(headings == 1 ? "slide heading" : "slide headings") " +
                    "for \(pages) PDF \(pages == 1 ? "page" : "pages"). " +
                    "Match one ## heading per PDF page before importing."
            }
        }
    }
}
