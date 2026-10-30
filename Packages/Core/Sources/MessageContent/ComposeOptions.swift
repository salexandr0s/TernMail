import Foundation

public enum ComposeFont: String, Codable, Sendable, CaseIterable {
    case sansSerif, serif, fixedWidth

    public var cssFamily: String {
        switch self {
        case .sansSerif: "Arial,Helvetica,sans-serif"
        case .serif: "Georgia,Times,serif"
        case .fixedWidth: "Menlo,Consolas,monospace"
        }
    }
}

/// Bytes live in an outgoing attachment; the document keeps only its stable CID.
public struct InlineImageReference: Codable, Sendable, Equatable {
    public var contentID: String
    public var altText: String

    public init(contentID: String, altText: String = "") {
        self.contentID = contentID
        self.altText = altText
    }

    public var isValid: Bool {
        !contentID.isEmpty && contentID.utf8.count <= 255 && contentID.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "@._-+".contains($0))
        }
    }
}
