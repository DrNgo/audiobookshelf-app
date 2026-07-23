//
//  SpeechTranscriptionEngine.swift
//  Audiobookshelf
//
//  SegmentProducing backed by iOS 26's SpeechAnalyzer. This is the ONLY file
//  that touches the Speech framework's long-form API.
//
//  Reads one file region as a single continuous analysis rather than fixed
//  chunks: chunking would cut words at every seam, so seams exist only at real
//  track boundaries and seek points.
//

import Foundation
// @preconcurrency: AVFAudio's AVAudioPCMBuffer is non-Sendable, and we capture
// one in the @Sendable feed closure. The capture is safe (each buffer is used by
// exactly one task), so suppress the cross-module Sendable warning as Apple advises.
@preconcurrency import AVFoundation
import Speech
import OSLog

@available(iOS 26.0, *)
actor SpeechTranscriptionEngine: SegmentProducing {

    enum EngineError: Error {
        case unsupportedLocale
        case unreadableAudio
    }

    // Instruments: wraps each transcription window so energy/CPU bursts (and the
    // idle gaps between them) are visible in the os_signpost / Energy Log tracks.
    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "com.audiobookshelf.captions", category: .pointsOfInterest)
    )

    private let locale: Locale
    /// Optional biasing vocabulary (character/place names from book+series
    /// metadata). Empty ⇒ no bias, identical to the unbiased path.
    private let contextualStrings: [String]

    init(locale: Locale, contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    /// Resolve a device locale to the supported locale it's EQUIVALENT to, or nil
    /// if the language isn't supported at all. Verified against the iOS 26.5 SDK:
    /// `static func supportedLocale(equivalentTo locale: Locale) async -> Locale?`
    /// on SpeechTranscriber (via LocaleDependentSpeechModule). This tolerates
    /// regional variants (e.g. en-CA resolves to en-US) instead of demanding an
    /// exact BCP-47 match, and the returned locale is the one whose model gets
    /// installed — so callers thread THIS value through install + engine
    /// construction to keep the two in lockstep.
    static func supportedEquivalent(of locale: Locale) async -> Locale? {
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    static func isAvailable(locale: Locale) async -> Bool {
        return await supportedEquivalent(of: locale) != nil
    }

    /// True when the on-device model for `locale` is already installed, so callers
    /// can skip the "downloading language support" status when nothing will download.
    /// Verified against the iOS 26.5 SDK: `static var installedLocales: [Locale] { get async }`
    /// on SpeechTranscriber. Compared by BCP-47 identifier, matching `supportedEquivalent`.
    static func isModelInstalled(locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Downloads the on-device language model if it isn't installed yet.
    /// Requires network on first use for a given language.
    static func prepareModel(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    nonisolated func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request: request, fileURL: fileURL, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(request: TranscriptionRequest,
                     fileURL: URL,
                     continuation: AsyncThrowingStream<CaptionSegment, Error>.Continuation) async throws {

        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "CaptionTranscribeWindow", id: signpostID,
            "bookOffset=\(request.bookOffset, privacy: .public)s duration=\(request.duration, privacy: .public)s"
        )
        defer { Self.signposter.endInterval("CaptionTranscribeWindow", interval) }

        // Finalized results only — we run ahead of the playhead, so provisional
        // guesses would only cause visible rewriting for no benefit.
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Verified: bestAvailableAudioFormat is static on SpeechAnalyzer (NOT
        // on SpeechTranscriber) and returns AVAudioFormat?.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.unreadableAudio
        }

        // NOTE: this AsyncStream is unbounded (no backpressure); the analyzer
        // keeps pace with the reader in practice — device-verified in Task 9 — so
        // the input side does not grow without bound. Not addressed here.
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Consume results CONCURRENTLY with feeding + finalizing. `transcriber.results`
        // does not complete until the analyzer is finalized, and finalization is issued
        // below AFTER the input is finished — so draining `results` inline before that
        // call would deadlock. This mirrors Apple's WWDC SpeechAnalyzer pattern: spin the
        // results consumer up first, feed, finish input, then finalize (which ends the
        // results sequence and lets this child task return). Finalize ordering is
        // confirmed end-to-end on device in Task 9 (the sim has no en-US model).
        //
        // Finalized results only: filter on isFinal so provisional guesses (which we
        // didn't even request volatile reporting for) never reach the UI.
        let resultsTask = Task { () throws in
            for try await result in transcriber.results {
                if Task.isCancelled { break }
                guard result.isFinal else { continue }
                // `feed` seeks the file to `offsetInTrack` and feeds a zero-based
                // sequence, so `.audioTimeRange` is relative to that offset and book
                // time is `request.bookOffset + reportedTime`. See `segment(from:)`.
                if let segment = Self.segment(from: result, bookOffset: request.bookOffset) {
                    continuation.yield(segment)
                }
            }
        }

        // `resultsTask` is unstructured and so does NOT inherit cancellation from this
        // (the outer stream's) task. The outer AsyncThrowingStream cancels this work via
        // `onTermination` → the run task's cancellation, so bridge that to `resultsTask`
        // (and the analyzer) with an explicit cancellation handler — the same role the
        // old `feeder.cancel()` played. `feed` runs inline in this task, so its own
        // `Task.isCancelled` checks already respond to the outer cancellation.
        try await withTaskCancellationHandler {
            // Verified: `start(inputSequence:)` returns promptly once autonomous
            // background analysis begins (it is `async throws -> Void`, distinct from
            // `analyzeSequence` which returns `CMTime?` only after consuming the whole
            // sequence). So feeding AFTER this call is correct. (The file-based
            // conveniences `analyzeSequence(from: AVAudioFile)` and
            // `init(inputAudioFile:…)` exist but read to EOF and can't be bounded to our
            // window, so we feed a ranged `AVAudioFile` read sequence instead.)
            do {
                // Bias recognition toward the book's known names, if we have any.
                if !self.contextualStrings.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = self.contextualStrings
                    try await analyzer.setContext(context)
                }
                try await analyzer.start(inputSequence: inputStream)

                // Pump PCM out of the file region into the analyzer, inline so a feed
                // failure surfaces here (feed keeps its own internal cancellation checks).
                try await self.feed(fileURL: fileURL,
                                    request: request,
                                    analyzerFormat: analyzerFormat,
                                    into: inputContinuation)
            } catch {
                inputContinuation.finish()
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }

            // Input exhausted: end the sequence, then finalize. Finalizing completes
            // `transcriber.results`, which ends `resultsTask`.
            inputContinuation.finish()
            // Verified: SpeechAnalyzer.finalizeAndFinishThroughEndOfInput() async throws.
            // A throw here exits the withTaskCancellationHandler body normally (not via
            // task cancellation), so onCancel does NOT run — cancel/await the results
            // task ourselves or it leaks, still awaiting transcriber.results.
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            try await resultsTask.value
        } onCancel: {
            // Outer task cancelled: stop the input, tear down the results consumer, and
            // abandon analysis. `onCancel` runs synchronously, so the async analyzer
            // teardown is detached.
            inputContinuation.finish()
            resultsTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Decode `request.duration` seconds starting at `request.offsetInTrack`,
    /// converting every buffer into the analyzer's exact format before feeding.
    ///
    /// Uses `AVAudioFile` + `framePosition` rather than `AVAssetReader.timeRange`:
    /// on these multi-file FLAC books `AVAssetReader` IGNORES the requested time range
    /// and re-delivers the START of the file for every window (so every window
    /// transcribed the opening and stamped it wherever the playhead was). `AVAudioFile`
    /// seeks by sample position, which FLAC supports accurately.
    ///
    /// Offset math: we seek to `offsetInTrack` and feed a zero-based sequence (no
    /// `AnalyzerInput.bufferStartTime`), so `.audioTimeRange` values are relative to
    /// `offsetInTrack` and book time is `request.bookOffset + reportedTime` — see
    /// `run`'s results loop and `segment(from:bookOffset:)`.
    private func feed(fileURL: URL,
                      request: TranscriptionRequest,
                      analyzerFormat: AVAudioFormat,
                      into continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw EngineError.unreadableAudio
        }

        // `read(into:)` decodes into the file's processing format (float32 PCM at the
        // file's own sample rate / channel count); AVAudioConverter then bridges it to
        // whatever the analyzer wants (sample rate, channel count, interleaving).
        let fileFormat = file.processingFormat
        let sampleRate = fileFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { throw EngineError.unreadableAudio }

        let startFrame = Int64((request.offsetInTrack * sampleRate).rounded())
        let endFrame = min(Int64(((request.offsetInTrack + request.duration) * sampleRate).rounded()), file.length)
        guard startFrame >= 0, startFrame < endFrame, startFrame < file.length else { return }
        file.framePosition = startFrame

        // Converter only needed when the formats differ; when it is, it is REQUIRED
        // (feeding the raw buffer would hand the analyzer a wrong-format buffer).
        let formatsDiffer = fileFormat != analyzerFormat
        let converter = AVAudioConverter(from: fileFormat, to: analyzerFormat)
        if formatsDiffer && converter == nil {
            throw EngineError.unreadableAudio
        }

        let chunkFrames: AVAudioFrameCount = 16384
        var framesRemaining = endFrame - startFrame
        while framesRemaining > 0 {
            if Task.isCancelled { break }
            let toRead = AVAudioFrameCount(min(Int64(chunkFrames), framesRemaining))
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: toRead) else {
                throw EngineError.unreadableAudio
            }
            do {
                try file.read(into: readBuffer, frameCount: toRead)
            } catch {
                throw EngineError.unreadableAudio
            }
            guard readBuffer.frameLength > 0 else { break } // EOF
            framesRemaining -= Int64(readBuffer.frameLength)

            let outBuffer: AVAudioPCMBuffer
            if formatsDiffer, let converter {
                guard let converted = Self.convert(readBuffer, using: converter, to: analyzerFormat) else { continue }
                outBuffer = converted
            } else {
                outBuffer = readBuffer
            }
            // Fresh sequence from zero ⇒ no bufferStartTime.
            continuation.yield(AnalyzerInput(buffer: outBuffer))
        }

        // Flush the converter's internal primer/tail so the last word(s) of the window
        // aren't clipped. Only the converter path buffers anything; skip on cancellation.
        if !Task.isCancelled, formatsDiffer, let converter {
            for tail in Self.drainTail(of: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: tail))
            }
        }
    }

    /// Drain frames AVAudioConverter buffered internally, by driving it with an
    /// end-of-stream input block until it reports `.endOfStream` (or errors /
    /// stops producing). The converter emits buffered frames as `.haveData`
    /// across one or more calls and finally returns `.endOfStream`, so we loop —
    /// guaranteeing no tail is lost and that it terminates.
    private static func drainTail(of converter: AVAudioConverter,
                                  to outFormat: AVAudioFormat) -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if error != nil { break }
            if output.frameLength > 0 { buffers.append(output) }
            if status == .endOfStream || status == .error || output.frameLength == 0 { break }
        }
        return buffers
    }

    /// Run `input` through `converter` into a buffer of `outFormat`.
    private static func convert(_ input: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                to outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let statusValue = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, statusValue != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Convert one recognizer result into a book-time segment.
    /// `.audioTimeRange` gives request-relative times; `bookOffset` shifts them
    /// (see the offset-math note on `feed`).
    private static func segment(from result: SpeechTranscriber.Result, bookOffset: Double) -> CaptionSegment? {
        let attributed = result.text
        let plain = String(attributed.characters)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var words: [CaptionWord] = []
        for run in attributed.runs {
            // ROW 7 (resolved against iOS 26.5 SDK): `Result.text` was produced with
            // `attributeOptions: [.audioTimeRange]`. The Speech framework declares
            // `AttributeScopes.SpeechAttributes.audioTimeRange` (a TimeRangeAttribute
            // whose Value is CMTimeRange) and extends `AttributeDynamicLookup`, so the
            // attribute surfaces on each run as the dynamic member `run.audioTimeRange`,
            // typed `CMTimeRange?`. Runs without the attribute are skipped.
            guard let range = run.audioTimeRange else { continue }
            let text = String(attributed[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            words.append(CaptionWord(
                start: bookOffset + range.start.seconds,
                end: bookOffset + range.end.seconds,
                text: text
            ))
        }

        guard let first = words.first, let last = words.last else { return nil }
        return CaptionSegment(start: first.start, end: last.end, text: plain, words: words)
    }
}
