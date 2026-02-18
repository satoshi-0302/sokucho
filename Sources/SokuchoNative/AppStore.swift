import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

@MainActor
final class AppStore: ObservableObject {
    private let roundingKey = "sokucho.native.rounding"
    private let continuousKey = "sokucho.native.continuous"
    private let snapKey = "sokucho.native.snap"
    private let projectExtension = "sokucho"
    private let autosaveDirectoryName = "SokuchoNative"
    private let autosaveFileName = "last-project.sokucho"

    private let minScale = 0.05
    private let maxScale = 80.0
    private let snapRadiusScreen: CGFloat = 12
    private let snapMinScore = 24.0
    private let supportedImageTypes: [UTType] = [.png, .jpeg, .tiff, .bmp, .gif, .webP, .heic, .heif]

    let maxVisibleResults = 120
    let displayDigits = 4

    @Published var sessions: [ImageSession] = []
    @Published var activeIndex: Int = -1
    @Published var mode: MeasureMode = .idle
    @Published var pendingPoints: [MeasurePoint] = []
    var hoverScreenPoint: CGPoint? = nil
    @Published var roundingMode: RoundingMode = .round
    @Published var continuousMeasure = false
    @Published var edgeSnap = false
    @Published var highlightedMeasurementID: Int? = nil
    var canvasSize: CGSize = .zero

    @Published var statusText = "準備完了: 画像を開く → 必要ならスケール設定 → 測長開始"

    @Published var showScaleSheet = false
    @Published var scaleInputUnit = "µm"
    @Published var scaleInputLength = ""

    weak var undoManager: UndoManager?

