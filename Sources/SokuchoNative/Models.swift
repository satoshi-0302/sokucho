import Foundation
import CoreGraphics
import AppKit

struct MeasurePoint: Hashable, Codable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}

struct Measurement: Identifiable, Hashable, Codable {
    let id: Int
    let p1: MeasurePoint
    let p2: MeasurePoint
    let pixelLength: Double
    let createdAt: Date
}

enum MeasureMode: String, CaseIterable {
    case idle
    case measure
    case scale

    var label: String {
        switch self {
        case .idle: return "通常"
        case .measure: return "測長"
        case .scale: return "スケール設定"
        }
    }
}

enum RoundingMode: String, CaseIterable {
    case round
    case ceil

    var label: String {
        switch self {
        case .round: return "四捨五入"
        case .ceil: return "切り上げ"
        }
    }
}

struct Calibration: Hashable, Codable {
    var unit: String
    var unitsPerPixel: Double
}

struct ViewTransform: Hashable, Codable {
    var scale: Double
    var tx: Double
    var ty: Double

    static let identity = ViewTransform(scale: 1, tx: 0, ty: 0)
}

struct LumaCache {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

struct ProjectDocument: Codable {
    var version: Int
    var exportedAt: Date
    var activeIndex: Int
    var sessions: [ProjectSessionState]
}

struct ProjectSessionState: Codable {
    var name: String
    var imagePath: String
    var calibration: Calibration?
    var transform: ViewTransform
    var hasCustomTransform: Bool
    var nextResultID: Int
    var results: [Measurement]
}

final class ImageSession: Identifiable {
    let id = UUID()
    let name: String
    let url: URL?
    let image: NSImage
    let thumbnail: NSImage
    let cgImage: CGImage
    let pixelSize: CGSize

    var transform: ViewTransform = .identity
    var hasCustomTransform = false
    var calibration: Calibration?
    var results: [Measurement] = []
    var nextResultID: Int = 1
    var lumaCache: LumaCache?

    init(name: String, url: URL?, image: NSImage, thumbnail: NSImage, cgImage: CGImage) {
        self.name = name
        self.url = url
        self.image = image
        self.thumbnail = thumbnail
        self.cgImage = cgImage
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    }
}
