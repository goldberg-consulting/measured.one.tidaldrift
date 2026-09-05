import XCTest
@testable import TidalDrift
import AppKit
import CryptoKit

/// Pure-logic clipboard sync tests: framing, digests, sanitization, and
/// pasteboard round trips against private named pasteboards. The network
/// round trip lives in the in-app Test Suite ("Clipboard Bulk Loopback"),
/// where Local Network entitlements are granted.
final class ClipboardSyncTests: XCTestCase {

    private func testKey() -> SymmetricKey {
        SessionCrypto.deriveClipboardKey(from: SessionCrypto.generateSessionKey())
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.tidaldrift.tests.\(UUID().uuidString)"))
    }

    // MARK: - Image pixel cap (#155)

    func test_pngPixelCount_readsHeaderAndRejectsGarbage() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 7, pixelsHigh: 5, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        XCTAssertEqual(ClipboardPasteboard.pngPixelCount(png), 35)
        XCTAssertNil(ClipboardPasteboard.pngPixelCount(Data("not an image".utf8)))
        XCTAssertNil(ClipboardPasteboard.pngPixelCount(Data()))
    }

    func test_applyInline_dropsImageDeclaringHugeCanvas() {
        // Minimal PNG whose IHDR declares 65535 x 65535 with no pixel data.
        // ImageIO reads the header without decoding, so the cap has to trip.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png += Data([0x00, 0x00, 0x00, 0x0D]) + Data("IHDR".utf8)
        png += Data([0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x08, 0x06, 0x00, 0x00, 0x00])
        png += Data([0x00, 0x00, 0x00, 0x00])  // CRC (ImageIO tolerates a bad one)
        if let pixels = ClipboardPasteboard.pngPixelCount(png) {
            XCTAssertGreaterThan(pixels, ClipboardPasteboard.maxImagePixels)
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test.\(UUID().uuidString)"))
        ClipboardPasteboard.applyInline(kind: .image, text: nil, rtf: nil, png: png, to: pasteboard)
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.data(forType: .tiff))
        pasteboard.releaseGlobally()
    }

    // MARK: - Manifest validation (#148)

    func test_declaredTotal_rejectsOverflowNegativeAndOversized() {
        let cap = LocalCastConfiguration.clipboardMaxTransferBytes
        XCTAssertEqual(ClipboardBulkTransfer.declaredTotal(of: []), 0)
        XCTAssertEqual(ClipboardBulkTransfer.declaredTotal(of: [
            ClipboardFileStub(name: "a", size: 10), ClipboardFileStub(name: "b", size: 32),
        ]), 42)
        XCTAssertNil(ClipboardBulkTransfer.declaredTotal(of: [
            ClipboardFileStub(name: "a", size: Int64.max), ClipboardFileStub(name: "b", size: 1),
        ]), "Int64.max + 1 must not trap")
        XCTAssertNil(ClipboardBulkTransfer.declaredTotal(of: [ClipboardFileStub(name: "a", size: -1)]))
        XCTAssertNil(ClipboardBulkTransfer.declaredTotal(of: [ClipboardFileStub(name: "a", size: cap + 1)]))
        XCTAssertNil(ClipboardBulkTransfer.declaredTotal(of: [
            ClipboardFileStub(name: "a", size: cap), ClipboardFileStub(name: "b", size: 1),
        ]), "sum over the cap")
        XCTAssertEqual(ClipboardBulkTransfer.declaredTotal(of: [ClipboardFileStub(name: "a", size: cap)]), cap)
    }

    // MARK: - Framing

    func test_framing_roundTrip_keyed() throws {
        let key = testKey()
        let body = Data("clipboard hello".utf8)
        let frame = try XCTUnwrap(ClipboardBulkFraming.encodeFrame(type: .hello, body: body, key: key))

        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        XCTAssertEqual(Int(length), frame.count - 4)

        let plaintext = try XCTUnwrap(ClipboardBulkFraming.unseal(Data(frame.dropFirst(4)), key: key))
        let decoded = try XCTUnwrap(ClipboardBulkFraming.decodeFrame(plaintext))
        XCTAssertEqual(decoded.type, .hello)
        XCTAssertEqual(decoded.body, body)
    }

    func test_framing_keyedSessionRejectsPlaintextFrame() {
        // Downgrade defense: a plaintext-flagged frame must be rejected once a
        // key exists, mirroring UDPTransport's post-auth rule.
        let plainWrapped = SessionCrypto.wrapPlaintext(Data([ClipboardBulkFrameType.hello.rawValue]))
        XCTAssertNil(ClipboardBulkFraming.unseal(plainWrapped, key: testKey()))
    }

    func test_framing_rejectsTamperedCiphertext() throws {
        let key = testKey()
        let frame = try XCTUnwrap(ClipboardBulkFraming.encodeFrame(type: .chunk, body: Data(count: 64), key: key))
        var sealed = Data(frame.dropFirst(4))
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertNil(ClipboardBulkFraming.unseal(sealed, key: key))
    }

    func test_framing_roundTrip_keyless() throws {
        let frame = try XCTUnwrap(ClipboardBulkFraming.encodeFrame(type: .done, body: Data(), key: nil))
        let plaintext = try XCTUnwrap(ClipboardBulkFraming.unseal(Data(frame.dropFirst(4)), key: nil))
        XCTAssertEqual(ClipboardBulkFraming.decodeFrame(plaintext)?.type, .done)
        // A keyless receiver must not accept an encrypted frame either.
        let keyedFrame = try XCTUnwrap(ClipboardBulkFraming.encodeFrame(type: .done, body: Data(), key: testKey()))
        XCTAssertNil(ClipboardBulkFraming.unseal(Data(keyedFrame.dropFirst(4)), key: nil))
    }

    func test_chunkBody_roundTrip() throws {
        let content = Data((0..<1000).map { UInt8($0 % 256) })
        let body = ClipboardBulkFraming.encodeChunkBody(sequence: 7, content: content)
        let decoded = try XCTUnwrap(ClipboardBulkFraming.decodeChunkBody(body))
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertEqual(decoded.content, content)
    }

    func test_chunkBody_decodesFromMisalignedSlice() throws {
        // The real receive path hands decodeChunkBody a slice at offset 1 of
        // the decrypted frame (behind the type tag). An aligned load(as:)
        // traps on that; this pins the loadUnaligned fix.
        let content = Data(repeating: 0xEE, count: 100)
        var plaintext = Data([ClipboardBulkFrameType.chunk.rawValue])
        plaintext.append(ClipboardBulkFraming.encodeChunkBody(sequence: 3, content: content))

        let frame = try XCTUnwrap(ClipboardBulkFraming.decodeFrame(plaintext))
        XCTAssertEqual(frame.type, .chunk)
        let chunk = try XCTUnwrap(ClipboardBulkFraming.decodeChunkBody(frame.body))
        XCTAssertEqual(chunk.sequence, 3)
        XCTAssertEqual(chunk.content, content)
    }

    func test_promiseFileName_isSanitized() {
        // The pasting app builds its destination path from fileNameForType;
        // a raw manifest name would allow traversal out of the paste target.
        let stubs = [ClipboardFileStub(name: "../../../evil.plist", size: 1)]
        let delegate = ClipboardFilePromiseDelegate(stubs: stubs) { completion in
            completion(.failure(ClipboardBulkError.cancelled))
        }
        let providers = delegate.makeProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(
            delegate.filePromiseProvider(providers[0], fileNameForType: "public.data"),
            "evil.plist"
        )
    }

    // MARK: - Names and collisions

    func test_sanitizeFileName_rejectsTraversalAndHidden() {
        XCTAssertEqual(ClipboardBulkFraming.sanitizeFileName("report.pdf"), "report.pdf")
        XCTAssertEqual(ClipboardBulkFraming.sanitizeFileName("/etc/passwd"), "passwd")
        XCTAssertEqual(ClipboardBulkFraming.sanitizeFileName("a/../../b.txt"), "b.txt")
        XCTAssertNil(ClipboardBulkFraming.sanitizeFileName(".."))
        XCTAssertNil(ClipboardBulkFraming.sanitizeFileName(".hidden"))
        XCTAssertNil(ClipboardBulkFraming.sanitizeFileName(""))
    }

    func test_collisionFreeURL_dedupsWithNumericSuffix() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(ClipboardBulkFraming.collisionFreeURL(for: "a.txt", in: dir).lastPathComponent, "a.txt")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        XCTAssertEqual(ClipboardBulkFraming.collisionFreeURL(for: "a.txt", in: dir).lastPathComponent, "a 2.txt")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a 2.txt").path, contents: Data())
        XCTAssertEqual(ClipboardBulkFraming.collisionFreeURL(for: "a.txt", in: dir).lastPathComponent, "a 3.txt")
    }

    // MARK: - Pasteboard capture and apply

    func test_capture_text_apply_digestStable() throws {
        let source = privatePasteboard()
        source.clearContents()
        source.setString("tidal drift", forType: .string)

        let snapshot = try XCTUnwrap(ClipboardPasteboard.capture(from: source))
        XCTAssertEqual(snapshot.kind, .text)
        XCTAssertEqual(snapshot.text, "tidal drift")

        // Applying what was captured must reproduce the same digest, or echo
        // suppression breaks and the sides ping-pong forever.
        let destination = privatePasteboard()
        ClipboardPasteboard.applyInline(kind: .text, text: snapshot.text, rtf: snapshot.rtf, png: nil, to: destination)
        let reCaptured = try XCTUnwrap(ClipboardPasteboard.capture(from: destination))
        XCTAssertEqual(reCaptured.digest, snapshot.digest)
    }

    func test_capture_image_apply_digestStable() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        let source = privatePasteboard()
        source.clearContents()
        source.setData(tiff, forType: .tiff)

        let snapshot = try XCTUnwrap(ClipboardPasteboard.capture(from: source))
        XCTAssertEqual(snapshot.kind, .image)
        XCTAssertNotNil(snapshot.png)

        let destination = privatePasteboard()
        ClipboardPasteboard.applyInline(kind: .image, text: nil, rtf: nil, png: snapshot.png, to: destination)
        let reCaptured = try XCTUnwrap(ClipboardPasteboard.capture(from: destination))
        XCTAssertEqual(reCaptured.digest, snapshot.digest, "PNG bytes must survive apply/capture for echo suppression")
    }

    func test_capture_skipsConcealedAndTransient() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            let pasteboard = privatePasteboard()
            pasteboard.clearContents()
            pasteboard.declareTypes([.string, NSPasteboard.PasteboardType(marker)], owner: nil)
            pasteboard.setString("hunter2", forType: .string)
            XCTAssertNil(ClipboardPasteboard.capture(from: pasteboard), "\(marker) content must never sync")
        }
    }

    func test_capture_prefersFilesOverText() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).txt")
        try Data("file content".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let pasteboard = privatePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString(file.lastPathComponent, forType: .string)

        let snapshot = try XCTUnwrap(ClipboardPasteboard.capture(from: pasteboard))
        XCTAssertEqual(snapshot.kind, .files, "Finder puts both URLs and a name string on the pasteboard; files must win")
        XCTAssertEqual(snapshot.fileURLs, [file])
    }

    func test_filesDigest_isMachineIndependent() throws {
        // Same names and sizes in different directories must hash identically,
        // or the receiver's renamed staging paths would re-trigger a sync.
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        for dir in [dirA, dirB] {
            try Data("12345".utf8).write(to: dir.appendingPathComponent("x.bin"))
        }

        let digestA = ClipboardPasteboard.filesDigest([dirA.appendingPathComponent("x.bin")])
        let digestB = ClipboardPasteboard.filesDigest([dirB.appendingPathComponent("x.bin")])
        XCTAssertEqual(digestA, digestB)
    }

    func test_inlinePayload_respectsLimitBoundary() throws {
        let small = ClipboardUpdatePayload(
            updateId: UUID(), kind: .text, text: "hi", rtf: nil, png: nil, bulk: nil,
            digest: ClipboardPasteboard.digest(kind: .text, chunks: [Data("hi".utf8)])
        )
        let encoded = try JSONEncoder().encode(small)
        XCTAssertLessThanOrEqual(encoded.count, LocalCastConfiguration.clipboardInlineLimit)

        let bigText = String(repeating: "x", count: LocalCastConfiguration.clipboardInlineLimit)
        let big = ClipboardUpdatePayload(
            updateId: UUID(), kind: .text, text: bigText, rtf: nil, png: nil, bulk: nil,
            digest: ClipboardPasteboard.digest(kind: .text, chunks: [Data(bigText.utf8)])
        )
        let bigEncoded = try JSONEncoder().encode(big)
        XCTAssertGreaterThan(bigEncoded.count, LocalCastConfiguration.clipboardInlineLimit, "The limit check must run on encoded size")
    }
}
