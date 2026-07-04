import Foundation

struct PDFHighlightRect: Codable, Equatable {
    let page: Int
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct PDFHighlightRecord: Equatable {
    let id: UUID
    let sourceId: UUID
    let page: Int
    let rects: [PDFHighlightRect]
    let quote: String
    let createdAt: Date
}
