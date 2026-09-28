import UIKit

/// Pictures placed inside a script (the "notebook" side of a script: a photo, a diagram, a
/// reference shot you want in front of you when you reach that line).
///
/// They live **in the Markdown itself** as a standard image link with a private scheme —
/// `![](tp-image:3F2A….jpg)` on its own line — and the pixels live on disk. That keeps the SwiftData
/// schema exactly as it was (no migration, nothing that can eat an existing script), keeps the
/// script body the single source of truth for undo/duplicate/export, and means an older build
/// that doesn't know about pictures simply shows the link as text instead of losing it.
enum ScriptImageMarkup {
    static let scheme = "tp-image:"

    static func token(for id: String) -> String { "![](\(scheme)\(id))" }

    /// IDs are generated here (UUID + extension), so anything else is rejected — which is also
    /// what stops a hand-edited or LAN-supplied link from pointing outside the images folder.
    private static let regex = try! NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\(tp-image:([A-Za-z0-9-]{1,64}\.(?:jpg|png))\)"#
    )

    struct Match {
        let range: NSRange
        let id: String
    }

    static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Match(range: $0.range, id: ns.substring(with: $0.range(at: 1)))
        }
    }

    static func isValidID(_ id: String) -> Bool {
        let probe = token(for: id)
        return matches(in: probe).first?.range.length == (probe as NSString).length
    }

    /// The text with every picture link removed — what word counts and card previews should see.
    static func strippingImages(from text: String) -> String {
        let ns = NSMutableString(string: text)
        for match in matches(in: text).reversed() {
            ns.replaceCharacters(in: match.range, with: "")
        }
        return ns as String
    }
}

/// Where the pixels live. Application Support rather than Documents on purpose: Documents is
/// visible in the Files app (that's where finished takes go), and a picture deleted from there
/// would silently vanish from the middle of a script.
enum ScriptImageStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScriptImages", isDirectory: true)
    }

    static func url(for id: String) -> URL? {
        guard ScriptImageMarkup.isValidID(id) else { return nil }
        return directory.appendingPathComponent(id)
    }

    /// Longest edge kept on disk. Big enough to stay sharp full-width on an iPad Pro, small enough
    /// that a script with a dozen photos in it doesn't turn into a few hundred megabytes.
    private static let maxPixelEdge: CGFloat = 2048

    /// Saves a picture and returns the ID to put in the script.
    static func save(_ image: UIImage) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prepared = downscaled(image)
        guard let data = prepared.jpegData(compressionQuality: 0.88) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let id = UUID().uuidString + ".jpg"
        try data.write(to: directory.appendingPathComponent(id), options: .atomic)
        cache.setObject(prepared, forKey: id as NSString)
        return id
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(for id: String) -> UIImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        guard let url = url(for: id), let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height) * image.scale
        let factor = min(1, maxPixelEdge / max(longest, 1))
        let target = CGSize(
            width: (size.width * image.scale * factor).rounded(),
            height: (size.height * image.scale * factor).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Redrawing also bakes in the photo's EXIF orientation, so it can't come out sideways.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// A script picture laid out inline in a `UITextView`. It sizes itself from the line it lands on,
/// so it follows the prompter card as it's resized and the editor as it rotates, with no
/// re-typesetting from outside: it fits a box as wide as the line and `boxAspect` times as tall,
/// keeping the photo's own shape.
final class ScriptImageAttachment: NSTextAttachment {
    let imageID: String
    private let boxAspect: CGFloat

    init(imageID: String, image: UIImage, boxAspect: CGFloat) {
        self.imageID = imageID
        self.boxAspect = boxAspect
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func fittedBounds(lineWidth: CGFloat) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0, lineWidth > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let boxWidth = lineWidth
        let boxHeight = lineWidth * boxAspect
        let scale = min(boxWidth / image.size.width, boxHeight / image.size.height)
        return CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    }

    // TextKit 2 (what both text views use).
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        fittedBounds(lineWidth: Self.lineWidth(proposedLineFragment, textContainer))
    }

    // TextKit 1, should UIKit ever fall back to it (it does for some text-view configurations).
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        fittedBounds(lineWidth: Self.lineWidth(lineFrag, textContainer))
    }

    private static func lineWidth(_ fragment: CGRect, _ container: NSTextContainer?) -> CGFloat {
        if fragment.width > 1 { return fragment.width }
        guard let container else { return 0 }
        return container.size.width - container.lineFragmentPadding * 2
    }
}
