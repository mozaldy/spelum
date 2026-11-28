import CoreGraphics
import SwiftUI

struct ImportPairingPreviewSection: View {
    let plan: SlidePairingPlan
    let stagedPDF: InspectedPDFDeck?
    let onReplacePDF: () -> Void
    let onRemovePDF: () -> Void

    var body: some View {
        Section {
            summaryBanner
            if plan.hasMismatch {
                mismatchControls
            }
            if plan.rows.isEmpty {
                emptyPreviewHint
            } else {
                ForEach(plan.rows) { row in
                    previewRowView(row)
                }
            }
        } header: {
            Text(plan.hasPDF ? "Slide Pairing Preview" : "Script Structure Preview")
        } footer: {
            Text(footerText)
        }
    }

    private var summaryBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summaryIconName)
                .foregroundStyle(summaryIconColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(summaryHeadline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("importPairingSummaryTitle")

                if let mismatch = plan.mismatchSummary {
                    Text(mismatch)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("importPairingMismatchSummary")
                } else {
                    Text(summaryDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("importPairingSummaryDetail")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var mismatchControls: some View {
        HStack(spacing: 12) {
            Button {
                onReplacePDF()
            } label: {
                Label("Replace PDF", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("mismatchReplacePDFButton")

            Button(role: .destructive) {
                onRemovePDF()
            } label: {
                Label("Remove PDF", systemImage: "trash")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("mismatchRemovePDFButton")
        }
    }

    private var emptyPreviewHint: some View {
        Text(
            "Plain scripts import as one section. Add # Section and ## Slide headings " +
            "to group sections and pair slides with a PDF deck."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("importPlainScriptHint")
    }

    private func previewRowView(_ row: SlidePairingPreviewRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowLeadingArtwork(for: row)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    statusPill(for: row)
                    if let sectionTitle = row.sectionTitle, !sectionTitle.isEmpty {
                        Text(sectionTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(rowHeadingTitle(for: row))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.status == .unmatchedPDFPage ? .red : .primary)
                    .lineLimit(2)

                Text(rowSpokenPreview(for: row))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("importPairingRow_\(row.orderIndex)")
    }

    @ViewBuilder
    private func rowLeadingArtwork(for row: SlidePairingPreviewRow) -> some View {
        if let pdf = stagedPDF, let pageIndex = row.pdfPageIndex {
            SlideThumbnailView(
                pdfURL: pdf.stagedURL,
                pageIndex: pageIndex,
                aspectRatio: CGFloat(row.pdfAspectRatio ?? (16.0 / 9.0)),
                targetWidth: 76
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        row.status == .unmatchedHeading
                            ? Color.orange.opacity(0.15)
                            : Color(.secondarySystemBackground)
                    )
                Image(
                    systemName: row.status == .unmatchedHeading
                        ? "exclamationmark.triangle.fill"
                        : "rectangle.on.rectangle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.status == .unmatchedHeading ? .orange : .secondary)
            }
            .frame(width: 76, height: 48)
            .accessibilityHidden(true)
        }
    }

    private func statusPill(for row: SlidePairingPreviewRow) -> some View {
        let label: String
        let tint: Color
        switch row.status {
        case .scriptOnly:
            label = "Slide \(row.orderIndex + 1)"
            tint = .accentColor
        case .paired:
            label = "Page \((row.pdfPageIndex ?? row.orderIndex) + 1)"
            tint = .green
        case .unmatchedHeading:
            label = "No PDF page"
            tint = .orange
        case .unmatchedPDFPage:
            label = "Page \((row.pdfPageIndex ?? row.orderIndex) + 1) unmatched"
            tint = .red
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func rowHeadingTitle(for row: SlidePairingPreviewRow) -> String {
        if let title = row.slideHeadingTitle, !title.isEmpty {
            return title
        }
        return "Unmatched PDF Page \((row.pdfPageIndex ?? row.orderIndex) + 1)"
    }

    private func rowSpokenPreview(for row: SlidePairingPreviewRow) -> String {
        if row.status == .unmatchedPDFPage {
            return "Add a matching ## heading in the script or replace the PDF."
        }
        if let line = row.firstSpokenLine, !line.isEmpty {
            return line
        }
        if row.hasOnlyDirectionsOrNoSpeech {
            return "Directions only — no spoken text"
        }
        return "Empty slide"
    }

    private var summaryIconName: String {
        if plan.hasMismatch {
            return "exclamationmark.triangle.fill"
        }
        if plan.hasPDF {
            return "checkmark.circle.fill"
        }
        return "text.document"
    }

    private var summaryIconColor: Color {
        if plan.hasMismatch { return .red }
        if plan.hasPDF { return .green }
        return .accentColor
    }

    private var summaryHeadline: String {
        let sectionCount = plan.parsedScript.sections.count
        let sectionLabel = sectionCount == 1 ? "1 section" : "\(sectionCount) sections"
        let headingCount = plan.explicitHeadingCount
        let slideLabel = headingCount == 1 ? "1 slide heading" : "\(headingCount) slide headings"
        if let pageCount = plan.pdfPageCount {
            let pageLabel = pageCount == 1 ? "1 PDF page" : "\(pageCount) PDF pages"
            return "\(slideLabel) · \(pageLabel)"
        }
        if headingCount > 0 {
            return "\(sectionLabel) · \(slideLabel)"
        }
        return "\(sectionLabel) · Script only"
    }

    private var summaryDetail: String {
        if plan.hasPDF {
            return "Pages pair 1-to-1 with ## slide headings in order across sections. " +
                "Section headings (#) and leading notes consume zero pages."
        }
        if plan.explicitHeadingCount > 0 {
            return "Ready to import without slides, or attach a static Keynote PDF to pair in order."
        }
        return "Ready to import as a single script-only section."
    }

    private var footerText: String {
        plan.hasPDF
            ? "Paired import requires exactly one PDF page for each ## slide heading."
            : "Lines starting with # create sections; lines starting with ## create slides."
    }
}
