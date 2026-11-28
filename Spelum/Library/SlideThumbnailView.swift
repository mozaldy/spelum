import CoreGraphics
import SwiftUI
import UIKit

struct SlideThumbnailView: View {
    let pdfURL: URL
    let pageIndex: Int
    let aspectRatio: CGFloat
    let targetWidth: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var renderedImage: UIImage?
    @State private var loadFailed = false

    private var clampedAspectRatio: CGFloat {
        aspectRatio.isFinite && aspectRatio > 0.2 && aspectRatio < 5.0 ? aspectRatio : (16.0 / 9.0)
    }

    private var targetHeight: CGFloat {
        max(36, targetWidth / clampedAspectRatio)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if loadFailed {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: targetWidth, height: targetHeight)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .task(id: "\(pdfURL.path)|\(pageIndex)|\(Int(targetWidth))|\(Int(displayScale))") {
            loadFailed = false
            let maxPixelDimension = max(targetWidth, targetHeight) * max(displayScale, 2)
            let image = await SlideDeckRenderer.shared.renderPage(
                url: pdfURL,
                pageIndex: pageIndex,
                maxPixelDimension: maxPixelDimension
            )
            if !Task.isCancelled {
                renderedImage = image
                loadFailed = image == nil
            }
        }
        .accessibilityLabel("PDF page \(pageIndex + 1) thumbnail")
    }
}
