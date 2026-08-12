package com.skybridge.compass.filetransfer.webrtc

/**
 * Pure, Android-independent filename de-duplication for the Downloads collection.
 *
 * When an accepted inbound file is persisted to Downloads (via MediaStore), a name collision must
 * never silently overwrite an existing file (R5.11). This resolver applies a deterministic rule:
 *  - if the desired name is free, it is returned unchanged;
 *  - otherwise an incrementing " (n)" suffix is appended to the base name, preserving the file
 *    extension (e.g. "report.pdf" -> "report (1).pdf" -> "report (2).pdf" ...);
 *  - if every numbered candidate up to [MAX_SUFFIX] collides, a timestamp-based fallback name is
 *    returned so the write can still proceed without overwriting.
 *
 * Keeping this logic pure (a desired name plus a "name exists" predicate) makes the collision rule
 * unit-testable without a `Context` / `ContentResolver`.
 */
object DownloadsFilenameDeduper {

    /** Highest numeric suffix attempted before falling back to a timestamp-based name. */
    const val MAX_SUFFIX: Int = 999

    /**
     * Returns a non-colliding display name for [desiredName].
     *
     * @param desiredName the display name the caller would like to use.
     * @param nameExists predicate returning true when a name is already taken in the target
     *                   collection.
     * @param timestampProvider source of the fallback disambiguator; injectable for deterministic
     *                          tests. Defaults to wall-clock milliseconds.
     */
    fun deduplicate(
        desiredName: String,
        nameExists: (String) -> Boolean,
        timestampProvider: () -> Long = { System.currentTimeMillis() }
    ): String {
        if (!nameExists(desiredName)) return desiredName

        for (i in 1..MAX_SUFFIX) {
            val candidate = collisionCandidate(desiredName, i)
            if (!nameExists(candidate)) return candidate
        }
        val (base, ext) = splitName(desiredName)
        return "$base-${timestampProvider()}${ext?.let { ".$it" }.orEmpty()}"
    }

    internal fun collisionCandidate(desiredName: String, collisionIndex: Int): String {
        require(collisionIndex >= 0) { "collision index must be non-negative" }
        if (collisionIndex == 0) return desiredName
        val (base, ext) = splitName(desiredName)
        return if (ext == null) "$base ($collisionIndex)" else "$base ($collisionIndex).$ext"
    }

    private fun splitName(desiredName: String): Pair<String, String?> {
        val dot = desiredName.lastIndexOf('.')
        val hasExt = dot > 0 && dot < desiredName.lastIndex
        val base = if (hasExt) desiredName.substring(0, dot) else desiredName
        val ext = if (hasExt) desiredName.substring(dot + 1) else null
        return base to ext
    }
}
