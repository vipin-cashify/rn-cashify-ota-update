package `in`.cashify.otaupdate

// Version strings must be digits-and-dots only (e.g. "8.0.1"); anything else
// (pre-release tags, blanks, typos) is filtered out and never wins a comparison.
private val SEMVER_REGEX = Regex("^\\d+(\\.\\d+)*$")

fun String.isSemanticVersion(): Boolean = SEMVER_REGEX.matches(this)

fun List<String>.semanticMax(): String? {
    return this.filter { SEMVER_REGEX.matches(it) }
        .maxWithOrNull { v1, v2 -> compareSemanticVersions(v1, v2) }
}

fun List<String>.semanticMin(): String? {
    return this.filter { SEMVER_REGEX.matches(it) }
        .minWithOrNull { v1, v2 -> compareSemanticVersions(v1, v2) }
}

private fun compareSemanticVersions(v1: String, v2: String): Int {
    val c1 = v1.split(".").mapNotNull { it.toIntOrNull() }
    val c2 = v2.split(".").mapNotNull { it.toIntOrNull() }
    for (i in 0 until minOf(c1.size, c2.size)) {
        if (c1[i] != c2[i]) return c1[i] - c2[i]
    }
    return c1.size - c2.size
}
