import SwiftUI

enum RehearsalSurfaceTheme: Equatable, Sendable {
    case standard
    case fullscreenStage

    var isDarkStage: Bool {
        self == .fullscreenStage
    }
}

struct AnnotatedScriptBlocksView: View {
    let blocks: [AnnotatedScriptBlock]
    let hasOnlyDirectionsOrNoSpeech: Bool
    let isAccessibilitySize: Bool
    let theme: RehearsalSurfaceTheme
    let scriptAccessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if blocks.isEmpty {
                emptyVisualSlidePlaceholder
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    blockView(block, index: index)
                }
                if hasOnlyDirectionsOrNoSpeech {
                    directionsOnlyNote
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(scriptAccessibilityIdentifier)
    }

    @ViewBuilder
    private func blockView(_ block: AnnotatedScriptBlock, index: Int) -> some View {
        switch block {
        case .speech(_, let tokens, _):
            let attributed = Self.makeAttributedSpeech(tokens: tokens, theme: theme)
            let spokenLabel = AnnotatedScriptInlineParser.accessibleDescription(for: tokens)
            Text(attributed)
                .font(speechFont)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(spokenLabel)
                .accessibilityIdentifier("annotatedSpeechBlock_\(index)")

        case .direction(_, _, let directionText):
            directionBlock(directionText, index: index)
        }
    }

    private func directionBlock(_ text: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(directionAccentColor)
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Label("Direction", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(directionAccentColor)

                Text(text)
                    .font(.callout.italic())
                    .foregroundStyle(directionBodyColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(directionSurfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(directionBorderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Direction: \(text)")
        .accessibilityIdentifier("annotatedDirectionBlock_\(index)")
    }

    private var emptyVisualSlidePlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(secondaryColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Visual-Only Slide")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryColor)
                Text("No spoken lines on this slide. Advance when ready.")
                    .font(.footnote)
                    .foregroundStyle(secondaryColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(directionSurfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("visualOnlySlidePlaceholder")
    }

    private var directionsOnlyNote: some View {
        Label("Directions only — no spoken lines on this slide.", systemImage: "speaker.slash")
            .font(.caption)
            .foregroundStyle(secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("directionsOnlySlideNote")
    }

    private var speechFont: Font {
        switch theme {
        case .standard:
            isAccessibilitySize ? .body : .title3
        case .fullscreenStage:
            isAccessibilitySize ? .body : .title2
        }
    }

    private var primaryColor: Color {
        theme.isDarkStage ? .white : .primary
    }

    private var secondaryColor: Color {
        theme.isDarkStage ? .white.opacity(0.80) : .secondary
    }

    private var directionAccentColor: Color {
        theme.isDarkStage ? Color(red: 0.99, green: 0.80, blue: 0.36) : Color.orange
    }

    private var directionBodyColor: Color {
        theme.isDarkStage ? Color.white.opacity(0.94) : Color.primary
    }

    private var directionSurfaceColor: Color {
        theme.isDarkStage ? Color.white.opacity(0.12) : Color.orange.opacity(0.10)
    }

    private var directionBorderColor: Color {
        theme.isDarkStage ? Color(red: 0.99, green: 0.80, blue: 0.36).opacity(0.45) : Color.orange.opacity(0.28)
    }

    static func makeAttributedSpeech(
        tokens: [AnnotatedInlineToken],
        theme: RehearsalSurfaceTheme
    ) -> AttributedString {
        var result = AttributedString()
        let textColor: Color = theme.isDarkStage ? .white : .primary
        let pauseColor: Color = theme.isDarkStage
            ? Color(red: 0.56, green: 0.88, blue: 1.0)
            : Color.indigo
        let pauseBg: Color = theme.isDarkStage
            ? Color.white.opacity(0.14)
            : Color.indigo.opacity(0.12)
        let risingColor: Color = theme.isDarkStage
            ? Color(red: 0.45, green: 0.95, blue: 0.72)
            : Color.teal
        let fallingColor: Color = theme.isDarkStage
            ? Color(red: 1.0, green: 0.72, blue: 0.42)
            : Color.orange

        for token in tokens {
            switch token {
            case .text(let string):
                var segment = AttributedString(string)
                segment.foregroundColor = textColor
                result.append(segment)

            case .pause(let kind):
                var segment = AttributedString(" \(kind.displayMark) ")
                segment.foregroundColor = pauseColor
                segment.backgroundColor = pauseBg
                segment.font = Font.callout.monospaced().weight(.bold)
                result.append(segment)

            case .pitch(let direction, let symbol):
                var segment = AttributedString(" \(symbol) ")
                segment.foregroundColor = direction == .rising ? risingColor : fallingColor
                segment.font = Font.callout.weight(.bold)
                result.append(segment)
            }
        }
        return result
    }
}
