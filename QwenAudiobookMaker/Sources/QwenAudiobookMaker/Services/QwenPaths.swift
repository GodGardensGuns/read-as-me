import Foundation

enum QwenPaths {
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Qwen Audiobook Maker", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Qwen Audiobook Maker", isDirectory: true)

    static let bundledRuntime = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
        .appendingPathComponent("Runtime", isDirectory: true)

    static let bootstrapScript = bundledRuntime.appendingPathComponent("bootstrap_runtime.sh")
    static let serverScript = bundledRuntime.appendingPathComponent("start_qwen_tts_server.sh")
    static let python = applicationSupport.appendingPathComponent("venvs/qwen-converter/bin/python")
    static let qwenServerExecutable = applicationSupport.appendingPathComponent("venvs/qwen-tts/bin/qwen-tts-demo")
    static let converter = bundledRuntime.appendingPathComponent("Qwen3-Audiobook-Converter/audiobook_converter.py")
    static let cache = applicationSupport.appendingPathComponent("cache", isDirectory: true)
    static let runRoot = applicationSupport.appendingPathComponent("gui_runs", isDirectory: true)

    private static let standardExecutablePath = [
        "/opt/homebrew/bin",
        "/opt/homebrew/opt/python@3.12/bin",
        "/usr/local/bin",
        "/usr/local/opt/python@3.12/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ].joined(separator: ":")

    static var defaultOutput: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var converterEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["QWEN_AUDIOBOOK_APP_SUPPORT"] = applicationSupport.path
        environment["QWEN_AUDIOBOOK_RUNTIME"] = bundledRuntime.path
        environment["QWEN_TTS_BIN"] = qwenServerExecutable.path
        environment["QWEN_TTS_PYTHON"] = applicationSupport.appendingPathComponent("venvs/qwen-tts/bin/python").path
        environment["HF_HOME"] = cache.appendingPathComponent("huggingface", isDirectory: true).path
        environment["XDG_CACHE_HOME"] = cache.path
        environment["MPLCONFIGDIR"] = cache.appendingPathComponent("matplotlib", isDirectory: true).path
        environment["PIP_CACHE_DIR"] = cache.appendingPathComponent("pip", isDirectory: true).path
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(standardExecutablePath):\(existingPath)"
        } else {
            environment["PATH"] = standardExecutablePath
        }
        return environment
    }

    static func createMutableDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("huggingface", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("matplotlib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("pip", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
    }

    static func missingBootstrapRequirements() -> [String] {
        [
            bootstrapScript,
            serverScript,
            converter,
            bundledRuntime.appendingPathComponent("requirements-converter.txt"),
            bundledRuntime.appendingPathComponent("requirements-qwen-tts.txt")
        ].filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    static func missingRequirements() -> [String] {
        [
            serverScript,
            python,
            qwenServerExecutable,
            converter
        ].filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }
}