    private var pendingScalePixels: Double?
    private var lastCalibration: Calibration?
    private var autosaveTask: Task<Void, Never>?
    private var autosaveRevision: UInt64 = 0

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: roundingKey), let mode = RoundingMode(rawValue: raw) {
            roundingMode = mode
        }
        continuousMeasure = defaults.bool(forKey: continuousKey)
        edgeSnap = defaults.bool(forKey: snapKey)
        restoreAutosaveIfPossible()
    }

    deinit {
        autosaveTask?.cancel()
    }

    var activeSession: ImageSession? {
        guard activeIndex >= 0, activeIndex < sessions.count else { return nil }
        return sessions[activeIndex]
    }

    var currentResults: [Measurement] {
        activeSession?.results ?? []
    }

    var drawResults: [Measurement] {
        Array(currentResults.prefix(maxVisibleResults))
    }

    var imageChipText: String {
        guard let session = activeSession else { return "0 / 0" }
        return "\(activeIndex + 1) / \(sessions.count) \(session.name)"
    }

    var modeText: String { mode.label }

    var scaleText: String {
        guard let calibration = activeSession?.calibration else { return "未設定" }
        return "\(formatSig(calibration.unitsPerPixel)) \(calibration.unit)/px"
    }

    var avgText: String {
        guard !currentResults.isEmpty else { return "--" }
        let avg = currentResults.reduce(0.0) { $0 + $1.pixelLength } / Double(currentResults.count)
        return formattedLength(pixelLength: avg)
    }

    var drawLimitNote: String? {
        currentResults.count > maxVisibleResults
            ? "描画は最新\(maxVisibleResults)件まで表示（CSV/保存は全件出力）。"
            : nil
    }

    func openImagePanel() {
        let panel = NSOpenPanel()
        panel.title = "SEM画像を選択"
        panel.prompt = "開く"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedImageTypes
        if panel.runModal() == .OK {
            addImageFiles(panel.urls)
        }
    }

    func openImageFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "画像フォルダを選択"
        panel.prompt = "開く"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let directoryURL = panel.url {
            let files = imageFiles(in: directoryURL)
            guard !files.isEmpty else {
                statusText = "フォルダ内に画像が見つかりませんでした。"
                return
            }
            addImageFiles(files)
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "プロジェクトを開く"
        panel.prompt = "開く"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [projectFileType, .json]
        if panel.runModal() == .OK, let url = panel.url {
            _ = loadProject(from: url, asAutosaveRestore: false)
        }
    }

    func saveProjectPanel() {
        guard !sessions.isEmpty else {
            statusText = "保存対象がありません。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "プロジェクトを保存"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [projectFileType]
        panel.nameFieldStringValue = defaultProjectName()
        if panel.runModal() == .OK, let raw = panel.url {
            let url = ensureProjectExtension(for: raw)
            _ = saveProject(to: url, updateStatus: true)
        }
    }

    func newProject() {
        objectWillChange.send()
        sessions.removeAll()
        activeIndex = -1
        mode = .idle
        pendingPoints.removeAll()
        hoverScreenPoint = nil
        highlightedMeasurementID = nil
        pendingScalePixels = nil
        showScaleSheet = false
        scaleInputLength = ""
        lastCalibration = nil
        statusText = "新規プロジェクトを開始しました。"
        scheduleAutosave()
    }

    func addImageFiles(_ urls: [URL]) {
        let loaded = urls.compactMap { url in
            autoreleasepool {
                loadSession(url: url)
            }
        }
        guard !loaded.isEmpty else {
            statusText = "画像読込エラー: 読み込めるファイルがありませんでした。"
            return
        }

        objectWillChange.send()
        sessions.append(contentsOf: loaded)
        if activeIndex < 0 {
            activeIndex = sessions.count - loaded.count
            fitActiveToCanvasIfPossible()
        }
        statusText = "\(loaded.count)件の画像を追加しました。"
        scheduleAutosave()
    }

    func switchSession(delta: Int) {
        guard !sessions.isEmpty else { return }
        var next = activeIndex
        next = (next + delta + sessions.count) % sessions.count
        activateSession(index: next)
    }

    func activateSession(index: Int) {
        guard sessions.indices.contains(index) else { return }
        objectWillChange.send()
        pendingPoints.removeAll()
        highlightedMeasurementID = nil
        activeIndex = index
        if !(activeSession?.hasCustomTransform ?? false) {
            fitActiveToCanvasIfPossible()
        }
        if let name = activeSession?.name {
            statusText = "画像切替: \(name)"
        }
        scheduleAutosave()
    }

    func setMode(_ next: MeasureMode) {
        objectWillChange.send()
        mode = next
        pendingPoints.removeAll()
        scheduleAutosave()
    }

    func toggleRounding() {
        roundingMode = (roundingMode == .round) ? .ceil : .round
        UserDefaults.standard.set(roundingMode.rawValue, forKey: roundingKey)
        objectWillChange.send()
        statusText = "丸め規則を\(roundingMode.label)に変更しました。"
        scheduleAutosave()
    }

    func toggleContinuousMeasure() {
        setContinuousMeasure(!continuousMeasure)
    }

    func setContinuousMeasure(_ enabled: Bool) {
        guard continuousMeasure != enabled else { return }
        continuousMeasure = enabled
        UserDefaults.standard.set(continuousMeasure, forKey: continuousKey)
        objectWillChange.send()
        statusText = "連続測長を\(continuousMeasure ? "ON" : "OFF")にしました。"
        scheduleAutosave()
    }

    func toggleEdgeSnap() {
        setEdgeSnap(!edgeSnap)
    }

    func setEdgeSnap(_ enabled: Bool) {
        guard edgeSnap != enabled else { return }
        edgeSnap = enabled
        UserDefaults.standard.set(edgeSnap, forKey: snapKey)
        objectWillChange.send()
        statusText = "点スナップを\(edgeSnap ? "ON" : "OFF")にしました。"
        scheduleAutosave()
    }

    func updateCanvasSize(_ size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let unchanged = abs(canvasSize.width - size.width) < 0.5
            && abs(canvasSize.height - size.height) < 0.5
        if unchanged {
            return
        }
        canvasSize = size
        if let session = activeSession, !session.hasCustomTransform {
            fit(session: session, canvasSize: size)
            objectWillChange.send()
        }
    }

    func fitActiveToCanvasIfPossible() {
        guard let session = activeSession, canvasSize.width > 0, canvasSize.height > 0 else { return }
        fit(session: session, canvasSize: canvasSize)
    }

    func resetView() {
        guard let session = activeSession else { return }
        fit(session: session, canvasSize: canvasSize)
        objectWillChange.send()
        statusText = "表示をリセットしました。"
        scheduleAutosave()
    }

    func pan(byScreen delta: CGSize) {
        guard let session = activeSession else { return }
        session.transform.tx += delta.width
        session.transform.ty += delta.height
        session.hasCustomTransform = true
        scheduleAutosave()
    }

    func zoom(atScreen point: CGPoint, factor: Double) {
        guard let session = activeSession else { return }
        guard factor.isFinite, factor > 0 else { return }

        let old = session.transform
        let imageX = (point.x - old.tx) / old.scale
        let imageY = (point.y - old.ty) / old.scale

        let nextScale = clamp(old.scale * factor, minScale, maxScale)
        session.transform.scale = nextScale
        session.transform.tx = point.x - imageX * nextScale
        session.transform.ty = point.y - imageY * nextScale
        session.hasCustomTransform = true

        scheduleAutosave()
    }

    func imagePoint(fromScreen point: CGPoint) -> MeasurePoint? {
        guard let session = activeSession else { return nil }
        let x = (point.x - session.transform.tx) / session.transform.scale
        let y = (point.y - session.transform.ty) / session.transform.scale
        return MeasurePoint(x: x, y: y)
    }

    func screenPoint(fromImage point: MeasurePoint) -> CGPoint? {
        guard let session = activeSession else { return nil }
        let x = point.x * session.transform.scale + session.transform.tx
        let y = point.y * session.transform.scale + session.transform.ty
        return CGPoint(x: x, y: y)
    }

    func updateHover(screenPoint: CGPoint?) {
        if hoverScreenPoint == screenPoint {
            return
        }
        hoverScreenPoint = screenPoint
    }

    func commitClick(atScreen screenPoint: CGPoint) {
        guard let rawImagePoint = imagePoint(fromScreen: screenPoint) else { return }
        guard let session = activeSession else { return }

        var imagePoint = clampPoint(rawImagePoint, to: session)
        if edgeSnap {
            let snapped = snap(point: imagePoint, in: session)
            if distance(snapped, imagePoint) > 0.1 {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
            imagePoint = snapped
        }
        commitImagePoint(imagePoint)
    }

    func cancelAction() {
        if !pendingPoints.isEmpty {
            pendingPoints.removeAll()
            objectWillChange.send()
            statusText = "キャンセル: 操作中の点をクリアしました。"
            return
        }

        guard let session = activeSession else {
            statusText = "キャンセル: 何もありません。"
            return
        }

        guard !session.results.isEmpty else {
            statusText = "キャンセル: 何もありません。"
            return
        }

        let previous = session.results
        let prevNext = session.nextResultID
        let prevHighlight = highlightedMeasurementID
        let removed = session.results.removeFirst()
        if highlightedMeasurementID == removed.id {
            highlightedMeasurementID = nil
        }
        registerUndo(sessionID: session.id,
                     previousResults: previous,
                     previousNextID: prevNext,
                     previousHighlight: prevHighlight,
                     actionName: "測定取消")
        objectWillChange.send()
        statusText = "キャンセル: #\(removed.id) を取り消しました。"
        scheduleAutosave()
    }

    func deleteMeasurement(id: Int) {
        guard let session = activeSession else { return }
        guard session.results.contains(where: { $0.id == id }) else { return }

        let previous = session.results
        let prevNext = session.nextResultID
        let prevHighlight = highlightedMeasurementID

        session.results.removeAll { $0.id == id }
        if highlightedMeasurementID == id {
            highlightedMeasurementID = nil
        }
        registerUndo(sessionID: session.id,
                     previousResults: previous,
                     previousNextID: prevNext,
                     previousHighlight: prevHighlight,
                     actionName: "測定削除")
        objectWillChange.send()
        scheduleAutosave()
    }

    func clearMeasurements() {
        guard let session = activeSession, !session.results.isEmpty else { return }

        let previous = session.results
        let prevNext = session.nextResultID
        let prevHighlight = highlightedMeasurementID

        session.results.removeAll()
        session.nextResultID = 1
        pendingPoints.removeAll()
        highlightedMeasurementID = nil

        registerUndo(sessionID: session.id,
                     previousResults: previous,
                     previousNextID: prevNext,
                     previousHighlight: prevHighlight,
                     actionName: "測定全削除")
        objectWillChange.send()
        statusText = "現在画像の測定結果を削除しました。"
        scheduleAutosave()
    }

    func toggleHighlight(_ id: Int) {
        highlightedMeasurementID = (highlightedMeasurementID == id) ? nil : id
        objectWillChange.send()
    }

    func copyCurrentCSV() {
        guard let session = activeSession else { return }
        let tsv = buildCSV(for: [session])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
        statusText = "CSVコピー完了: 現在画像をコピーしました。"
    }

    func copyAllCSV() {
        let measured = sessions.filter { !$0.results.isEmpty }
        guard !measured.isEmpty else {
            statusText = "一括コピー対象がありません。"
            return
        }
        let tsv = buildCSV(for: measured)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
        statusText = "CSVコピー全画面完了: \(measured.count)列をコピーしました。"
    }

    func saveAnnotatedCurrent() {
        guard let session = activeSession else { return }
        guard !session.results.isEmpty else {
            statusText = "保存対象がありません。"
            return
        }
        guard let data = annotatedPNGData(for: session) else {
            statusText = "画像保存に失敗しました。"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = measuredExportName(for: session.name)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                statusText = "画面保存完了: \(url.lastPathComponent)"
            } catch {
                statusText = "画像保存に失敗しました。"
            }
        }
    }

    func saveAnnotatedAll() {
        let measured = sessions.filter { !$0.results.isEmpty }
        guard !measured.isEmpty else {
            statusText = "保存対象がありません。"
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "保存"
        panel.message = "保存先フォルダを選択"

        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var used = Set<String>()
        var savedCount = 0

        for session in measured {
            guard let data = annotatedPNGData(for: session) else { continue }
            let base = measuredExportName(for: session.name)
            let fileName = uniqueFileName(base: base, used: &used, directory: dir)
            let url = dir.appendingPathComponent(fileName)
            do {
                try data.write(to: url)
                savedCount += 1
            } catch {
                continue
            }
        }

        statusText = "画面保存全画面完了: \(savedCount)件保存しました。"
    }

    func applyScaleInput() {
        guard let px = pendingScalePixels, px > 0 else {
            cancelScaleInput()
            return
        }

        let unitRaw = scaleInputUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unitRaw.isEmpty ? "µm" : unitRaw

        let normalized = scaleInputLength.replacingOccurrences(of: ",", with: ".")
        guard let realLength = Double(normalized), realLength.isFinite, realLength > 0 else {
            statusText = "スケール入力が不正です。"
            return
        }

        guard let session = activeSession else { return }

        let calibration = Calibration(unit: unit, unitsPerPixel: realLength / px)
        session.calibration = calibration
        lastCalibration = calibration

        pendingScalePixels = nil
        showScaleSheet = false
        scaleInputLength = ""
        objectWillChange.send()
        statusText = "スケール確定: \(formatSig(calibration.unitsPerPixel)) \(unit)/px"
        scheduleAutosave()
    }

    func cancelScaleInput() {
        pendingScalePixels = nil
        showScaleSheet = false
        scaleInputLength = ""
        statusText = "スケール入力をキャンセルしました。"
    }

    func formattedLength(pixelLength: Double, calibration: Calibration? = nil) -> String {
        let calibration = calibration ?? activeSession?.calibration
        if let c = calibration {
            return "\(formatSig(pixelLength * c.unitsPerPixel)) \(c.unit)"
        }
        return "\(formatSig(pixelLength)) px"
    }

    func formatSig(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == 0 { return "0." + String(repeating: "0", count: displayDigits) }

        let rounded = roundToSignificant(value, digits: displayDigits, mode: roundingMode)
        if rounded == 0 { return "0." + String(repeating: "0", count: displayDigits) }

        let exp = floor(log10(abs(rounded)))
        let decimals = max(0, displayDigits - Int(exp) - 1)
        return String(format: "%.*f", decimals, rounded)
    }

    func screenRectForActiveImage(in canvasSize: CGSize) -> CGRect {
        guard let session = activeSession else { return .zero }
        let t = session.transform
        let width = session.pixelSize.width * t.scale
        let height = session.pixelSize.height * t.scale
        return CGRect(x: t.tx, y: t.ty, width: width, height: height)
    }

    private func commitImagePoint(_ imagePoint: MeasurePoint) {
        guard let session = activeSession else { return }

        pendingPoints.append(imagePoint)
        objectWillChange.send()

        if pendingPoints.count == 1 {
            if mode == .idle {
                mode = .measure
            }
            if mode == .scale {
                statusText = "スケール: 2点目をクリック → 実長入力"
            } else {
                statusText = "測長中: 2点目クリックで確定 / 右クリックorESCで戻る"
            }
            return
        }

        guard pendingPoints.count == 2 else {
            pendingPoints = Array(pendingPoints.prefix(2))
            return
        }

        let p1 = pendingPoints[0]
        let p2 = pendingPoints[1]
        let px = distance(p1, p2)

        if px <= 0.0001 {
            pendingPoints.removeAll()
            statusText = "点が同じです。やり直してください。"
            objectWillChange.send()
            return
        }

        if mode == .scale {
            pendingPoints.removeAll()
            pendingScalePixels = px
            scaleInputUnit = session.calibration?.unit ?? lastCalibration?.unit ?? "µm"
            scaleInputLength = ""
            showScaleSheet = true
            statusText = "スケール値を入力してください。"
            objectWillChange.send()
            return
        }

        adoptLastCalibrationIfNeeded(for: session)
        addMeasurement(to: session, p1: p1, p2: p2, pixelLength: px)

        if continuousMeasure {
            pendingPoints = [p2]
            statusText = "測長追加: \(formattedLength(pixelLength: px))（連続測長ON）"
        } else {
            pendingPoints.removeAll()
            statusText = "測長追加: \(formattedLength(pixelLength: px))"
        }

        objectWillChange.send()
    }

    private func addMeasurement(to session: ImageSession, p1: MeasurePoint, p2: MeasurePoint, pixelLength: Double) {
        let previous = session.results
        let prevNext = session.nextResultID
        let prevHighlight = highlightedMeasurementID

        let result = Measurement(id: session.nextResultID,
                                 p1: p1,
                                 p2: p2,
                                 pixelLength: pixelLength,
                                 createdAt: Date())
        session.nextResultID += 1
        session.results.insert(result, at: 0)
        highlightedMeasurementID = result.id

        registerUndo(sessionID: session.id,
                     previousResults: previous,
                     previousNextID: prevNext,
                     previousHighlight: prevHighlight,
                     actionName: "測定追加")
        scheduleAutosave()
    }

    private func adoptLastCalibrationIfNeeded(for session: ImageSession) {
        if session.calibration == nil, let calibration = lastCalibration {
            session.calibration = calibration
        }
        if let current = session.calibration {
            lastCalibration = current
        }
    }

    private func registerUndo(sessionID: UUID,
                              previousResults: [Measurement],
                              previousNextID: Int,
                              previousHighlight: Int?,
                              actionName: String) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            target.applySessionSnapshot(sessionID: sessionID,
                                        results: previousResults,
                                        nextID: previousNextID,
                                        highlightID: previousHighlight)
        }
        manager.setActionName(actionName)
    }

    private func applySessionSnapshot(sessionID: UUID,
                                      results: [Measurement],
                                      nextID: Int,
                                      highlightID: Int?) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.results = results
        session.nextResultID = nextID
        highlightedMeasurementID = highlightID
        objectWillChange.send()
        scheduleAutosave()
    }

    private func loadSession(url: URL) -> ImageSession? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let thumbnail = makeThumbnail(from: image)
        return ImageSession(name: url.lastPathComponent, url: url, image: image, thumbnail: thumbnail, cgImage: cg)
    }

    private func makeThumbnail(from image: NSImage, maxSide: CGFloat = 160) -> NSImage {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return image }

        let scale = min(1, maxSide / max(srcSize.width, srcSize.height))
        let thumbSize = NSSize(width: max(1, floor(srcSize.width * scale)),
                               height: max(1, floor(srcSize.height * scale)))
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocusFlipped(true)
        image.draw(in: CGRect(origin: .zero, size: thumbSize),
                   from: CGRect(origin: .zero, size: srcSize),
                   operation: .copy,
                   fraction: 1,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.low])
        thumb.unlockFocus()
        return thumb
    }

    private func fit(session: ImageSession, canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let sx = canvasSize.width / session.pixelSize.width
        let sy = canvasSize.height / session.pixelSize.height
        let scale = min(sx, sy)
        let tx = (canvasSize.width - session.pixelSize.width * scale) * 0.5
        let ty = (canvasSize.height - session.pixelSize.height * scale) * 0.5
        session.transform = ViewTransform(scale: scale, tx: tx, ty: ty)
        session.hasCustomTransform = false
    }

    private func clampPoint(_ point: MeasurePoint, to session: ImageSession) -> MeasurePoint {
        let x = clamp(point.x, 0, session.pixelSize.width)
        let y = clamp(point.y, 0, session.pixelSize.height)
        return MeasurePoint(x: x, y: y)
    }

    private func snap(point: MeasurePoint, in session: ImageSession) -> MeasurePoint {
        guard let luma = lumaCache(for: session) else { return point }
        guard luma.width >= 3, luma.height >= 3 else { return point }

        let centerX = Int(clamp(point.x.rounded(), 1, Double(luma.width - 2)))
        let centerY = Int(clamp(point.y.rounded(), 1, Double(luma.height - 2)))

        let radius = max(1, Int((snapRadiusScreen / session.transform.scale).rounded()))
        let minX = max(1, centerX - radius)
        let maxX = min(luma.width - 2, centerX + radius)
        let minY = max(1, centerY - radius)
        let maxY = min(luma.height - 2, centerY + radius)

        var bestX = centerX
        var bestY = centerY
        var bestScore = -1.0
        let rr = radius * radius

        for y in minY...maxY {
            let dy = y - centerY
            for x in minX...maxX {
                let dx = x - centerX
                if dx * dx + dy * dy > rr { continue }

                let gx = abs(Double(sampleLuma(luma, x + 1, y)) - Double(sampleLuma(luma, x - 1, y)))
                let gy = abs(Double(sampleLuma(luma, x, y + 1)) - Double(sampleLuma(luma, x, y - 1)))
                let score = gx + gy
                if score > bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
            }
        }

        if bestScore < snapMinScore {
            return point
        }

        return MeasurePoint(x: Double(bestX), y: Double(bestY))
    }

    private func lumaCache(for session: ImageSession) -> LumaCache? {
        if let cache = session.lumaCache {
            return cache
        }

        let width = session.cgImage.width
        let height = session.cgImage.height
        guard width > 0, height > 0 else { return nil }

        var luma = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &luma,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            return nil
        }

        ctx.interpolationQuality = .none
        ctx.draw(session.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cache = LumaCache(width: width, height: height, pixels: luma)
        session.lumaCache = cache
        return cache
    }

    private func sampleLuma(_ cache: LumaCache, _ x: Int, _ y: Int) -> UInt8 {
        cache.pixels[y * cache.width + x]
    }

    private func buildCSV(for sessions: [ImageSession]) -> String {
        let hasMultiple = sessions.count > 1
        if !hasMultiple, let session = sessions.first {
            let unit = session.calibration?.unit ?? "px"
            var rows = ["PositionNo\t\(session.name)", "Unit\t\(unit)"]
            let ordered = Array(session.results.reversed())
            for (idx, result) in ordered.enumerated() {
                let v = formattedRawLength(result.pixelLength, calibration: session.calibration)
                rows.append("\(idx + 1)\t\(formatSig(v))")
            }
            return rows.joined(separator: "\n")
        }

        let withResults = sessions.filter { !$0.results.isEmpty }
        let headers = withResults.map { $0.name }
        let units = withResults.map { $0.calibration?.unit ?? "px" }
        let values: [[String]] = withResults.map { session in
            Array(session.results.reversed()).map { result in
                formatSig(formattedRawLength(result.pixelLength, calibration: session.calibration))
            }
        }
        let maxRows = values.map { $0.count }.max() ?? 0

        var rows = ["PositionNo\t" + headers.joined(separator: "\t")]
        rows.append("Unit\t" + units.joined(separator: "\t"))
        for row in 0..<maxRows {
            let cols = values.map { row < $0.count ? $0[row] : "" }.joined(separator: "\t")
            rows.append("\(row + 1)\t\(cols)")
        }
        return rows.joined(separator: "\n")
    }

    private func formattedRawLength(_ pixelLength: Double, calibration: Calibration?) -> Double {
        guard let c = calibration else { return pixelLength }
        return pixelLength * c.unitsPerPixel
    }

    private func annotatedPNGData(for session: ImageSession) -> Data? {
        let size = NSSize(width: session.pixelSize.width, height: session.pixelSize.height)
        let out = NSImage(size: size)
        out.lockFocusFlipped(true)

        defer { out.unlockFocus() }

        session.image.draw(in: CGRect(origin: .zero, size: size),
                           from: .zero,
                           operation: .copy,
                           fraction: 1,
                           respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.none])

        NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.0, alpha: 0.95).setStroke()
        NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.0, alpha: 0.95).setFill()

        for measurement in session.results.reversed() {
            let p1 = measurement.p1.cgPoint
            let p2 = measurement.p2.cgPoint

            let line = NSBezierPath()
            line.lineWidth = max(1.5, min(4, size.width / 800))
            line.move(to: p1)
            line.line(to: p2)
            line.stroke()

            let mx = (p1.x + p2.x) * 0.5
            let my = (p1.y + p2.y) * 0.5
            let text = "#\(measurement.id) \(formattedLength(pixelLength: measurement.pixelLength, calibration: session.calibration))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(12, size.width / 120), weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 0.98)
            ]

            let tSize = text.size(withAttributes: attrs)
            let box = CGRect(x: max(4, min(size.width - tSize.width - 14, mx + 8)),
                             y: max(4, min(size.height - 24, my + 8)),
                             width: tSize.width + 10,
                             height: 18)
            NSColor(calibratedWhite: 0.08, alpha: 0.78).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
        }

        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private func measuredExportName(for fileName: String) -> String {
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        if ext.isEmpty {
            return "\(base)_計測済み.png"
        }
        return "\(base)_計測済み.png"
    }

    private func uniqueFileName(base: String, used: inout Set<String>, directory: URL) -> String {
        func withIndex(_ idx: Int) -> String {
            guard idx > 0 else { return base }
            let ns = base as NSString
            let ext = ns.pathExtension
            let stem = ns.deletingPathExtension
            if ext.isEmpty {
                return "\(stem)_\(String(format: "%02d", idx))"
            }
            return "\(stem)_\(String(format: "%02d", idx)).\(ext)"
        }

        var idx = 0
        while true {
            let name = withIndex(idx)
            if used.contains(name) {
                idx += 1
                continue
            }
            let fileURL = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                used.insert(name)
                return name
            }
            idx += 1
        }
    }

    private var projectFileType: UTType {
        UTType(filenameExtension: projectExtension) ?? .json
    }

    private var autosaveURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent(autosaveDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent(autosaveFileName)
    }

    private func defaultProjectName() -> String {
        if let active = activeSession {
            let base = (active.name as NSString).deletingPathExtension
            return "\(base).\(projectExtension)"
        }
        return "SokuchoProject.\(projectExtension)"
    }

    private func ensureProjectExtension(for url: URL) -> URL {
        if url.pathExtension.lowercased() == projectExtension {
            return url
        }
        return url.appendingPathExtension(projectExtension)
    }

    @discardableResult
    private func saveProject(to url: URL, updateStatus: Bool) -> Bool {
        let document = makeProjectDocument()
        do {
            try writeProjectDocument(document, to: url)
            if updateStatus {
                statusText = "プロジェクトを保存しました: \(url.lastPathComponent)"
            }
            return true
        } catch {
            if updateStatus {
                statusText = "プロジェクト保存に失敗しました。"
            }
            return false
        }
    }

    @discardableResult
    private func loadProject(from url: URL, asAutosaveRestore: Bool) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(ProjectDocument.self, from: data)

            var loadedSessions: [ImageSession] = []
            var missingFiles: [String] = []

            for state in document.sessions {
                let imageURL = URL(fileURLWithPath: state.imagePath)
                guard FileManager.default.fileExists(atPath: imageURL.path),
                      let session = loadSession(url: imageURL) else {
                    missingFiles.append((state.imagePath as NSString).lastPathComponent)
                    continue
                }
                session.calibration = state.calibration
                session.transform = state.transform
                session.hasCustomTransform = state.hasCustomTransform
                session.results = state.results
                let maxID = session.results.map(\.id).max() ?? 0
                session.nextResultID = max(state.nextResultID, maxID + 1)
                loadedSessions.append(session)
            }

            guard !loadedSessions.isEmpty else {
                if !asAutosaveRestore {
                    statusText = "プロジェクト読込失敗: 画像ファイルが見つかりません。"
                }
                return false
            }

            objectWillChange.send()
            sessions = loadedSessions
            activeIndex = max(0, min(document.activeIndex, loadedSessions.count - 1))
            mode = .idle
            pendingPoints.removeAll()
            hoverScreenPoint = nil
            highlightedMeasurementID = nil
            pendingScalePixels = nil
            showScaleSheet = false
            scaleInputLength = ""
            if !(activeSession?.hasCustomTransform ?? false) {
                fitActiveToCanvasIfPossible()
            }
            lastCalibration = activeSession?.calibration ?? loadedSessions.compactMap(\.calibration).last

            if asAutosaveRestore {
                statusText = "前回の作業を復元しました。(\(loadedSessions.count)枚)"
            } else if missingFiles.isEmpty {
                statusText = "プロジェクト読込完了: \(loadedSessions.count)枚を読み込みました。"
            } else {
                statusText = "プロジェクト読込完了: \(loadedSessions.count)枚（不足 \(missingFiles.count)件）"
            }
            scheduleAutosave()
            return true
        } catch {
            if !asAutosaveRestore {
                statusText = "プロジェクト読込に失敗しました。"
            }
            return false
        }
    }

    private func makeProjectDocument() -> ProjectDocument {
        let projectSessions = sessions.compactMap { session -> ProjectSessionState? in
            guard let imagePath = session.url?.path else { return nil }
            return ProjectSessionState(
                name: session.name,
                imagePath: imagePath,
                calibration: session.calibration,
                transform: session.transform,
                hasCustomTransform: session.hasCustomTransform,
                nextResultID: session.nextResultID,
                results: session.results
            )
        }

        let clampedActive: Int
        if projectSessions.isEmpty {
            clampedActive = -1
        } else {
            clampedActive = max(0, min(activeIndex, projectSessions.count - 1))
        }

        return ProjectDocument(
            version: 1,
            exportedAt: Date(),
            activeIndex: clampedActive,
            sessions: projectSessions
        )
    }

    private func writeProjectDocument(_ document: ProjectDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    private func restoreAutosaveIfPossible() {
        guard let url = autosaveURL, FileManager.default.fileExists(atPath: url.path) else { return }
        _ = loadProject(from: url, asAutosaveRestore: true)
    }

    private func scheduleAutosave() {
        autosaveRevision &+= 1
        if autosaveTask != nil {
            return
        }
        autosaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                let revision = self.autosaveRevision
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                if self.autosaveRevision != revision {
                    continue
                }
                self.saveAutosaveNow()
                self.autosaveTask = nil
                return
            }
        }
    }

    private func saveAutosaveNow() {
        guard let url = autosaveURL else { return }
        let document = makeProjectDocument()
        if document.sessions.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? writeProjectDocument(document, to: url)
    }

    private func imageFiles(in directoryURL: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }

            if let contentType = values.contentType {
                let matched = supportedImageTypes.contains { contentType.conforms(to: $0) }
                if matched {
                    files.append(fileURL)
                }
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            let matched = supportedImageTypes.contains {
                ($0.preferredFilenameExtension?.lowercased() ?? "") == ext
            }
            if matched {
                files.append(fileURL)
            }
        }

        files.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return files
    }

    private func roundToSignificant(_ value: Double, digits: Int, mode: RoundingMode) -> Double {
        guard value.isFinite, value != 0 else { return value }
        let absVal = abs(value)
        let exponent = floor(log10(absVal))
        let shift = Double(digits - Int(exponent) - 1)
        let rounder: (Double) -> Double
        if mode == .ceil {
            rounder = { Foundation.ceil($0) }
        } else {
            rounder = { Foundation.round($0) }
        }

        if shift >= 0 {
            let factor = pow(10, shift)
            return rounder(value * factor) / factor
        } else {
            let factor = pow(10, -shift)
            return rounder(value / factor) * factor
        }
    }

    private func clamp(_ value: Double, _ minV: Double, _ maxV: Double) -> Double {
        max(minV, min(maxV, value))
    }

    private func distance(_ a: MeasurePoint, _ b: MeasurePoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
