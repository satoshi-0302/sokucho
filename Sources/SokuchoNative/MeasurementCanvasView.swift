import SwiftUI
import AppKit

struct MeasurementCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var store: AppStore

    func makeNSView(context: Context) -> MeasurementCanvasNSView {
        let view = MeasurementCanvasNSView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: MeasurementCanvasNSView, context: Context) {
        nsView.store = store
        nsView.syncCanvasSize()
        nsView.needsDisplay = true
    }
}

final class MeasurementCanvasNSView: NSView {
    weak var store: AppStore?

    private var trackingAreaRef: NSTrackingArea?
    private var panButton: Int?
    private var dragMoved = false
    private var mouseDownPoint: CGPoint = .zero
    private var lastDragPoint: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1).cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1).cgColor
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncCanvasSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func syncCanvasSize() {
        store?.updateCanvasSize(bounds.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncCanvasSize()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        store?.updateHover(screenPoint: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        beginPan(button: 0, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        beginPan(button: Int(event.buttonNumber), event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        store?.cancelAction()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        finishPan(button: 0, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        finishPan(button: Int(event.buttonNumber), event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let store else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let factor = exp(-event.scrollingDeltaY * 0.003)
            store.zoom(atScreen: pt, factor: factor)
            needsDisplay = true
            return
        }

        if event.hasPreciseScrollingDeltas {
            store.pan(byScreen: CGSize(width: -event.scrollingDeltaX, height: -event.scrollingDeltaY))
            needsDisplay = true
            return
        }

        let step = (event.deltaY < 0) ? 1.08 : (1.0 / 1.08)
        store.zoom(atScreen: pt, factor: step)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let store else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let factor = max(0.05, 1 + event.magnification)
        store.zoom(atScreen: pt, factor: factor)
        needsDisplay = true
    }

    override func swipe(with event: NSEvent) {
        guard let store else { return }
        let horizontal = abs(event.deltaX) > abs(event.deltaY)
        guard horizontal, abs(event.deltaX) > 0.1 else {
            super.swipe(with: event)
            return
        }
        let delta = (event.deltaX > 0) ? -1 : 1
        store.switchSession(delta: delta)
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !objects.isEmpty
        else {
            return false
        }
        store?.addImageFiles(objects)
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.03, alpha: 1).setFill()
        dirtyRect.fill()

        guard let store, let session = store.activeSession else {
            drawHintText("画像をドラッグ&ドロップ、または「画像を開く」")
            drawSubHintText("トラックパッド: 2本指パン / ピンチズーム / Option+2本指上下でズーム")
            return
        }

        let imageRect = store.screenRectForActiveImage(in: bounds.size)
        session.image.draw(in: imageRect,
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1,
                           respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.none])

        drawMeasurements(store: store)
        drawPending(store: store)
        drawCrosshair(store: store)
    }

    private func beginPan(button: Int, event: NSEvent) {
        panButton = button
        dragMoved = false
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        lastDragPoint = point
    }

    private func handleDrag(_ event: NSEvent) {
        guard let store, panButton != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - lastDragPoint.x
        let dy = point.y - lastDragPoint.y

        if !dragMoved {
            let rawDx = point.x - mouseDownPoint.x
            let rawDy = point.y - mouseDownPoint.y
            dragMoved = hypot(rawDx, rawDy) > 4
        }

        if dragMoved {
            store.pan(byScreen: CGSize(width: dx, height: dy))
            needsDisplay = true
        }

        lastDragPoint = point
        store.updateHover(screenPoint: point)
    }

    private func finishPan(button: Int, event: NSEvent) {
        guard let store, panButton == button else { return }
        let point = convert(event.locationInWindow, from: nil)

        defer {
            panButton = nil
            dragMoved = false
        }

        if button == 0, !dragMoved {
            store.commitClick(atScreen: point)
            needsDisplay = true
        }
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        store?.updateHover(screenPoint: point)
        needsDisplay = true
    }

    private func drawMeasurements(store: AppStore) {
        guard let session = store.activeSession else { return }

        for measurement in store.drawResults {
            guard let p1 = store.screenPoint(fromImage: measurement.p1),
                  let p2 = store.screenPoint(fromImage: measurement.p2)
            else { continue }

            let isHighlighted = (measurement.id == store.highlightedMeasurementID)
            let stroke = isHighlighted
                ? NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.54, alpha: 0.96)
                : NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.0, alpha: 0.82)

            stroke.setStroke()
            let line = NSBezierPath()
            line.lineWidth = 2.0
            line.move(to: p1)
            line.line(to: p2)
            line.stroke()

            let label = "#\(measurement.id) \(store.formattedLength(pixelLength: measurement.pixelLength, calibration: session.calibration))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 0.98)
            ]
            let textSize = label.size(withAttributes: attrs)
            let mid = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
            let box = CGRect(x: clamp(mid.x + 8, 8, bounds.width - textSize.width - 22),
                             y: clamp(mid.y + 8, 8, bounds.height - 24),
                             width: textSize.width + 10,
                             height: 18)

            let bg = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            (isHighlighted
                ? NSColor(calibratedRed: 0.17, green: 0.34, blue: 0.25, alpha: 0.88)
                : NSColor(calibratedWhite: 0.10, alpha: 0.74)).setFill()
            bg.fill()

            label.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
        }
    }

    private func drawPending(store: AppStore) {
        guard let first = store.pendingPoints.first,
              let firstScreen = store.screenPoint(fromImage: first)
        else {
            return
        }

        NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.54, alpha: 0.95).setFill()
        let dot = NSBezierPath(ovalIn: CGRect(x: firstScreen.x - 3, y: firstScreen.y - 3, width: 6, height: 6))
        dot.fill()

        guard let hover = store.hoverScreenPoint,
              let hoverImg = store.imagePoint(fromScreen: hover)
        else {
            return
        }

        NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.54, alpha: 0.9).setStroke()
        let preview = NSBezierPath()
        preview.lineWidth = 2
        preview.move(to: firstScreen)
        preview.line(to: hover)
        preview.stroke()

        let px = hypot(first.x - hoverImg.x, first.y - hoverImg.y)
        let text = (store.mode == .scale)
            ? "\(store.formatSig(px)) px（ここを2点目で確定）"
            : "\(store.formattedLength(pixelLength: px))（2点目クリックで確定）"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 0.98)
        ]
        let size = text.size(withAttributes: attrs)
        let box = CGRect(x: clamp(hover.x + 14, 8, bounds.width - size.width - 18),
                         y: clamp(hover.y + 14, 8, bounds.height - 28),
                         width: size.width + 10,
                         height: 20)
        NSColor(calibratedWhite: 0.1, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawCrosshair(store: AppStore) {
        guard let hover = store.hoverScreenPoint else { return }
        let len: CGFloat = 14

        let under = NSBezierPath()
        under.lineWidth = 3
        under.move(to: CGPoint(x: hover.x - len, y: hover.y))
        under.line(to: CGPoint(x: hover.x + len, y: hover.y))
        under.move(to: CGPoint(x: hover.x, y: hover.y - len))
        under.line(to: CGPoint(x: hover.x, y: hover.y + len))
        NSColor(calibratedWhite: 0.02, alpha: 0.78).setStroke()
        under.stroke()

        let top = NSBezierPath()
        top.lineWidth = 1.2
        top.move(to: CGPoint(x: hover.x - len, y: hover.y))
        top.line(to: CGPoint(x: hover.x + len, y: hover.y))
        top.move(to: CGPoint(x: hover.x, y: hover.y - len))
        top.line(to: CGPoint(x: hover.x, y: hover.y + len))
        NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.0, alpha: 0.96).setStroke()
        top.stroke()

        if store.edgeSnap && (store.mode == .measure || store.mode == .scale) {
            let ring = NSBezierPath(ovalIn: CGRect(x: hover.x - 5, y: hover.y - 5, width: 10, height: 10))
            ring.lineWidth = 1.2
            NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.54, alpha: 0.95).setStroke()
            ring.stroke()
        }
    }

    private func drawHintText(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 0.86)
        ]
        text.draw(at: CGPoint(x: 20, y: 36), withAttributes: attrs)
    }

    private func drawSubHintText(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 0.9)
        ]
        text.draw(at: CGPoint(x: 20, y: 62), withAttributes: attrs)
    }

    private func clamp(_ v: CGFloat, _ minV: CGFloat, _ maxV: CGFloat) -> CGFloat {
        max(minV, min(maxV, v))
    }
}
