import Foundation

struct RunningProcess {
    let process: Process
    let outputPipe: Pipe
    let errorPipe: Pipe
}

enum ProcessRunner {
    static func start(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @MainActor (String) -> Void,
        onTermination: (@MainActor (Int32) -> Void)? = nil
    ) throws -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        func attach(_ pipe: Pipe) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in
                    onOutput(text)
                }
            }
        }

        attach(outputPipe)
        attach(errorPipe)

        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if let onTermination {
                Task { @MainActor in
                    onTermination(process.terminationStatus)
                }
            }
        }

        try process.run()
        return RunningProcess(process: process, outputPipe: outputPipe, errorPipe: errorPipe)
    }
}
