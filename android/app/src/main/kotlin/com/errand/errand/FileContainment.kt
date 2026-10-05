package com.errand.errand

import android.content.Context
import android.os.Environment
import java.io.File

/**
 * Shared path-containment guard for every handler that turns an
 * agent-supplied string into file access (R2-C1).
 *
 * Used by `open_file`/`installApk` ([MainActivity]) and `openPdf`
 * ([PdfReaderPlugin]): an LLM-influenced path must never become a read of
 * app-private or system files. Canonicalization resolves `..` and symlinks
 * before the check, and comparison is by path segment so
 * "/data/data/com.app-evil" cannot pass against "/data/data/com.app".
 *
 * Roots: shared external storage (user workspace) plus the app's own
 * files/cache dirs (OTA downloads, scratch). The external variants are
 * nullable on newer SDKs; a null there is skipped, since guessing a
 * substitute would widen the allowed set.
 *
 * @return the canonical File, or null when the path escapes every root.
 */
internal fun Context.resolveContainedFile(rawPath: String): File? {
    val candidate = try {
        File(rawPath).canonicalFile
    } catch (_: Exception) {
        return null
    }
    val roots = mutableListOf<File>()
    @Suppress("DEPRECATION")
    Environment.getExternalStorageDirectory()?.let { roots.add(it) }
    roots.add(filesDir)
    roots.add(cacheDir)
    externalCacheDir?.let { roots.add(it) }
    getExternalFilesDir(null)?.let { roots.add(it) }
    for (root in roots) {
        val canonicalRoot = try {
            root.canonicalFile
        } catch (_: Exception) {
            continue
        }
        if (candidate.path == canonicalRoot.path) return candidate
        if (candidate.path.startsWith(canonicalRoot.path + File.separator)) {
            return candidate
        }
    }
    return null
}
