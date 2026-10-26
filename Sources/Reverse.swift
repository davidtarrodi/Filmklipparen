import AVFoundation
import CoreMedia

enum ReverseError: LocalizedError {
    case noVideo
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "Klippet har ingen bild."
        case .cancelled: return "Avbrutet."
        case .failed(let s): return s
        }
    }
}

/// Gör en baklänges-kopia av ett filmklipp (bild och ljud). Kopian sparas i appens mapp
/// och återanvänds nästa gång samma klipp vänds.
enum ReverseRenderer {
    private static let audioRate = 44100.0

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filmklipparen/Baklanges", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Samma fil (sökväg, storlek, ändringsdatum) ger alltid samma namn.
    static func cacheURL(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(source.path)|\(size)|\(Int(mtime))|v1".utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return folder.appendingPathComponent(String(format: "%016llx.mov", h))
    }

    static func isReady(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            && !AVURLAsset(url: url).tracks(withMediaType: .video).isEmpty
    }

    /// Körs på en bakgrundskö. Returnerar den färdiga baklänges-filen.
    static func render(_ source: URL, progress: (Double) -> Void,
                       isCancelled: () -> Bool = { false }) throws -> URL {
        let out = cacheURL(for: source)
        if isReady(out) { return out }
        let tmp = out.deletingPathExtension().appendingPathExtension("tmp.mov")
        try? FileManager.default.removeItem(at: tmp)

        let asset = AVURLAsset(url: source)
        guard let vt = asset.tracks(withMediaType: .video).first else { throw ReverseError.noVideo }
        let range = vt.timeRange
        let base = range.start.seconds
        let total = range.duration.seconds
        guard total > 0.05 else { throw ReverseError.noVideo }
        let fps = vt.nominalFrameRate > 1 ? Double(vt.nominalFrameRate) : 30
        let frameDur = 1 / fps

        // Ljudet läses in helt och vänds (16 bit, stereo, 44,1 kHz).
        let reversedAudio = try readReversedAudio(asset, frames: Int((total * audioRate).rounded()))

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let natural = vt.naturalSize
        let scale = min(1, 1920 / max(natural.width, natural.height, 1))
        let w = max(16, Int((natural.width * scale / 2).rounded()) * 2)
        let h = max(16, Int((natural.height * scale / 2).rounded()) * 2)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, Int(Double(w * h) * fps * 0.15)),
                AVVideoMaxKeyFrameIntervalKey: Int(fps),
            ],
        ])
        vin.expectsMediaDataInRealTime = false
        vin.transform = vt.preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(vin) else { throw ReverseError.failed("Kunde inte skriva bilden.") }
        writer.add(vin)

        var ain: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if reversedAudio != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) {
                writer.add(a)
                ain = a
                audioFormat = makeAudioFormat()
            }
        }

        guard writer.startWriting() else {
            throw ReverseError.failed(writer.error?.localizedDescription ?? "Kunde inte börja skriva.")
        }
        writer.startSession(atSourceTime: .zero)

        var audioDone = 0
        func flushAudio(upTo seconds: Double) throws {
            guard let a = ain, let fmt = audioFormat, let samples = reversedAudio else { return }
            let target = min(samples.count / 2, max(0, Int(seconds * audioRate)))
            while audioDone < target {
                let n = min(8192, target - audioDone)
                guard let sb = samples.withUnsafeBufferPointer({ buf -> CMSampleBuffer? in
                    makeAudioBuffer(buf.baseAddress! + audioDone * 2, frames: n, start: audioDone, format: fmt)
                }) else { throw ReverseError.failed("Kunde inte vända ljudet.") }
                try waitUntilReady(a, writer)
                if !a.append(sb) {
                    throw ReverseError.failed(writer.error?.localizedDescription ?? "Kunde inte skriva ljudet.")
                }
                audioDone += n
            }
        }

        // Bilden: läs en bit i taget bakifrån, skriv bilderna i omvänd ordning.
        let bigFrames = natural.width * natural.height > 2_500_000
        let segment = bigFrames ? 0.5 : 1.0
        var segEnd = total
        var lastOut = -1.0
        while segEnd > 0.0005 {
            if isCancelled() {
                writer.cancelWriting()
                throw ReverseError.cancelled
            }
            let segStart = max(0, segEnd - segment)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: cm(base + max(0, segStart - 0.1)), end: cm(base + segEnd))
            let o = AVAssetReaderTrackOutput(track: vt, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            o.alwaysCopiesSampleData = false
            guard reader.canAdd(o) else { throw ReverseError.failed("Kunde inte läsa klippet.") }
            reader.add(o)
            guard reader.startReading() else {
                throw ReverseError.failed(reader.error?.localizedDescription ?? "Kunde inte läsa klippet.")
            }
            var frames: [(buffer: CVPixelBuffer, time: Double)] = []
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let p = CMSampleBufferGetPresentationTimeStamp(sb).seconds - base
                if p >= segStart - 0.0005 && p < segEnd - 0.0005 {
                    frames.append((pb, p))
                }
            }
            if reader.status == .failed {
                throw ReverseError.failed(reader.error?.localizedDescription ?? "Kunde inte läsa klippet.")
            }
            frames.sort { $0.time < $1.time }
            for f in frames.reversed() {
                let t = max(0, total - f.time - frameDur)
                if t <= lastOut + 0.0001 { continue }
                try waitUntilReady(vin, writer)
                if !adaptor.append(f.buffer, withPresentationTime: cm(t)) {
                    throw ReverseError.failed(writer.error?.localizedDescription ?? "Kunde inte skriva bilden.")
                }
                lastOut = t
                try flushAudio(upTo: t + frameDur)
            }
            progress(min(1, (total - segStart) / total))
            segEnd = segStart
        }
        try flushAudio(upTo: total)

        vin.markAsFinished()
        ain?.markAsFinished()
        writer.endSession(atSourceTime: cm(total))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw ReverseError.failed(writer.error?.localizedDescription ?? "Kunde inte spara det vända klippet.")
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) throws {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw ReverseError.failed(writer.error?.localizedDescription ?? "Skrivningen misslyckades.")
            }
            Thread.sleep(forTimeInterval: 0.002)
            waited += 1
            if waited > 10_000 { throw ReverseError.failed("Skrivningen fastnade.") }
        }
    }

    /// Hela ljudet som 16-bitars stereo, vänt baklänges och exakt `frames` långt (tystnad om det saknas).
    private static func readReversedAudio(_ asset: AVAsset, frames: Int) throws -> [Int16]? {
        guard let at = asset.tracks(withMediaType: .audio).first, frames > 0 else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: at, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: audioRate,
            AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(o) else { return nil }
        reader.add(o)
        guard reader.startReading() else { return nil }
        var pcm = [Int16]()
        pcm.reserveCapacity(frames * 2 + 4096)
        while let sb = o.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            if len < 4 { continue }
            var chunk = [Int16](repeating: 0, count: len / 2)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: (len / 2) * 2, destination: raw.baseAddress!)
            }
            if status == noErr { pcm += chunk }
        }
        if reader.status == .failed { return nil }
        var rev = [Int16](repeating: 0, count: frames * 2)
        let have = pcm.count / 2
        for i in 0..<frames {
            let src = frames - 1 - i
            if src < have {
                rev[2 * i] = pcm[2 * src]
                rev[2 * i + 1] = pcm[2 * src + 1]
            }
        }
        return rev
    }

    private static func makeAudioFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: audioRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
        return fmt
    }

    private static func makeAudioBuffer(_ ptr: UnsafePointer<Int16>, frames: Int, start: Int,
                                        format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let b = block,
              CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: b, offsetIntoDestination: 0,
                                            dataLength: bytes) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: b, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audioRate)),
            packetDescriptions: nil, sampleBufferOut: &sb) == noErr
        else { return nil }
        return sb
    }
}
