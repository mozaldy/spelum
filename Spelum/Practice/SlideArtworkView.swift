import CoreGraphics
import SwiftUI
import UIKit

struct SlideArtworkView: View {
    let pdfURL: URL
    let pageIndex: Int
    let aspectRatio: CGFloat
    let slideNumber: Int
    let totalSlides: Int
    let visibleSlideTitle: String?
    let maxHeight: CGFloat
    let isDarkStage: Bool
    var compact: Bool = false

    @Environment(\.displayScale) private var displayScale
    @State private var renderedImage: UIImage?
    @State private var loadFailed = false
    @State private var showingEnlargedSheet = false

    private var clampedAspectRatio: CGFloat {
        aspectRatio.isFinite && aspectRatio > 0.25 && aspectRatio < 4.5 ? aspectRatio : (16.0 / 9.0)
    }

    var body: some View {
        Button {
            showingEnlargedSheet = true
        } label: {
            artworkFrame
        }
        .buttonStyle(.plain)
        .frame(maxWidth: compact ? nil : .infinity, alignment: .center)
        .accessibilityLabel(accessibleArtworkLabel)
        .accessibilityHint("Double-tap to open an enlarged zoomable view of this slide.")
        .accessibilityIdentifier("slideArtworkButton_page_\(pageIndex)")
        .task(id: "\(pdfURL.path)|\(pageIndex)|\(Int(maxHeight))|\(Int(displayScale))") {
            loadFailed = false
            let maxDimension = max(maxHeight * clampedAspectRatio, maxHeight, 360) * max(displayScale, 2)
            let image = await SlideDeckRenderer.shared.renderPage(
                url: pdfURL,
                pageIndex: pageIndex,
                maxPixelDimension: maxDimension
            )
            if !Task.isCancelled {
                renderedImage = image
                loadFailed = image == nil
            }
        }
        .sheet(isPresented: $showingEnlargedSheet) {
            EnlargedSlideSheet(
                pdfURL: pdfURL,
                pageIndex: pageIndex,
                aspectRatio: clampedAspectRatio,
                slideNumber: slideNumber,
                totalSlides: totalSlides,
                visibleSlideTitle: visibleSlideTitle
            )
        }
    }

    private var artworkFrame: some View {
        let cornerRadius: CGFloat = compact ? 8 : 12
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isDarkStage ? Color.white.opacity(0.10) : Color(.tertiarySystemGroupedBackground))

                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - 1, 6), style: .continuous))
                } else if loadFailed {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.richtext")
                            .font(compact ? .caption : .title3)
                        if !compact {
                            Text("Slide page \(pageIndex + 1) unavailable")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(isDarkStage ? Color.white.opacity(0.75) : .secondary)
                    .padding(compact ? 6 : 12)
                } else {
                    ProgressView()
                        .scaleEffect(compact ? 0.75 : 1.0)
                        .tint(isDarkStage ? .white : nil)
                }
            }
            .aspectRatio(clampedAspectRatio, contentMode: .fit)
            .frame(
                maxWidth: compact ? min(maxHeight * clampedAspectRatio, 132) : nil,
                maxHeight: maxHeight
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isDarkStage ? Color.white.opacity(0.24) : Color.primary.opacity(0.14),
                        lineWidth: 1
                    )
            }

            enlargeBadge
        }
    }

    @ViewBuilder
    private var enlargeBadge: some View {
        if compact {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Color.black.opacity(0.66), in: Circle())
                .padding(4)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.weight(.semibold))
                Text("Enlarge")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.64), in: Capsule())
            .padding(8)
            .accessibilityHidden(true)
        }
    }

    private var accessibleArtworkLabel: String {
        var parts = ["Slide \(slideNumber) of \(max(totalSlides, 1))"]
        if let title = visibleSlideTitle, !title.isEmpty {
            parts.append(title)
        }
        parts.append("PDF page \(pageIndex + 1)")
        return parts.joined(separator: ", ")
    }
}

struct EnlargedSlideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    let pdfURL: URL
    let pageIndex: Int
    let aspectRatio: CGFloat
    let slideNumber: Int
    let totalSlides: Int
    let visibleSlideTitle: String?

    @State private var highResImage: UIImage?
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureScale: CGFloat = 1.0

    private var effectiveScale: CGFloat {
        min(max(zoomScale * gestureScale, 1.0), 4.0)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        if let highResImage {
                            Image(uiImage: highResImage)
                                .resizable()
                                .aspectRatio(aspectRatio, contentMode: .fit)
                                .frame(
                                    width: max(geometry.size.width - 24, 200) * effectiveScale,
                                    height: max(geometry.size.height - 24, 200) * effectiveScale
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .shadow(color: Color.black.opacity(0.2), radius: 8, y: 2)
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        zoomScale = zoomScale > 1.2 ? 1.0 : 2.2
                                    }
                                }
                        } else {
                            ProgressView("Rendering slide…")
                                .frame(
                                    width: max(geometry.size.width - 24, 200),
                                    height: max(geometry.size.height - 24, 200)
                                )
                        }
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height
                    )
                    .padding(12)
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            gestureScale = value.magnification
                        }
                        .onEnded { value in
                            zoomScale = min(max(zoomScale * value.magnification, 1.0), 4.0)
                            gestureScale = 1.0
                        }
                )
            }
            .background(Color(.systemBackground))
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if effectiveScale > 1.05 {
                        Button("Reset Zoom") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                zoomScale = 1.0
                                gestureScale = 1.0
                            }
                        }
                        .accessibilityIdentifier("resetEnlargedSlideZoomButton")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("closeEnlargedSlideButton")
                }
            }
            .task(id: "\(pdfURL.path)|\(pageIndex)|enlarged|\(Int(displayScale))") {
                let targetPixels = max(1600, 1200 * max(displayScale, 2))
                highResImage = await SlideDeckRenderer.shared.renderPage(
                    url: pdfURL,
                    pageIndex: pageIndex,
                    maxPixelDimension: targetPixels
                )
            }
        }
        .accessibilityIdentifier("enlargedSlideSheet")
    }

    private var sheetTitle: String {
        Self.resolvedSheetTitle(
            slideNumber: slideNumber,
            totalSlides: totalSlides,
            pageIndex: pageIndex,
            visibleSlideTitle: visibleSlideTitle
        )
    }

    static func resolvedSheetTitle(
        slideNumber: Int,
        totalSlides: Int,
        pageIndex: Int,
        visibleSlideTitle: String?
    ) -> String {
        if let title = visibleSlideTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if startsWithSlideNumberPrefix(title) {
                return title
            }
            return "Slide \(slideNumber): \(title)"
        }
        return "Slide \(slideNumber) of \(max(totalSlides, 1)) · Page \(pageIndex + 1)"
    }

    private static func startsWithSlideNumberPrefix(_ title: String) -> Bool {
        title.range(
            of: #"^slide\s+\d+(?:$|[\s:.\-–—·])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
