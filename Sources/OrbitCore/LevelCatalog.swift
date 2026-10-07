import Foundation

public enum LevelCatalog {
    public enum LoadError: Error { case missingResource, emptyCatalog }
    public static func load() throws -> [Level] {
        guard let url = Bundle.module.url(forResource: "levels", withExtension: "json") else {
            throw LoadError.missingResource
        }
        let levels = try JSONDecoder().decode([Level].self, from: Data(contentsOf: url))
        guard !levels.isEmpty else { throw LoadError.emptyCatalog }
        return levels
    }
    /// Bundled sectors and their supplied solutions.
    public static let all: [Level] = {
        do {
            return try load()
        } catch {
            preconditionFailure("OrbitCore level catalog could not be decoded: \(error)")
        }
    }()
}
