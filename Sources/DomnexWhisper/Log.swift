import os

/// Unified-log channel (NSLog does not reach the system log for this app). Never log what the user says.
enum Log {
    static let app = Logger(subsystem: "com.luispinto.domnexwhisper", category: "app")
}
