import AppKit
import ImageIO
import MailStore

/// ImageIO creates the pixels on a serial actor. The immutable CGImage is only
/// wrapped in an NSImage on the main actor; no AppKit object crosses executors.
struct PreparedContactThumbnail: @unchecked Sendable {
    let pixels: CGImage
    var cost: Int { pixels.bytesPerRow * pixels.height }
}

private actor ContactThumbnailDecoder {
    static let shared = ContactThumbnailDecoder()

    func decode(_ data: Data) throws -> PreparedContactThumbnail {
        try Task.checkCancellation()
        let clean = try ContactPhotoImages.thumbnail(data)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(clean as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ContactPhotoImages.PhotoError.invalidImage
        }
        return PreparedContactThumbnail(pixels: pixels)
    }
}

struct ContactPhotoCacheKey: Hashable, Sendable {
    let contextID: String
    let accountID: String
    let resource: String
    let version: String
    let fetchedAt: Date?
    let size: Int

    init(_ record: ContactPhotoRecord, contextID: String) {
        self.contextID = contextID
        accountID = record.accountID
        resource = record.source.rawValue + ":" + record.resourceName + ":" + record.url.absoluteString
        version = record.version
        fetchedAt = record.fetchedAt
        size = ContactPhotoImages.thumbnailDimension
    }
}

/// The process-wide decoded-photo budget counts pixels, rather than compressed
/// PNG bytes. Access and photo-version checks remain the caller's responsibility.
@MainActor
final class ContactThumbnailCache {
    static let shared = ContactThumbnailCache()
    let capacity: Int
    private(set) var cost = 0
    private(set) var decodeCount = 0
    private var sequence = 0
    private var entries: [ContactPhotoCacheKey: Entry] = [:]
    private var pending: [ContactPhotoCacheKey: Pending] = [:]
    private var pressure: (any DispatchSourceMemoryPressure)?

    private struct Entry {
        let image: NSImage
        let cost: Int
        var used: Int
    }
    private struct Pending {
        let id: UUID
        let task: Task<PreparedContactThumbnail, any Error>
    }

    init(capacity: Int = 32 * 1_024 * 1_024, monitorsPressure: Bool = true) {
        self.capacity = max(0, capacity)
        if monitorsPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.removeAll()
                    AttachmentPresentation.removeAll()
                    await EmailCalendarPreparation.shared.removeAll()
                }
            }
            source.resume()
            pressure = source
        }
    }

    func image(for key: ContactPhotoCacheKey) -> NSImage? {
        guard var entry = entries[key] else { return nil }
        sequence += 1
        entry.used = sequence
        entries[key] = entry
        return entry.image
    }

    func image(for key: ContactPhotoCacheKey, data: Data) async throws -> NSImage {
        if let image = image(for: key) { return image }
        let work: Pending
        if let existing = pending[key] { work = existing }
        else {
            let task = Task { try await ContactThumbnailDecoder.shared.decode(data) }
            work = Pending(id: UUID(), task: task)
            pending[key] = work
            decodeCount += 1
        }
        let decoded: PreparedContactThumbnail
        do { decoded = try await work.task.value }
        catch {
            if pending[key]?.id == work.id { pending[key] = nil }
            throw error
        }
        try Task.checkCancellation()
        if let image = image(for: key) { return image }
        // An account removal or pressure purge must also reject late decoding.
        guard pending[key]?.id == work.id else { throw CancellationError() }
        pending[key] = nil
        let image = NSImage(cgImage: decoded.pixels,
            size: NSSize(width: decoded.pixels.width, height: decoded.pixels.height))
        if decoded.cost <= capacity {
            while cost + decoded.cost > capacity,
                  let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                remove(oldest)
            }
            sequence += 1
            entries[key] = Entry(image: image, cost: decoded.cost, used: sequence)
            cost += decoded.cost
        }
        return image
    }

    func remove(accountID: String) {
        for key in entries.keys.filter({ $0.accountID == accountID }) { remove(key) }
        for key in pending.keys.filter({ $0.accountID == accountID }) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
    }

    func removeAll() {
        entries.removeAll()
        cost = 0
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
    }

    private func remove(_ key: ContactPhotoCacheKey) {
        if let removed = entries.removeValue(forKey: key) { cost -= removed.cost }
    }
}
