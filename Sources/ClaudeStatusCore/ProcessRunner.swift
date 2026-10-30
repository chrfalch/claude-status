import Foundation
import Darwin

public struct CommandError: LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func drain(_ handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            else if count < 0 && errno == EINTR { continue }
            else { return }
        }
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public enum ProcessRunner {
    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let output = CommandOutput()
        let terminated = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let flags = fcntl(reader.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(reader.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw CommandError(message: "Cannot configure command output")
        }
        reader.readabilityHandler = { output.drain($0) }
        defer { reader.readabilityHandler = nil }
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        guard terminated.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)
            // Descendants can retain stdout after the child is killed.
            throw CommandError(message: "Command timed out after \(timeout) seconds")
        }
        output.drain(reader)
        guard process.terminationStatus == 0 else {
            throw CommandError(message: "Command failed (exit \(process.terminationStatus))")
        }
        return output.snapshot
    }
}
