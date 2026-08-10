import Foundation

extension String {
  /// Version strings must be digits-and-dots only (e.g. "8.0.1"); anything else
  /// is filtered out and never wins a comparison.
  var isSemanticVersion: Bool {
    range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
  }
}

extension Array where Element == String {
  /// Returns the maximum semantic version in the array
  func semanticMax() -> String? {
    let validVersions = self.filter { $0.isSemanticVersion }
    return validVersions.sorted { compareSemanticVersions($0, $1) == .orderedAscending }.last
  }

  /// Returns the minimum semantic version in the array
  func semanticMin() -> String? {
    let validVersions = self.filter { $0.isSemanticVersion }
    return validVersions.sorted { compareSemanticVersions($0, $1) == .orderedAscending }.first
  }

  private func compareSemanticVersions(_ v1: String, _ v2: String) -> ComparisonResult {
    let components1 = v1.split(separator: ".").compactMap { Int($0) }
    let components2 = v2.split(separator: ".").compactMap { Int($0) }

    for (c1, c2) in zip(components1, components2) {
      if c1 < c2 { return .orderedAscending }
      if c1 > c2 { return .orderedDescending }
    }

    return components1.count < components2.count
      ? .orderedAscending
      : (components1.count > components2.count ? .orderedDescending : .orderedSame)
  }
}
