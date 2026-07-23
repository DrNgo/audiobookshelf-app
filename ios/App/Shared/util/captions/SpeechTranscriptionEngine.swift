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
import AVFoundation
import Speech

@available(iOS 26.0, *)
actor SpeechTranscriptionEngine: SegmentProducing {

    enum EngineError: Error {
        case unsupportedLocale
        case unreadableAudio
    }

    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    static func isAvailable(locale: Locale) async -> Bool {
        // Verified: `supportedLocales` is `static var … [Locale] { get async }`.
        // Includes locales that are downloadable-but-not-yet-installed, which is
        // what we want — prepareModel() installs on demand. (`installedLocales`
        // exists too, for skipping the download prompt when already present.)
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
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

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Pump PCM out of the file region and into the analyzer.
        let feeder = Task {
            defer { inputContinuation.finish() }
            do {
                try await self.feed(fileURL: fileURL,
                                    request: request,
                                    analyzerFormat: analyzerFormat,
                                    into: inputContinuation)
            } catch {
                inputContinuation.finish()
            }
        }

        // Verified: autonomous-mode feed. (The file-based conveniences
        // `analyzeSequence(from: AVAudioFile)` and `init(inputAudioFile:…)`
        // exist but read to EOF and can't be bounded to our window, so we feed
        // a ranged AVAssetReader sequence instead.)
        try await analyzer.start(inputSequence: inputStream)

        // Finalized results only: filter on isFinal so provisional guesses (which
        // we didn't even request volatile reporting for) never reach the UI.
        for try await result in transcriber.results {
            if Task.isCancelled { break }
            guard result.isFinal else { continue }
            if let segment = Self.segment(from: result, bookOffset: request.bookOffset) {
                continuation.yield(segment)
            }
        }

        feeder.cancel()
        // Verified: SpeechAnalyzer.finalizeAndFinishThroughEndOfInput() async throws.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    /// Decode `request.duration` seconds starting at `request.offsetInTrack`,
    /// converting every buffer into the analyzer's exact format before feeding.
    ///
    /// Offset math, and why it's robust: we build a FRESH analyzer per request and
    /// feed it starting at `offsetInTrack`, and `AVAudioPCMBuffer`s carry no
    /// timestamps. So the analyzer counts time from zero at the first fed frame,
    /// making `.audioTimeRange` values relative to the START of this request's
    /// audio. Book time is therefore `request.bookOffset + reportedTime` — see
    /// `segment(from:bookOffset:)`. Because the sequence starts at zero we do NOT
    /// set `AnalyzerInput.bufferStartTime`. **Task 9 must confirm this assumption
    /// on device** — if the analyzer instead reports asset-timeline times, the
    /// shift becomes `track.startOffset + reportedTime` and this is the one line
    /// to change.
    private func feed(fileURL: URL,
                      request: TranscriptionRequest,
                      analyzerFormat: AVAudioFormat,
                      into continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {

        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EngineError.unreadableAudio
        }

        // AVAssetReader rather than AVAudioFile: AVAudioFile is unreliable on .m4b.
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: request.offsetInTrack, preferredTimescale: 600),
            duration: CMTime(seconds: request.duration, preferredTimescale: 600)
        )

        // Read as canonical deinterleaved float32 mono. This is the reader's
        // OUTPUT format; AVAudioConverter then bridges it to whatever the
        // analyzer wants (sample rate, interleaving, bit depth may all differ).
        let readerSampleRate = analyzerFormat.sampleRate
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: readerSampleRate,
            AVNumberOfChannelsKey: 1
        ]
        guard let readerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: readerSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw EngineError.unreadableAudio
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw EngineError.unreadableAudio }

        // Converter is identity when readerFormat == analyzerFormat; correct
        // otherwise. Never memcpy across mismatched layouts.
        let converter = AVAudioConverter(from: readerFormat, to: analyzerFormat)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { break }
            guard let readerBuffer = Self.pcmBuffer(from: sampleBuffer, format: readerFormat) else { continue }

            let outBuffer: AVAudioPCMBuffer
            if let converter, readerFormat != analyzerFormat {
                guard let converted = Self.convert(readerBuffer, using: converter, to: analyzerFormat) else { continue }
                outBuffer = converted
            } else {
                outBuffer = readerBuffer
            }
            // Row 8: fresh sequence from zero ⇒ no bufferStartTime.
            continuation.yield(AnalyzerInput(buffer: outBuffer))
        }

        if reader.status == .failed { throw reader.error ?? EngineError.unreadableAudio }
        reader.cancelReading()
    }

    /// Copy a decoded CMSampleBuffer into an AVAudioPCMBuffer of `format` using
    /// the audio buffer list — safe across channel/layout, unlike a raw memcpy.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
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
