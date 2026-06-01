import Foundation

public struct Idea: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var transcript: String
    public var title: String
    public var bullets: [String]
    public var forestPath: String
    public var durationSeconds: Double
    public var project: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcript: String,
        title: String,
        bullets: [String] = [],
        forestPath: String,
        durationSeconds: Double,
        project: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.title = title
        self.bullets = bullets
        self.forestPath = forestPath
        self.durationSeconds = durationSeconds
        self.project = project
    }
}
