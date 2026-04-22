import Foundation

/// Simple file-based logger for debugging without Mac/Console.app
final class FileLogger {
    
    static let shared = FileLogger()
    
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.iosmirror.filelogger")
    
    private init() {
        // Save to Documents directory (accessible via Files app)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documentsPath.appendingPathComponent("debug.log")
        
        // Clear old log on app start
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }
    
    func log(_ message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            
            if let existing = try? String(contentsOf: self.logFileURL, encoding: .utf8) {
                try? (existing + line).write(to: self.logFileURL, atomically: true, encoding: .utf8)
            } else {
                try? line.write(to: self.logFileURL, atomically: true, encoding: .utf8)
            }
        }
    }
    
    func getLogContents() -> String {
        return (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }
    
    func clear() {
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }
}