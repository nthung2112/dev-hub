import Foundation

/// A developer cache that's safe to empty: the tools rebuild it on their next run.
public enum CleanupTarget: String, CaseIterable, Identifiable, Sendable {
    case derivedData, yarnCache, gradleCaches

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .derivedData: return "Xcode DerivedData"
        case .yarnCache: return "Yarn cache"
        case .gradleCaches: return "Gradle caches"
        }
    }

    /// What emptying it costs, for the confirmation.
    public var warning: String {
        switch self {
        case .derivedData: return "Xcode rebuilds each project from scratch the next time. Quit Xcode first."
        case .yarnCache: return "The next yarn install downloads every package again from Artifactory."
        case .gradleCaches: return "The next Gradle build downloads its dependencies again. Stop running Gradle builds and daemons first."
        }
    }
}

public enum DevCleanup {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The folders `target` keeps its cache in, those that exist.
    public static func directories(_ target: CleanupTarget) async -> [URL] {
        var candidates: [URL]
        switch target {
        case .derivedData:
            candidates = [home.appendingPathComponent("Library/Developer/Xcode/DerivedData")]
        case .yarnCache:
            candidates = [home.appendingPathComponent("Library/Caches/Yarn"), home.appendingPathComponent(".yarn/berry/cache")]
            if let yarn = Shell.find("yarn"), let result = try? await Shell.run(yarn, ["cache", "dir"], timeout: 10), result.succeeded,
               let path = yarnCacheDir(result.stdout) {
                candidates.insert(URL(fileURLWithPath: path), at: 0)
            }
        case .gradleCaches:
            candidates = [home.appendingPathComponent(".gradle/caches")]
        }
        return outermost(candidates.filter(isDirectory))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Without duplicates or folders inside another one listed, so nothing is counted twice.
    static func outermost(_ urls: [URL]) -> [URL] {
        let paths = urls.map { $0.standardizedFileURL.path }
        var seen: Set<String> = []
        return zip(urls, paths).filter { _, path in
            !paths.contains { path.hasPrefix($0 + "/") } && seen.insert(path).inserted
        }.map(\.0)
    }

    /// The last line `yarn cache dir` prints that's an absolute path; nil for Yarn 2+, which has no
    /// such command outside a project.
    static func yarnCacheDir(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    /// The space the folders take on disk. Walks every file, so it runs off the main thread.
    public static func size(of directories: [URL]) async -> Int64 {
        await Task.detached(priority: .utility) {
            directories.reduce(Int64(0)) { $0 + allocatedSize($1) }
        }.value
    }

    static func allocatedSize(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes everything inside the folders, keeping the folders themselves.
    public static func clean(_ target: CleanupTarget) async throws {
        let directories = await directories(target)
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            for directory in directories {
                for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    try manager.removeItem(at: item)
                }
            }
        }.value
    }
}
