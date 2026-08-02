// macOS-exclusive: built on macOS-only frameworks (see SkyBridgeCore iOS portability
// notes). Excluded from other platforms; no behaviour changes on macOS.
#if os(macOS)
import Foundation
import CoreGraphics
import ApplicationServices

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class RemoteDesktopInteractionTelemetrySampler {
    struct CaptureContext: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let displayPixelSize: CGSize
        let streamSize: CGSize

        var isValid: Bool {
            displayPixelSize.width > 0
                && displayPixelSize.height > 0
                && streamSize.width > 0
                && streamSize.height > 0
        }
    }

    private struct CursorSignature: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let hotspotX: Int
        let hotspotY: Int
        let hidden: Bool
        let imageSignature: Data?
    }

    private struct OverlaySignature: Equatable {
        let selectionRects: [CGRect]
        let focusRect: CGRect?
    }

    private struct CursorRaster {
        let pngData: Data?
        let pixelSize: CGSize
        let signatureData: Data?
    }

    private var lastCursorSignature: CursorSignature?
    private var lastOverlaySignature: OverlaySignature?

    func reset() {
        resetCursorState()
        resetOverlayState()
    }

    func resetCursorState() {
        lastCursorSignature = nil
    }

    func resetOverlayState() {
        lastOverlaySignature = nil
    }

    func sampleCursor(context: CaptureContext) -> RemoteDesktopCursorPayload? {
        guard context.isValid,
              let screen = screen(for: context.displayID) else {
            return nil
        }

        let globalMouseLocation = NSEvent.mouseLocation
        let isOnCapturedDisplay = screen.frame.insetBy(dx: -1, dy: -1).contains(globalMouseLocation)
        let scale = streamScale(context)
        let clampedPixelLocation = clampedScreenPixelLocation(
            from: globalMouseLocation,
            in: screen,
            displayPixelSize: context.displayPixelSize
        )

        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let raster = rasterizedCursorImage(cursor.image)
        let hotspotPixels = CGPoint(
            x: cursor.hotSpot.x * screen.backingScaleFactor,
            y: cursor.hotSpot.y * screen.backingScaleFactor
        )

        let streamLocation = CGPoint(
            x: clampedPixelLocation.x * scale.x,
            y: clampedPixelLocation.y * scale.y
        )
        let streamCursorSize = CGSize(
            width: max(raster.pixelSize.width * scale.x, 1),
            height: max(raster.pixelSize.height * scale.y, 1)
        )
        let streamHotspot = CGPoint(
            x: hotspotPixels.x * scale.x,
            y: hotspotPixels.y * scale.y
        )
        let hidden = !isOnCapturedDisplay

        let signature = CursorSignature(
            x: Int(streamLocation.x.rounded()),
            y: Int(streamLocation.y.rounded()),
            width: Int(streamCursorSize.width.rounded()),
            height: Int(streamCursorSize.height.rounded()),
            hotspotX: Int(streamHotspot.x.rounded()),
            hotspotY: Int(streamHotspot.y.rounded()),
            hidden: hidden,
            imageSignature: raster.signatureData
        )

        guard signature != lastCursorSignature else { return nil }

        let shouldEmbedImage = lastCursorSignature?.imageSignature != signature.imageSignature
        lastCursorSignature = signature

        let imageData = shouldEmbedImage ? raster.pngData : nil
        let mimeType = imageData == nil ? nil : (UTType.png.preferredMIMEType ?? "image/png")
        return RemoteDesktopCursorPayload(
            x: Double(signature.x),
            y: Double(signature.y),
            width: Double(max(signature.width, 1)),
            height: Double(max(signature.height, 1)),
            hotspotX: Double(max(signature.hotspotX, 0)),
            hotspotY: Double(max(signature.hotspotY, 0)),
            hidden: hidden,
            imageData: imageData,
            mimeType: mimeType
        )
    }

    func sampleOverlay(context: CaptureContext) -> RemoteDesktopOverlayPayload? {
        guard context.isValid else { return nil }

        guard AXIsProcessTrusted() else {
            if lastOverlaySignature == nil {
                return nil
            }
            lastOverlaySignature = OverlaySignature(selectionRects: [], focusRect: nil)
            return RemoteDesktopOverlayPayload()
        }

        guard let screen = screen(for: context.displayID) else { return nil }

        let focusedElement = focusedUIElement()
        let sampledFocusRect: CGRect? = {
            guard let focusedElement,
                  let rect = focusRect(for: focusedElement) else {
                return nil
            }
            return convertToStreamRect(rect, on: screen, context: context)
        }()

        let sampledSelectionRects: [CGRect] = {
            guard let focusedElement else { return [] }
            return selectionRects(for: focusedElement).compactMap {
                convertToStreamRect($0, on: screen, context: context)
            }
        }()

        let normalizedSelectionRects = normalizedSelectionRects(sampledSelectionRects)
        let signature = OverlaySignature(
            selectionRects: normalizedSelectionRects,
            focusRect: sampledFocusRect
        )

        guard signature != lastOverlaySignature else { return nil }
        lastOverlaySignature = signature

        return RemoteDesktopOverlayPayload(
            selectionRects: normalizedSelectionRects.map(Self.damageRect(from:)),
            focusRect: sampledFocusRect.map(Self.damageRect(from:))
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }

    private func streamScale(_ context: CaptureContext) -> CGPoint {
        CGPoint(
            x: context.streamSize.width / context.displayPixelSize.width,
            y: context.streamSize.height / context.displayPixelSize.height
        )
    }

    private func clampedScreenPixelLocation(
        from globalMouseLocation: CGPoint,
        in screen: NSScreen,
        displayPixelSize: CGSize
    ) -> CGPoint {
        let raw = screenPixelLocation(from: globalMouseLocation, in: screen)
        return CGPoint(
            x: min(max(raw.x, 0), displayPixelSize.width),
            y: min(max(raw.y, 0), displayPixelSize.height)
        )
    }

    private func screenPixelLocation(from globalMouseLocation: CGPoint, in screen: NSScreen) -> CGPoint {
        CGPoint(
            x: (globalMouseLocation.x - screen.frame.minX) * screen.backingScaleFactor,
            y: (screen.frame.maxY - globalMouseLocation.y) * screen.backingScaleFactor
        )
    }

    private func convertToStreamRect(
        _ rect: CGRect,
        on screen: NSScreen,
        context: CaptureContext
    ) -> CGRect? {
        let displayRect = CGRect(origin: .zero, size: context.displayPixelSize)
        let localPixelRect = CGRect(
            x: (rect.minX - screen.frame.minX) * screen.backingScaleFactor,
            y: (screen.frame.maxY - rect.maxY) * screen.backingScaleFactor,
            width: rect.width * screen.backingScaleFactor,
            height: rect.height * screen.backingScaleFactor
        )
        let clipped = localPixelRect.intersection(displayRect).integral
        guard !clipped.isNull,
              !clipped.isEmpty,
              clipped.width >= 1,
              clipped.height >= 1 else {
            return nil
        }

        let scale = streamScale(context)
        let converted = CGRect(
            x: clipped.minX * scale.x,
            y: clipped.minY * scale.y,
            width: clipped.width * scale.x,
            height: clipped.height * scale.y
        ).integral

        guard !converted.isNull,
              !converted.isEmpty,
              converted.width >= 1,
              converted.height >= 1 else {
            return nil
        }
        return converted
    }

    private func rasterizedCursorImage(_ image: NSImage) -> CursorRaster {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return CursorRaster(
                pngData: nil,
                pixelSize: CGSize(
                    width: max(image.size.width, 1),
                    height: max(image.size.height, 1)
                ),
                signatureData: nil
            )
        }

        return CursorRaster(
            pngData: bitmap.representation(using: .png, properties: [:]),
            pixelSize: CGSize(
                width: max(bitmap.pixelsWide, 1),
                height: max(bitmap.pixelsHigh, 1)
            ),
            signatureData: tiff
        )
    }

    private func focusedUIElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue else {
            return nil
        }
        return axUIElement(from: rawValue)
    }

    private func focusRect(for element: AXUIElement) -> CGRect? {
        guard let position = attributeCGPoint(element, attribute: kAXPositionAttribute as CFString),
              let size = attributeCGSize(element, attribute: kAXSizeAttribute as CFString),
              size.width >= 1,
              size.height >= 1 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func selectionRects(for element: AXUIElement) -> [CGRect] {
        let rangeValues = selectedTextRangeValues(for: element)
        guard !rangeValues.isEmpty else { return [] }

        return rangeValues.prefix(8).compactMap { rangeValue in
            var rawResult: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &rawResult
            ) == .success,
            let rawResult,
            let rectValue = axValue(from: rawResult),
            AXValueGetType(rectValue) == .cgRect else {
                return nil
            }

            var rect = CGRect.zero
            guard AXValueGetValue(rectValue, .cgRect, &rect) else { return nil }
            return rect
        }
    }

    private func selectedTextRangeValues(for element: AXUIElement) -> [AXValue] {
        if let rawRanges = attributeValue(
            element,
            attribute: kAXSelectedTextRangesAttribute as CFString
        ) as? [AnyObject] {
            let values = rawRanges.compactMap { item -> AXValue? in
                guard CFGetTypeID(item) == AXValueGetTypeID() else {
                    return nil
                }
                return unsafeDowncast(item, to: AXValue.self)
            }
            if !values.isEmpty {
                return values
            }
        }

        if let rawRangeRef = attributeValue(
            element,
            attribute: kAXSelectedTextRangeAttribute as CFString
        ),
        let rawRange = axValue(from: rawRangeRef) {
            return [rawRange]
        }

        return []
    }

    private func attributeValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
            return nil
        }
        return rawValue
    }

    private func attributeCGPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        guard let rawValue = attributeValue(element, attribute: attribute),
              let axValue = axValue(from: rawValue),
              AXValueGetType(axValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func attributeCGSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let rawValue = attributeValue(element, attribute: attribute),
              let axValue = axValue(from: rawValue),
              AXValueGetType(axValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func axUIElement(from rawValue: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(rawValue, to: AXUIElement.self)
    }

    private func axValue(from rawValue: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(rawValue, to: AXValue.self)
    }

    private func normalizedSelectionRects(_ rects: [CGRect]) -> [CGRect] {
        let normalized = rects
            .map(\.integral)
            .filter { !$0.isNull && !$0.isEmpty && $0.width >= 1 && $0.height >= 1 }

        guard !normalized.isEmpty else { return [] }
        if normalized.count <= 6 {
            return normalized
        }
        return [normalized.reduce(normalized[0]) { $0.union($1) }.integral]
    }

    private static func damageRect(from rect: CGRect) -> RemoteDesktopDamageRect {
        RemoteDesktopDamageRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }
}
#endif
#endif
