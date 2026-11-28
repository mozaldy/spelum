import CoreGraphics
import Foundation
import PDFKit
import UIKit

private actor SlidePDFRenderWorker {
    func render(
        url: URL,
        pageIndex: Int,
        maxPixelDimension: CGFloat
    ) -> UIImage? {
        guard pageIndex >= 0,
              let document = PDFDocument(url: url),
              !document.isLocked,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            return nil
        }
        return Self.renderPage(page, maxPixelDimension: maxPixelDimension)
    }

    nonisolated static func renderPage(
        _ page: PDFPage,
        maxPixelDimension: CGFloat
    ) -> UIImage? {
        let clampedMax = min(max(maxPixelDimension, 64), 2048)
        let ratio = CGFloat(SlideDeckStorage.aspectRatio(for: page))
        let targetSize: CGSize
        if ratio >= 1 {
            targetSize = CGSize(
                width: clampedMax,
                height: max(1, (clampedMax / ratio).rounded())
            )
        } else {
            targetSize = CGSize(
                width: max(1, (clampedMax * ratio).rounded()),
                height: clampedMax
            )
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(UIColor.white.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: targetSize))

            cgContext.saveGState()
            // Flip UIKit coordinate system to PDF bottom-left origin.
            cgContext.translateBy(x: 0, y: targetSize.height)
            cgContext.scaleBy(x: 1, y: -1)
            let drawingTransform = page.transform(for: .cropBox)
            let pageBounds = page.bounds(for: .cropBox)
            let isQuarterTurn = page.rotation % 180 != 0
            let naturalWidth = max(1, isQuarterTurn ? pageBounds.height : pageBounds.width)
            let naturalHeight = max(1, isQuarterTurn ? pageBounds.width : pageBounds.height)
            let scaleX = targetSize.width / naturalWidth
            let scaleY = targetSize.height / naturalHeight
            let scale = min(scaleX, scaleY)
            cgContext.scaleBy(x: scale, y: scale)
            cgContext.concatenate(drawingTransform)
            page.draw(with: .cropBox, to: cgContext)
            cgContext.restoreGState()
        }
    }
}

@MainActor
final class SlideDeckRenderer {
    static let shared = SlideDeckRenderer()

    nonisolated static let maxCachedImages = 24
    nonisolated static let maxCacheBytes = 32 * 1024 * 1024

    private let cache: NSCache<NSString, UIImage>
    private let worker = SlidePDFRenderWorker()

    init(
        countLimit: Int = SlideDeckRenderer.maxCachedImages,
        totalCostLimit: Int = SlideDeckRenderer.maxCacheBytes
    ) {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        self.cache = cache
    }

    func cachedImage(
        url: URL,
        pageIndex: Int,
        maxPixelDimension: CGFloat
    ) -> UIImage? {
        let key = cacheKey(url: url, pageIndex: pageIndex, maxPixelDimension: maxPixelDimension)
        return cache.object(forKey: key)
    }

    func renderPage(
        url: URL,
        pageIndex: Int,
        maxPixelDimension: CGFloat
    ) async -> UIImage? {
        let bucketedDimension = bucketDimension(maxPixelDimension)
        let key = cacheKey(url: url, pageIndex: pageIndex, maxPixelDimension: bucketedDimension)
        if let existing = cache.object(forKey: key) {
            return existing
        }

        guard let rendered = await worker.render(
            url: url,
            pageIndex: pageIndex,
            maxPixelDimension: bucketedDimension
        ) else {
            return nil
        }

        let cost = estimatedByteCost(for: rendered)
        cache.setObject(rendered, forKey: key, cost: cost)
        return rendered
    }

    func renderPageSync(
        url: URL,
        pageIndex: Int,
        maxPixelDimension: CGFloat
    ) -> UIImage? {
        let bucketedDimension = bucketDimension(maxPixelDimension)
        let key = cacheKey(url: url, pageIndex: pageIndex, maxPixelDimension: bucketedDimension)
        if let existing = cache.object(forKey: key) {
            return existing
        }
        guard pageIndex >= 0,
              let document = PDFDocument(url: url),
              !document.isLocked,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex),
              let rendered = SlidePDFRenderWorker.renderPage(page, maxPixelDimension: bucketedDimension) else {
            return nil
        }
        cache.setObject(rendered, forKey: key, cost: estimatedByteCost(for: rendered))
        return rendered
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    private func bucketDimension(_ raw: CGFloat) -> CGFloat {
        let clamped = min(max(raw, 64), 2048)
        return (clamped / 32).rounded(.up) * 32
    }

    private func cacheKey(url: URL, pageIndex: Int, maxPixelDimension: CGFloat) -> NSString {
        "\(url.standardizedFileURL.path)#\(pageIndex)@\(Int(maxPixelDimension))" as NSString
    }

    private func estimatedByteCost(for image: UIImage) -> Int {
        let pixels = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
        return max(1, pixels * 4)
    }
}
