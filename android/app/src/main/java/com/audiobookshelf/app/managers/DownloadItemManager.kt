package com.audiobookshelf.app.managers

import android.app.DownloadManager
import android.net.Uri
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import com.anggrayudi.storage.callback.FileCallback
import com.anggrayudi.storage.file.DocumentFileCompat
import com.anggrayudi.storage.file.MimeType
import com.anggrayudi.storage.file.getAbsolutePath
import com.anggrayudi.storage.file.moveFileTo
import com.anggrayudi.storage.media.FileDescription
import com.audiobookshelf.app.MainActivity
import com.audiobookshelf.app.device.DeviceManager
import com.audiobookshelf.app.device.FolderScanner
import com.audiobookshelf.app.models.DownloadItem
import com.audiobookshelf.app.models.DownloadItemPart
import com.fasterxml.jackson.core.json.JsonReadFeature
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.getcapacitor.JSObject
import java.io.File
import java.io.FileOutputStream
import java.util.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Manages download items and their parts. */
class DownloadItemManager(
        var downloadManager: DownloadManager,
        private var folderScanner: FolderScanner,
        var mainActivity: MainActivity,
        private var clientEventEmitter: DownloadEventEmitter
) {
  val tag = "DownloadItemManager"
  private val maxSimultaneousDownloads = 3
  private val maxRetries = 3
  private val stallTimeoutMs = 30_000L
  private val reservedId = -1L
  private var jacksonMapper =
          jacksonObjectMapper()
                  .enable(JsonReadFeature.ALLOW_UNESCAPED_CONTROL_CHARS.mappedFeature())

  enum class DownloadCheckStatus {
    InProgress,
    Successful,
    Failed
  }

  private var downloadItemQueue: MutableList<DownloadItem> =
          mutableListOf() // All pending and downloading items; access only under queueLock
  var currentDownloadItemParts: MutableList<DownloadItemPart> =
          mutableListOf() // Item parts currently being downloaded

  // Guards the mutable collections below against concurrent access from the watcher coroutine and
  // the (main-thread) enqueue path — they were previously plain lists mutated from two threads.
  private val queueLock = Any()
  private val retryCounts = mutableMapOf<String, Int>()
  private val internalDownloaders = mutableMapOf<String, InternalDownloadManager>()
  private val progressTracker = mutableMapOf<String, ProgressSnapshot>()
  private val lastEmittedProgress = mutableMapOf<String, Long>()

  private data class ProgressSnapshot(var bytes: Long, var at: Long)

  interface DownloadEventEmitter {
    fun onDownloadItem(downloadItem: DownloadItem)
    fun onDownloadItemPartUpdate(downloadItemPart: DownloadItemPart)
    fun onDownloadItemComplete(jsobj: JSObject)
  }

  interface InternalProgressCallback {
    fun onProgress(totalBytesWritten: Long, progress: Long)
    fun onComplete(failed: Boolean)
  }

  companion object {
    var isDownloading: Boolean = false
  }

  /** Adds a download item to the queue and starts processing the queue. */
  fun addDownloadItem(downloadItem: DownloadItem) {
    DeviceManager.dbManager.saveDownloadItem(downloadItem)
    Log.i(tag, "Add download item ${downloadItem.media.metadata.title}")

    synchronized(queueLock) { downloadItemQueue.add(downloadItem) }
    clientEventEmitter.onDownloadItem(downloadItem)
    checkUpdateDownloadQueue()
  }

  /** Thread-safe check for the duplicate-download guard (queue is mutated under queueLock elsewhere). */
  fun isItemInQueue(downloadItemId: String): Boolean =
          synchronized(queueLock) { downloadItemQueue.any { it.id == downloadItemId } }

  /**
   * Re-adopts download items persisted from a previous app launch. In-memory queue state does not
   * survive a process restart, so incomplete parts are reset and re-downloaded cleanly (previous
   * process downloadIds can't be trusted to still be valid). Called from the plugin's load().
   */
  fun reconcilePersistedDownloads() {
    GlobalScope.launch(Dispatchers.IO) {
      val persisted =
              try {
                DeviceManager.dbManager.getDownloadItems()
              } catch (e: Exception) {
                Log.e(tag, "Failed to load persisted download items", e)
                return@launch
              }
      if (persisted.isEmpty()) return@launch

      val readopted = mutableListOf<DownloadItem>()
      synchronized(queueLock) {
        for (item in persisted) {
          if (downloadItemQueue.any { it.id == item.id }) continue
          item.downloadItemParts.forEach { part ->
            if (!part.completed || part.failed) {
              part.completed = false
              part.failed = false
              part.isMoving = false
              part.downloadId = null
              part.progress = 0
              part.bytesDownloaded = 0
            }
          }
          if (item.downloadItemParts.any { !it.completed }) {
            downloadItemQueue.add(item)
            readopted.add(item)
          } else {
            DeviceManager.dbManager.removeDownloadItem(item.id)
          }
        }
      }

      if (readopted.isNotEmpty()) {
        Log.i(tag, "Reconciled ${readopted.size} persisted download item(s) after launch")
        launch(Dispatchers.Main) { readopted.forEach { clientEventEmitter.onDownloadItem(it) } }
        checkUpdateDownloadQueue()
      }
    }
  }

  /** Checks and updates the download queue, selecting parts to start up to the concurrency limit. */
  private fun checkUpdateDownloadQueue() {
    val toStart: List<DownloadItemPart> =
            synchronized(queueLock) {
              val selected = mutableListOf<DownloadItemPart>()
              for (downloadItem in downloadItemQueue) {
                val capacity = maxSimultaneousDownloads - (currentDownloadItemParts.size + selected.size)
                if (capacity <= 0) break
                val next = downloadItem.getNextDownloadItemParts(capacity)
                // Reserve so a concurrent call can't re-select the same part before it starts
                next.forEach { it.downloadId = reservedId }
                selected.addAll(next)
                if (currentDownloadItemParts.size + selected.size >= maxSimultaneousDownloads) break
              }
              selected
            }

    if (toStart.isNotEmpty()) processDownloadItemParts(toStart)
    if (synchronized(queueLock) { currentDownloadItemParts.isNotEmpty() }) startWatchingDownloads()
  }

  /** Processes the download item parts. */
  private fun processDownloadItemParts(nextDownloadItemParts: List<DownloadItemPart>) {
    nextDownloadItemParts.forEach {
      if (it.isInternalStorage) {
        startInternalDownload(it)
      } else {
        startExternalDownload(it)
      }
    }
  }

  /** Starts an internal download (streams straight to the final destination path). */
  private fun startInternalDownload(downloadItemPart: DownloadItemPart) {
    Log.d(
            tag,
            "Start internal download to destination path ${downloadItemPart.finalDestinationPath} from ${downloadItemPart.serverUrl}"
    )
    downloadItemPart.downloadId = 1

    val downloader: InternalDownloadManager
    try {
      val file = File(downloadItemPart.finalDestinationPath)
      file.parentFile?.mkdirs()
      val fileOutputStream = FileOutputStream(downloadItemPart.finalDestinationPath)
      val internalProgressCallback =
              object : InternalProgressCallback {
                override fun onProgress(totalBytesWritten: Long, progress: Long) {
                  downloadItemPart.bytesDownloaded = totalBytesWritten
                  downloadItemPart.progress = progress
                }

                override fun onComplete(failed: Boolean) {
                  downloadItemPart.failed = failed
                  downloadItemPart.completed = true
                }
              }
      downloader = InternalDownloadManager(fileOutputStream, internalProgressCallback)
      downloader.download(downloadItemPart.serverUrl)
    } catch (e: Exception) {
      // Opening the destination file (or starting the request) failed. Mark the part terminal and
      // still track it so the watcher resolves it via handleTerminalFailure, instead of leaving it
      // reserved and never re-selected (getNextDownloadItemParts only picks parts with a null id).
      Log.e(tag, "Failed to start internal download ${downloadItemPart.filename}", e)
      downloadItemPart.failed = true
      downloadItemPart.completed = true
      synchronized(queueLock) {
        currentDownloadItemParts.add(downloadItemPart)
        progressTracker[downloadItemPart.id] = ProgressSnapshot(0, System.currentTimeMillis())
      }
      return
    }

    synchronized(queueLock) {
      internalDownloaders[downloadItemPart.id] = downloader
      currentDownloadItemParts.add(downloadItemPart)
      progressTracker[downloadItemPart.id] = ProgressSnapshot(0, System.currentTimeMillis())
    }
  }

  /** Starts an external download via the system DownloadManager. */
  private fun startExternalDownload(downloadItemPart: DownloadItemPart) {
    try {
      val dlRequest = downloadItemPart.getDownloadRequest()
      val downloadId = downloadManager.enqueue(dlRequest)
      downloadItemPart.downloadId = downloadId
      Log.d(tag, "checkUpdateDownloadQueue: Starting download item part, downloadId=$downloadId")
    } catch (e: Exception) {
      // enqueue() can throw (bad request, DownloadManager unavailable). Mark the part terminal so
      // the watcher resolves it instead of leaving it reserved (downloadId == -1) and never re-picked.
      Log.e(tag, "Failed to enqueue external download ${downloadItemPart.filename}", e)
      downloadItemPart.failed = true
      downloadItemPart.completed = true
    }
    synchronized(queueLock) {
      currentDownloadItemParts.add(downloadItemPart)
      progressTracker[downloadItemPart.id] = ProgressSnapshot(0, System.currentTimeMillis())
    }
  }

  /** Starts watching the downloads. */
  private fun startWatchingDownloads() {
    // Atomically claim the watcher: `isDownloading` was set inside the coroutine, so two callers
    // could both pass the guard and launch two watcher coroutines racing the same queue.
    synchronized(queueLock) {
      if (isDownloading) return // Already watching
      isDownloading = true
    }

    GlobalScope.launch(Dispatchers.IO) {
      Log.d(tag, "Starting watching downloads")

      while (true) {
        // Check emptiness and release the watcher flag under the SAME lock, so a part enqueued just
        // as the loop drains can't be lost in the gap between the empty check and clearing the flag.
        val itemParts =
                synchronized(queueLock) {
                  if (currentDownloadItemParts.isEmpty()) {
                    isDownloading = false
                    null
                  } else {
                    currentDownloadItemParts.filter { !it.isMoving }
                  }
                }
                        ?: break

        for (downloadItemPart in itemParts) {
          if (downloadItemPart.isInternalStorage) {
            handleInternalDownloadPart(downloadItemPart)
          } else {
            handleExternalDownloadPart(downloadItemPart)
          }
        }

        delay(500)

        if (synchronized(queueLock) { currentDownloadItemParts.size } < maxSimultaneousDownloads) {
          checkUpdateDownloadQueue()
        }
      }

      Log.d(tag, "Finished watching downloads")
    }
  }

  /** Handles an internal download part. */
  private fun handleInternalDownloadPart(downloadItemPart: DownloadItemPart) {
    if (downloadItemPart.completed) {
      if (downloadItemPart.failed) {
        handleTerminalFailure(downloadItemPart)
        return
      }
      // Internal downloads write straight to the final destination — no move step needed
      emitPartUpdate(downloadItemPart)
      val downloadItem =
              synchronized(queueLock) { downloadItemQueue.find { it.id == downloadItemPart.downloadItemId } }
      cleanupActivePart(downloadItemPart)
      synchronized(queueLock) { retryCounts.remove(downloadItemPart.id) }
      downloadItem?.let { checkDownloadItemFinished(it) }
    } else {
      emitPartUpdate(downloadItemPart)
      checkStall(downloadItemPart)
    }
  }

  /** Handles an external download part. */
  private fun handleExternalDownloadPart(downloadItemPart: DownloadItemPart) {
    val downloadCheckStatus = checkDownloadItemPart(downloadItemPart)
    emitPartUpdate(downloadItemPart)

    val downloadItem =
            synchronized(queueLock) { downloadItemQueue.find { it.id == downloadItemPart.downloadItemId } }
    if (downloadItem == null) {
      Log.e(tag, "Download item part finished but download item not found ${downloadItemPart.filename}")
      cleanupActivePart(downloadItemPart)
      return
    }

    when (downloadCheckStatus) {
      DownloadCheckStatus.Successful -> moveDownloadedFile(downloadItem, downloadItemPart)
      DownloadCheckStatus.Failed -> handleTerminalFailure(downloadItemPart)
      DownloadCheckStatus.InProgress -> checkStall(downloadItemPart)
    }
  }

  /** Checks the status of a download item part. */
  private fun checkDownloadItemPart(downloadItemPart: DownloadItemPart): DownloadCheckStatus {
    val downloadId = downloadItemPart.downloadId ?: return DownloadCheckStatus.Failed

    val query = DownloadManager.Query().setFilterById(downloadId)
    downloadManager.query(query).use {
      if (it.moveToFirst()) {
        val bytesColumnIndex = it.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
        val statusColumnIndex = it.getColumnIndex(DownloadManager.COLUMN_STATUS)
        val bytesDownloadedColumnIndex =
                it.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)

        val totalBytes = if (bytesColumnIndex >= 0) it.getInt(bytesColumnIndex) else 0
        val downloadStatus = if (statusColumnIndex >= 0) it.getInt(statusColumnIndex) else 0
        val bytesDownloadedSoFar =
                if (bytesDownloadedColumnIndex >= 0) it.getLong(bytesDownloadedColumnIndex) else 0

        return when (downloadStatus) {
          DownloadManager.STATUS_SUCCESSFUL -> {
            Log.d(tag, "checkDownloads Download ${downloadItemPart.filename} Successful")
            downloadItemPart.completed = true
            downloadItemPart.progress = 1
            downloadItemPart.bytesDownloaded = bytesDownloadedSoFar

            DownloadCheckStatus.Successful
          }
          DownloadManager.STATUS_FAILED -> {
            Log.d(tag, "checkDownloads Download ${downloadItemPart.filename} Failed")
            DownloadCheckStatus.Failed
          }
          else -> {
            val percentProgress =
                    if (totalBytes > 0) ((bytesDownloadedSoFar * 100L) / totalBytes) else 0
            downloadItemPart.progress = percentProgress
            downloadItemPart.bytesDownloaded = bytesDownloadedSoFar

            DownloadCheckStatus.InProgress
          }
        }
      } else {
        Log.d(tag, "Download ${downloadItemPart.filename} not found in dlmanager")
        return DownloadCheckStatus.Failed
      }
    }
  }

  /**
   * Detects a stalled part (no forward progress for stallTimeoutMs) and cancels the in-flight
   * download. Cancellation routes through the normal failure path on the next poll, which retries.
   */
  private fun checkStall(downloadItemPart: DownloadItemPart) {
    val now = System.currentTimeMillis()
    val snap =
            synchronized(queueLock) {
              progressTracker.getOrPut(downloadItemPart.id) {
                ProgressSnapshot(downloadItemPart.bytesDownloaded, now)
              }
            }

    if (downloadItemPart.bytesDownloaded > snap.bytes) {
      snap.bytes = downloadItemPart.bytesDownloaded
      snap.at = now
      return
    }

    if (now - snap.at > stallTimeoutMs) {
      Log.e(
              tag,
              "Stall detected on ${downloadItemPart.filename}: no progress for >${stallTimeoutMs / 1000}s — cancelling to retry"
      )
      snap.at = now // avoid re-cancelling on every subsequent poll while it winds down
      if (downloadItemPart.isInternalStorage) {
        synchronized(queueLock) { internalDownloaders[downloadItemPart.id] }?.cancel()
      } else {
        downloadItemPart.downloadId?.let { if (it > 0) downloadManager.remove(it) }
      }
    }
  }

  /** Retries a failed/stalled part with a bounded retry count, or resolves it as permanently failed. */
  private fun handleTerminalFailure(downloadItemPart: DownloadItemPart) {
    val retries = synchronized(queueLock) { retryCounts.getOrDefault(downloadItemPart.id, 0) }

    if (retries < maxRetries) {
      synchronized(queueLock) { retryCounts[downloadItemPart.id] = retries + 1 }
      Log.w(tag, "Retrying ${downloadItemPart.filename} — attempt ${retries + 1}/$maxRetries")
      cleanupActivePart(downloadItemPart)
      // Reset so getNextDownloadItemParts re-selects it on the next queue tick
      downloadItemPart.completed = false
      downloadItemPart.failed = false
      downloadItemPart.isMoving = false
      downloadItemPart.downloadId = null
      downloadItemPart.progress = 0
      downloadItemPart.bytesDownloaded = 0
    } else {
      Log.e(tag, "Download failed permanently for ${downloadItemPart.filename} after $maxRetries retries")
      downloadItemPart.completed = true
      downloadItemPart.failed = true
      val downloadItem =
              synchronized(queueLock) { downloadItemQueue.find { it.id == downloadItemPart.downloadItemId } }
      emitPartUpdate(downloadItemPart) // surface the failure to the UI before we drop the part
      cleanupActivePart(downloadItemPart)
      synchronized(queueLock) { retryCounts.remove(downloadItemPart.id) }
      downloadItem?.let { checkDownloadItemFinished(it) }
    }
  }

  /** Removes a part from the active set and clears its per-part bookkeeping. */
  private fun cleanupActivePart(downloadItemPart: DownloadItemPart) {
    synchronized(queueLock) {
      currentDownloadItemParts.remove(downloadItemPart)
      internalDownloaders.remove(downloadItemPart.id)
      progressTracker.remove(downloadItemPart.id)
      lastEmittedProgress.remove(downloadItemPart.id)
    }
  }

  /** Emits a part update to the JS layer only when something actually changed (avoids bridge churn). */
  private fun emitPartUpdate(downloadItemPart: DownloadItemPart) {
    val shouldEmit =
            synchronized(queueLock) {
              val last = lastEmittedProgress[downloadItemPart.id]
              if (last == null || last != downloadItemPart.progress || downloadItemPart.completed) {
                lastEmittedProgress[downloadItemPart.id] = downloadItemPart.progress
                true
              } else {
                false
              }
            }
    if (shouldEmit) clientEventEmitter.onDownloadItemPartUpdate(downloadItemPart)
  }

  /** Moves the downloaded file to its final destination. */
  private fun moveDownloadedFile(downloadItem: DownloadItem, downloadItemPart: DownloadItemPart) {
    val file = DocumentFileCompat.fromUri(mainActivity, downloadItemPart.destinationUri)
    Log.d(tag, "DOWNLOAD: DESTINATION URI ${downloadItemPart.destinationUri}")

    val fcb =
            object : FileCallback() {
              override fun onPrepare() {
                Log.d(tag, "DOWNLOAD: PREPARING MOVE FILE")
              }

              override fun onFailed(errorCode: ErrorCode) {
                Log.e(tag, "DOWNLOAD: FAILED TO MOVE FILE $errorCode")
                downloadItemPart.failed = true
                downloadItemPart.isMoving = false
                file?.delete()
                cleanupActivePart(downloadItemPart)
                synchronized(queueLock) { retryCounts.remove(downloadItemPart.id) }
                checkDownloadItemFinished(downloadItem)
              }

              override fun onCompleted(result: Any) {
                Log.d(tag, "DOWNLOAD: FILE MOVE COMPLETED")
                val resultDocFile = result as DocumentFile
                Log.d(
                        tag,
                        "DOWNLOAD: COMPLETED FILE INFO (name=${resultDocFile.name}) ${resultDocFile.getAbsolutePath(mainActivity)}"
                )

                // Rename to fix appended .mp3 on m4b/m4a files
                //  REF: https://github.com/anggrayudi/SimpleStorage/issues/94
                val docNameLowerCase = resultDocFile.name?.lowercase(Locale.getDefault()) ?: ""
                if (docNameLowerCase.endsWith(".m4b.mp3") || docNameLowerCase.endsWith(".m4a.mp3")) {
                  resultDocFile.renameTo(downloadItemPart.filename)
                }

                downloadItemPart.moved = true
                downloadItemPart.isMoving = false
                cleanupActivePart(downloadItemPart)
                synchronized(queueLock) { retryCounts.remove(downloadItemPart.id) }
                checkDownloadItemFinished(downloadItem)
              }
            }

    val localFolderFile =
            DocumentFileCompat.fromUri(mainActivity, Uri.parse(downloadItemPart.localFolderUrl))
    if (localFolderFile == null) {
      // Failed
      downloadItemPart.failed = true
      Log.e(tag, "Local Folder File from uri is null")
      cleanupActivePart(downloadItemPart)
      synchronized(queueLock) { retryCounts.remove(downloadItemPart.id) }
      checkDownloadItemFinished(downloadItem)
    } else {
      downloadItemPart.isMoving = true
      val mimetype = if (downloadItemPart.audioTrack != null) MimeType.AUDIO else MimeType.IMAGE
      val fileDescription =
              FileDescription(
                      downloadItemPart.filename,
                      downloadItemPart.finalDestinationSubfolder,
                      mimetype
              )
      file?.moveFileTo(mainActivity, localFolderFile, fileDescription, fcb)
    }
  }

  /** Checks if a download item is finished and processes it. */
  private fun checkDownloadItemFinished(downloadItem: DownloadItem) {
    if (downloadItem.isDownloadFinished) {
      Log.i(tag, "Download Item finished ${downloadItem.media.metadata.title}")

      GlobalScope.launch(Dispatchers.IO) {
        folderScanner.scanDownloadItem(downloadItem) { downloadItemScanResult ->
          Log.d(
                  tag,
                  "Item download complete ${downloadItem.itemTitle} | local library item id: ${downloadItemScanResult?.localLibraryItem?.id}"
          )

          val jsobj =
                  JSObject().apply {
                    put("libraryItemId", downloadItem.id)
                    put("localFolderId", downloadItem.localFolder.id)

                    downloadItemScanResult?.localLibraryItem?.let { localLibraryItem ->
                      put(
                              "localLibraryItem",
                              JSObject(jacksonMapper.writeValueAsString(localLibraryItem))
                      )
                    }
                    downloadItemScanResult?.localMediaProgress?.let { localMediaProgress ->
                      put(
                              "localMediaProgress",
                              JSObject(jacksonMapper.writeValueAsString(localMediaProgress))
                      )
                    }
                  }

          launch(Dispatchers.Main) {
            clientEventEmitter.onDownloadItemComplete(jsobj)
            synchronized(queueLock) { downloadItemQueue.remove(downloadItem) }
            DeviceManager.dbManager.removeDownloadItem(downloadItem.id)
          }
        }
      }
    }
  }
}
