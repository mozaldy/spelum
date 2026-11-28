import CoreGraphics
import Foundation
import PDFKit

nonisolated struct SectionSlideReference: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let slideOrderIndex: Int
    let headingTitle: String
    let deckRelativePath: String?
    let pdfPageIndex: Int?
    let pageAspectRatio: Double?

    init(
        id: UUID = UUID(),
        slideOrderIndex: Int,
        headingTitle: String,
        deckRelativePath: String? = nil,
        pdfPageIndex: Int? = nil,
        pageAspectRatio: Double? = nil
    ) {
        self.id = id
        self.slideOrderIndex = max(0, slideOrderIndex)
        self.headingTitle = headingTitle
        self.deckRelativePath = deckRelativePath
        self.pdfPageIndex = pdfPageIndex
        self.pageAspectRatio = pageAspectRatio
    }

    var resolvedAspectRatio: CGFloat {
        if let ratio = pageAspectRatio, ratio.isFinite, ratio > 0.1, ratio < 10 {
            return CGFloat(ratio)
        }
        return 16.0 / 9.0
    }
}

nonisolated struct InspectedPDFDeck: Equatable, Hashable, Sendable {
    let stagedURL: URL
    let displayFileName: String
    let pageCount: Int
    let pageAspectRatios: [Double]
}

nonisolated struct CopiedSlideDeck: Equatable, Sendable {
    let relativePath: String
    let pageCount: Int
    let pageAspectRatios: [Double]
}

nonisolated enum SlideDeckStorage {
    static let decksSubdirectoryName = "Decks"
    static let stagingSubdirectoryName = "SpelumPDFImportStaging"

    static func defaultStorageRootURL() -> URL {
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appendingPathComponent("Spelum", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("Spelum", isDirectory: true)
    }

    static func opaqueRelativeDeckPath(for deckID: UUID = UUID()) -> String {
        "\(decksSubdirectoryName)/\(deckID.uuidString.lowercased()).pdf"
    }

    static func resolvedDeckURL(
        for relativePath: String,
        storageRootURL: URL
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            throw PresentationImportError.invalidDeckPath
        }
        let components = trimmed.split(separator: "/")
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw PresentationImportError.invalidDeckPath
        }

        let rootStandardized = storageRootURL.standardizedFileURL
        let resolved = rootStandardized.appendingPathComponent(trimmed).standardizedFileURL
        let rootPrefix = rootStandardized.path.hasSuffix("/")
            ? rootStandardized.path
            : rootStandardized.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw PresentationImportError.invalidDeckPath
        }
        return resolved
    }

    static func inspectPDFData(_ data: Data) throws -> (pageCount: Int, pageAspectRatios: [Double]) {
        guard !data.isEmpty else {
            throw PresentationImportError.emptyPDF
        }
        guard let document = PDFDocument(data: data) else {
            throw PresentationImportError.unreadableOrCorruptPDF
        }
        if document.isLocked {
            throw PresentationImportError.lockedPDF
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PresentationImportError.emptyPDF
        }

        var ratios: [Double] = []
        ratios.reserveCapacity(pageCount)
        for index in 0 ..< pageCount {
            if let page = document.page(at: index) {
                ratios.append(aspectRatio(for: page))
            } else {
                ratios.append(16.0 / 9.0)
            }
        }
        return (pageCount, ratios)
    }

    static func inspectPDF(at sourceURL: URL) throws -> (pageCount: Int, pageAspectRatios: [Double]) {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw PresentationImportError.unreadableOrCorruptPDF
        }
        return try inspectPDFData(data)
    }

    static func inspectAndStagePDF(from sourceURL: URL) throws -> InspectedPDFDeck {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw PresentationImportError.unreadableOrCorruptPDF
        }

        let inspected = try inspectPDFData(data)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(stagingSubdirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let stagedURL = stagingDir.appendingPathComponent("\(UUID().uuidString.lowercased()).pdf")
            try data.write(to: stagedURL, options: .atomic)
            let displayName = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return InspectedPDFDeck(
                stagedURL: stagedURL,
                displayFileName: displayName.isEmpty ? "Slides.pdf" : displayName,
                pageCount: inspected.pageCount,
                pageAspectRatios: inspected.pageAspectRatios
            )
        } catch {
            throw PresentationImportError.deckCopyFailed
        }
    }

    static func removeStagedFile(at url: URL) {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(stagingSubdirectoryName, isDirectory: true)
            .standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(stagingRoot) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func copyPDFToAppStorage(
        from sourceURL: URL,
        storageRootURL: URL,
        deckID: UUID = UUID()
    ) throws -> CopiedSlideDeck {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw PresentationImportError.unreadableOrCorruptPDF
        }

        let inspected = try inspectPDFData(data)
        let decksDir = storageRootURL.appendingPathComponent(decksSubdirectoryName, isDirectory: true)
        let relativePath = opaqueRelativeDeckPath(for: deckID)
        let destinationURL = try resolvedDeckURL(for: relativePath, storageRootURL: storageRootURL)

        do {
            try FileManager.default.createDirectory(at: decksDir, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDir = decksDir
            try? mutableDir.setResourceValues(resourceValues)
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            throw PresentationImportError.deckCopyFailed
        }

        return CopiedSlideDeck(
            relativePath: relativePath,
            pageCount: inspected.pageCount,
            pageAspectRatios: inspected.pageAspectRatios
        )
    }

    static func removeDeckFile(relativePath: String, storageRootURL: URL) {
        guard let url = try? resolvedDeckURL(for: relativePath, storageRootURL: storageRootURL) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    static func aspectRatio(for page: PDFPage) -> Double {
        let bounds = page.bounds(for: .cropBox)
        let isQuarterTurn = page.rotation % 180 != 0
        let width = isQuarterTurn ? bounds.height : bounds.width
        let height = isQuarterTurn ? bounds.width : bounds.height
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return Double(width / height)
    }
}
