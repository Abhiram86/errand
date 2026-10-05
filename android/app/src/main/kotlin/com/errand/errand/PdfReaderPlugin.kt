package com.errand.errand

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class PdfReaderPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "pdf_reader"

        /** Mirrors the Dart-side 64MB cap; PDDocument.load maps the whole file. */
        const val MAX_DOCUMENT_BYTES = 64L * 1024 * 1024

        /** Upper bound on simultaneously open PDDocuments before eviction. */
        const val MAX_OPEN_DOCUMENTS = 8

        private var isInitialized = false

        fun registerWith(messenger: BinaryMessenger, context: Context): Pair<MethodChannel, PdfReaderPlugin> {
            val channel = MethodChannel(messenger, CHANNEL)
            val plugin = PdfReaderPlugin(context)
            channel.setMethodCallHandler(plugin)
            return Pair(channel, plugin)
        }
    }

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val openDocuments = ConcurrentHashMap<String, PDDocument>()

    /**
     * Closes open documents when the open set exceeds [MAX_OPEN_DOCUMENTS].
     * Every `PDDocument` holds a memory-mapped file handle and a full
     * in-memory parse (up to [MAX_DOCUMENT_BYTES]), so an unbounded set is
     * an OOM. Eviction order is arbitrary (`ConcurrentHashMap` iteration),
     * not recency — the bound is the guarantee, not the order.
     */
    private fun evictIfOverCapacity() {
        while (openDocuments.size >= MAX_OPEN_DOCUMENTS) {
            val oldest = openDocuments.keys.firstOrNull() ?: return
            val evicted = openDocuments.remove(oldest) ?: return
            try {
                evicted.close()
            } catch (_: Exception) {}
        }
    }

    private fun ensureInitialized() {
        if (!isInitialized) {
            PDFBoxResourceLoader.init(context)
            isInitialized = true
        }
    }

    private fun replySuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post {
            try {
                result.success(value)
            } catch (_: Exception) {}
        }
    }

    private fun replyError(
        result: MethodChannel.Result,
        errorCode: String,
        errorMessage: String?,
        errorDetails: Any? = null
    ) {
        mainHandler.post {
            try {
                result.error(errorCode, errorMessage, errorDetails)
            } catch (_: Exception) {}
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openPdf" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGUMENT", "Path is required", null)
                    return
                }
                executor.execute {
                    try {
                        ensureInitialized()
                        // Same containment as open_file/installApk (R2-C1):
                        // the path is LLM-influenced and must not become an
                        // arbitrary read + exfiltration primitive.
                        val file = context.resolveContainedFile(path)
                        if (file == null) {
                            replyError(result, "PATH_NOT_ALLOWED", "Path is outside the allowed storage roots: $path")
                            return@execute
                        }
                        if (!file.exists()) {
                            replyError(result, "FILE_NOT_FOUND", "File does not exist: $path")
                            return@execute
                        }
                        // Server-side size guard. The 64MB cap only existed in
                        // Dart; PDDocument.load maps the whole file, so an
                        // oversized or hostile document must be refused here too.
                        if (!file.canRead() || file.length() > MAX_DOCUMENT_BYTES) {
                            replyError(
                                result,
                                "TOO_LARGE",
                                "PDF exceeds the ${MAX_DOCUMENT_BYTES / (1024 * 1024)}MB limit: ${file.length()} bytes"
                            )
                            return@execute
                        }
                        val doc = PDDocument.load(file)
                        val docId = UUID.randomUUID().toString()
                        val pageCount = doc.numberOfPages
                        // Bound the open set. A Dart Finalizer cannot rescue a
                        // leaked PDDocument (it has no BinaryMessenger on the
                        // finalizer thread), so eviction is the only backstop.
                        evictIfOverCapacity()
                        openDocuments[docId] = doc
                        replySuccess(
                            result,
                            mapOf(
                                "docId" to docId,
                                "pageCount" to pageCount
                            )
                        )
                    } catch (e: Exception) {
                        replyError(result, "PARSE_ERROR", "Failed to parse PDF: ${e.message}")
                    }
                }
            }

            "extractPage" -> {
                val docId = call.argument<String>("docId")
                val pageIndex = call.argument<Int>("pageIndex")
                if (docId == null || pageIndex == null) {
                    result.error("INVALID_ARGUMENT", "docId and pageIndex are required", null)
                    return
                }
                executor.execute {
                    try {
                        val doc = openDocuments[docId]
                        if (doc == null) {
                            replyError(result, "DOC_NOT_FOUND", "No open document with id: $docId")
                            return@execute
                        }
                        if (pageIndex < 0 || pageIndex >= doc.numberOfPages) {
                            replyError(
                                result,
                                "INDEX_OUT_OF_BOUNDS",
                                "Page index $pageIndex is out of bounds (total: ${doc.numberOfPages})"
                            )
                            return@execute
                        }
                        val stripper = PDFTextStripper()
                        // PDFTextStripper uses 1-based page indexing
                        stripper.startPage = pageIndex + 1
                        stripper.endPage = pageIndex + 1
                        val text = stripper.getText(doc).trim()
                        replySuccess(result, text)
                    } catch (e: Exception) {
                        replyError(result, "EXTRACT_ERROR", "Failed to extract page text: ${e.message}")
                    }
                }
            }

            "closePdf" -> {
                val docId = call.argument<String>("docId")
                if (docId == null) {
                    result.error("INVALID_ARGUMENT", "docId is required", null)
                    return
                }
                executor.execute {
                    try {
                        val doc = openDocuments.remove(docId)
                        doc?.close()
                        replySuccess(result, true)
                    } catch (e: Exception) {
                        replyError(result, "CLOSE_ERROR", "Failed to close PDF: ${e.message}")
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    fun closeAll() {
        for ((_, doc) in openDocuments) {
            try {
                doc.close()
            } catch (_: Exception) {}
        }
        openDocuments.clear()
        try {
            executor.shutdownNow()
        } catch (_: Exception) {}
    }
}
