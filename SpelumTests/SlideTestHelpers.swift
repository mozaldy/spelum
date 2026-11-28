import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import UIKit
@testable import Spelum

enum SyntheticPDFTestHelper {
    static func writeMultiPagePDF(
        to url: URL,
        pageTitles: [String],
        pageSize: CGSize = CGSize(width: 640, height: 360)
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for (index, title) in pageTitles.enumerated() {
                context.beginPage()
                let hue = CGFloat(index % 6) / 6.0
                UIColor(hue: hue, saturation: 0.25, brightness: 0.96, alpha: 1.0).setFill()
                context.fill(bounds)

                let accentRect = CGRect(x: 24, y: 24, width: pageSize.width - 48, height: 48)
                UIColor(hue: hue, saturation: 0.6, brightness: 0.55, alpha: 1.0).setFill()
                UIBezierPath(roundedRect: accentRect, cornerRadius: 10).fill()

                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 22),
                    .foregroundColor: UIColor.white
                ]
                let label = "Page \(index + 1): \(title)" as NSString
                label.draw(
                    in: CGRect(x: 38, y: 34, width: pageSize.width - 76, height: 34),
                    withAttributes: headerAttrs
                )

                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 16),
                    .foregroundColor: UIColor.darkGray
                ]
                let body = "Synthetic rehearsal slide artwork #\(index + 1)" as NSString
                body.draw(
                    in: CGRect(x: 38, y: 110, width: pageSize.width - 76, height: 80),
                    withAttributes: bodyAttrs
                )
            }
        }
        try data.write(to: url, options: .atomic)
    }

    static func writeLockedPDF(to url: URL, pageCount: Int = 2) throws {
        let plainURL = url.deletingLastPathComponent()
            .appendingPathComponent("plain-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: plainURL) }

        let titles = (1 ... max(pageCount, 1)).map { "Locked Slide \($0)" }
        try writeMultiPagePDF(to: plainURL, pageTitles: titles)
        guard let document = PDFDocument(url: plainURL) else {
            throw PresentationImportError.unreadableOrCorruptPDF
        }
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: "secret-user",
            .ownerPasswordOption: "secret-owner"
        ]
        guard document.write(to: url, withOptions: options) else {
            throw PresentationImportError.deckCopyFailed
        }
    }

    static func writeEmptyPDF(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
    }

    static func writeCorruptPDF(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let garbage = Data("This is not a valid PDF header or document.".utf8)
        try garbage.write(to: url, options: .atomic)
    }
}

@MainActor
enum RehearsalAccessibilityInspector {
    static func collectStrings<V: View>(from view: V, size: CGSize = CGSize(width: 393, height: 852)) -> [String] {
        let host = UIHostingController(rootView: view)
        let window = makeWindow(size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        var collected: [String] = []
        var visited = Set<ObjectIdentifier>()
        visit(host.view, collected: &collected, visited: &visited)
        window.isHidden = true
        return collected
    }

    private static func makeWindow(size: CGSize) -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            return window
        }
        return UIWindow(frame: CGRect(origin: .zero, size: size))
    }

    private static func visit(
        _ object: AnyObject,
        collected: inout [String],
        visited: inout Set<ObjectIdentifier>
    ) {
        let id = ObjectIdentifier(object)
        guard !visited.contains(id) else { return }
        visited.insert(id)

        if let nsObj = object as? NSObject {
            appendAccessibilityStrings(from: nsObj, into: &collected)
            let count = nsObj.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0 ..< count {
                    if let child = nsObj.accessibilityElement(at: index) as AnyObject? {
                        visit(child, collected: &collected, visited: &visited)
                    }
                }
            }
            if let elements = nsObj.accessibilityElements as? [AnyObject] {
                for element in elements {
                    visit(element, collected: &collected, visited: &visited)
                }
            }
        }

        if let view = object as? UIView {
            for subview in view.subviews {
                visit(subview, collected: &collected, visited: &visited)
            }
        }
    }

    private static func appendAccessibilityStrings(from object: NSObject, into collected: inout [String]) {
        if let label = object.accessibilityLabel, !label.isEmpty {
            collected.append(label)
        }
        if let value = object.accessibilityValue, !value.isEmpty {
            collected.append(value)
        }
        if let hint = object.accessibilityHint, !hint.isEmpty {
            collected.append(hint)
        }
        if let labelView = object as? UILabel, let text = labelView.text, !text.isEmpty {
            collected.append(text)
        }
    }
}
