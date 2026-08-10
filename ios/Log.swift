import Foundation
import os

/// OTA logging with the same "CashifyOTA" tag as Android, via os_log so lines are
/// visible in Console.app / `log stream --predicate 'eventMessage CONTAINS "CashifyOTA"'`
/// even in Release builds.
enum Log {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "CashifyOps",
    category: "CashifyOTA"
  )

  static func d(_ message: String) {
    logger.log("CashifyOTA::\(message, privacy: .public)")
  }

  static func e(_ message: String) {
    logger.error("CashifyOTA::ERROR::\(message, privacy: .public)")
  }
}
