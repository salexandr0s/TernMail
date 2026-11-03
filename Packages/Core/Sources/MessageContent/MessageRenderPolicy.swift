import Foundation

public struct MessageRenderPolicy: Sendable, Equatable {
    public var allowsRemoteImages: Bool
    public var inlineResources: InlineResourceMap
    public var textScale: Double

    public init(allowsRemoteImages: Bool = false, inlineResources: InlineResourceMap = .init(), textScale: Double = 1) {
        self.allowsRemoteImages = allowsRemoteImages
        self.inlineResources = inlineResources
        self.textScale = textScale.isFinite ? min(2, max(0.85, textScale)) : 1
    }

    public var contentSecurityPolicy: String {
        "default-src 'none'; img-src data: \(InlineResourceMap.scheme):\(allowsRemoteImages ? " https:" : ""); style-src 'unsafe-inline'; font-src data:"
    }
}
