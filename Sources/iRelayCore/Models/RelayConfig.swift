import Foundation

/// 模型信息（从 /v1/models 解析）
public struct ModelInfo: Identifiable, Equatable, Codable {
    public let id: String
    public let description: String
    public var displayName: String { description.isEmpty ? id : description }
    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}
