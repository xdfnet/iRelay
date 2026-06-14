import Foundation

/// 模型信息（从 /v1/models 解析）
struct ModelInfo: Identifiable, Equatable, Codable {
    let id: String
    let description: String
    var displayName: String { description.isEmpty ? id : description }
}
