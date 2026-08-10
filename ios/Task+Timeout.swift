import Foundation

struct TimeoutError: Error {}

actor CompletionState {
  private var isCompleted = false

  func checkAndSetCompleted() -> Bool {
    if !isCompleted {
      isCompleted = true
      return true
    } else {
      return false
    }
  }
}

public extension Task where Failure == Error {
  /// Runs `operation` with a hard timeout; throws TimeoutError when it expires
  /// first. Whichever side finishes first wins the (single) continuation resume.
  static func withCheckedTimeout(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> Success
  ) async throws -> Success {
    let completionState = CompletionState()
    return try await withCheckedThrowingContinuation { continuation in
      Task<Void, Error> {
        do {
          let result = try await operation()
          if await completionState.checkAndSetCompleted() {
            continuation.resume(returning: result)
          }
        } catch {
          if await completionState.checkAndSetCompleted() {
            continuation.resume(throwing: error)
          }
        }
      }

      Task<Void, Never> {
        try? await Task<Never, Never>.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if await completionState.checkAndSetCompleted() {
          continuation.resume(throwing: TimeoutError())
        }
      }
    }
  }
}
