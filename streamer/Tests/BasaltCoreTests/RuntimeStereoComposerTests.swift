import CoreVideo
import IOSurface
import Metal
import XCTest
@testable import BasaltCore

final class RuntimeStereoComposerTests: XCTestCase {
    private final class FrameStore: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [RuntimeStereoComposer.ComposedFrame] = []

        func append(_ frame: RuntimeStereoComposer.ComposedFrame?) {
            guard let frame else { return }
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func first() -> RuntimeStereoComposer.ComposedFrame? {
            lock.lock()
            defer { lock.unlock() }
            return frames.first
        }

        func removeAll() {
            lock.lock()
            frames.removeAll()
            lock.unlock()
        }
    }

    private func pixelBuffer(b: UInt8, g: UInt8, r: UInt8, a: UInt8) throws
        -> CVPixelBuffer
    {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var maybeBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 1, 1, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &maybeBuffer),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        bytes[0] = b
        bytes[1] = g
        bytes[2] = r
        bytes[3] = a
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testOpaqueProjectionPreservesRGBWhenSourceAlphaIsZero() throws {
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        let left = try pixelBuffer(b: 0, g: 0, r: 255, a: 0)
        let right = try pixelBuffer(b: 0, g: 255, r: 0, a: 0)
        let completed = expectation(description: "asynchronous Metal composition")
        let outputs = FrameStore()
        XCTAssertTrue(composer.composeAsync(
            left: try XCTUnwrap(CVPixelBufferGetIOSurface(left)?.takeUnretainedValue()),
            right: try XCTUnwrap(CVPixelBufferGetIOSurface(right)?.takeUnretainedValue())
        ) { frame in
            outputs.append(frame)
            completed.fulfill()
        })
        wait(for: [completed], timeout: 2)
        let pixelBuffer = try XCTUnwrap(outputs.first()?.pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[2], 240)
        XCTAssertLessThan(bytes[1], 15)
        XCTAssertGreaterThan(bytes[3], 240)
        XCTAssertGreaterThan(bytes[5], 240)
        XCTAssertLessThan(bytes[6], 15)
        XCTAssertGreaterThan(bytes[7], 240)
    }

    func testRGBAIOSurfacesComposeToBGRAWithoutColorConversion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device")
        }
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        let completed = expectation(description: "RGBA IOSurface composition")
        let outputs = FrameStore()

        func surface(r: UInt8, g: UInt8, b: UInt8, a: UInt8) throws -> IOSurfaceRef {
            let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, 4)
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: 1,
                kIOSurfaceHeight: 1,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: bytesPerRow,
                kIOSurfacePixelFormat: kCVPixelFormatType_32RGBA,
            ]
            let surface = try XCTUnwrap(IOSurfaceCreate(properties as CFDictionary))
            XCTAssertEqual(IOSurfaceLock(surface, [], nil), 0)
            let bytes = try XCTUnwrap(IOSurfaceGetBaseAddress(surface))
                .assumingMemoryBound(to: UInt8.self)
            bytes[0] = r
            bytes[1] = g
            bytes[2] = b
            bytes[3] = a
            XCTAssertEqual(IOSurfaceUnlock(surface, [], nil), 0)
            return surface
        }

        // Drop the caller's source references before waiting for GPU completion.
        try autoreleasepool {
            let left = try surface(r: 32, g: 96, b: 160, a: 0)
            let right = try surface(r: 210, g: 70, b: 15, a: 17)
            XCTAssertTrue(composer.composeAsync(left: left, right: right) { frame in
                outputs.append(frame)
                completed.fulfill()
            })
        }
        wait(for: [completed], timeout: 2)
        let output = try XCTUnwrap(outputs.first()?.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(output))
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 8)),
                       [160, 96, 32, 255, 15, 70, 210, 255])
    }

    func testEyeRectsCropASharedSideBySideImage() throws {
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        // One image holding both eyes: left half blue, right half red.
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var maybeSource: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 2, 1, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &maybeSource),
            kCVReturnSuccess)
        let source = try XCTUnwrap(maybeSource)
        CVPixelBufferLockBaseAddress(source, [])
        let sourceBytes = CVPixelBufferGetBaseAddress(source)!
            .assumingMemoryBound(to: UInt8.self)
        sourceBytes[0] = 255
        sourceBytes[1] = 0
        sourceBytes[2] = 0
        sourceBytes[3] = 255
        sourceBytes[4] = 0
        sourceBytes[5] = 0
        sourceBytes[6] = 255
        sourceBytes[7] = 255
        CVPixelBufferUnlockBaseAddress(source, [])

        let completed = expectation(description: "cropped composition")
        let outputs = FrameStore()
        XCTAssertTrue(composer.composeAsync(
            left: source, right: source,
            leftRect: SIMD4<Float>(0, 0, 1, 1),
            rightRect: SIMD4<Float>(1, 0, 1, 1)
        ) { frame in
            outputs.append(frame)
            completed.fulfill()
        })
        wait(for: [completed], timeout: 2)
        let composed = try XCTUnwrap(outputs.first()?.pixelBuffer)

        CVPixelBufferLockBaseAddress(composed, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(composed, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(composed)!
            .assumingMemoryBound(to: UInt8.self)
        // Each eye samples its own rect instead of the whole image.
        XCTAssertGreaterThan(bytes[0], 240)
        XCTAssertLessThan(bytes[2], 15)
        XCTAssertLessThan(bytes[4], 15)
        XCTAssertGreaterThan(bytes[6], 240)
    }

    func testCompositionHasStrictTwoFrameBoundAndReusesReleasedSlot() throws {
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        let source = try pixelBuffer(b: 0, g: 0, r: 0, a: 255)
        let outputs = FrameStore()
        let firstTwo = expectation(description: "first two frames complete")
        firstTwo.expectedFulfillmentCount = RuntimeStereoComposer.maximumFramesInFlight

        for _ in 0..<RuntimeStereoComposer.maximumFramesInFlight {
            XCTAssertTrue(composer.composeAsync(left: source, right: source) { frame in
                outputs.append(frame)
                firstTwo.fulfill()
            })
        }
        XCTAssertFalse(composer.composeAsync(left: source, right: source) { _ in
            XCTFail("a third in-flight frame must not be admitted")
        })
        wait(for: [firstTwo], timeout: 2)

        outputs.removeAll()
        let reused = expectation(description: "released slot is reusable")
        XCTAssertTrue(composer.composeAsync(left: source, right: source) { frame in
            XCTAssertNotNil(frame)
            reused.fulfill()
        })
        wait(for: [reused], timeout: 2)
    }
}
