import AVFoundation

/// Mörka och pipiga röster: ljudet i ett filmklipp görs om med ändrad tonhöjd.
/// Den nya ljudfilen sparas i appens mapp och återanvänds nästa gång.
enum Voice {
    /// Valen i appen. Cent: 100 = ett halvtonsteg, 1200 = en oktav.
    static let presets: [(name: String, cents: Int)] = [
        ("Monster", -800), ("Mörk", -400), ("Vanlig", 0), ("Pipig", 400), ("Ekorre", 800),
    ]

    static func name(_ cents: Int) -> String {
        presets.first { $0.cents == cents }?.name ?? (cents < 0 ? "Mörk" : "Pipig")
    }

    private static let rate = 44100.0

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filmklipparen/Roster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ljudet som rösten görs av: klippets eget ljud, eller baklänges-ljudet när klippet är vänt.
    static func sourceAudioURL(for clip: Clip) -> URL? {
        if clip.isReversed {
            let au = ReverseRenderer.audioURL(forReversed: clip.mediaURL)
            return FileManager.default.fileExists(atPath: au.path) ? au : nil
        }
        return clip.url
    }

    /// Den färdiga röstfilen om den finns och hör till klippets nuvarande ljud.
    static func activeFile(for clip: Clip) -> URL? {
        guard let c = clip.pitch, c != 0, let vp = clip.voicePath, let src = sourceAudioURL(for: clip),
              clip.voiceSource == src.path, FileManager.default.fileExists(atPath: vp)
        else { return nil }
        return URL(fileURLWithPath: vp)
    }

    static func cacheURL(source: URL, cents: Int) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(source.path)|\(size)|\(Int(mtime))|\(cents)|v1".utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return folder.appendingPathComponent(String(format: "%016llx.m4a", h))
    }

    /// Körs på en bakgrundskö. Returnerar ljudfilen med ändrad tonhöjd, lika lång som originalet.
    static func render(source: URL, cents: Int, progress: (Double) -> Void = { _ in }) throws -> URL {
        let out = cacheURL(source: source, cents: cents)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = out.deletingPathExtension().appendingPathExtension("tmp.m4a")
        try? FileManager.default.removeItem(at: tmp)

        // 1. Läs hela ljudet (stereo, 44,1 kHz).
        let pcm = try readPCM(AVURLAsset(url: source))
        let frames = pcm.count / 2
        guard frames > 0 else { throw ReverseError.failed("Klippet har inget ljud.") }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let input = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let ch = input.floatChannelData
        else { throw ReverseError.failed("Kunde inte läsa ljudet.") }
        input.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            ch[0][i] = Float(pcm[2 * i]) / 32768
            ch[1][i] = Float(pcm[2 * i + 1]) / 32768
        }

        // 2. Spela det genom en tonhöjdsändrare, snabbare än realtid, rakt till en fil.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = Float(cents)
        pitch.rate = 1
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: fmt)
        engine.connect(pitch, to: engine.mainMixerNode, format: fmt)
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                         frameCapacity: engine.manualRenderingMaximumFrameCount),
              let part = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                          frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw ReverseError.failed("Kunde inte göra om ljudet.") }

        // Tonhöjdsändraren är lite sen; hoppa över fördröjningen så att ljud och bild håller ihop.
        var skip = max(0, Int((pitch.latency + player.latency) * rate))
        let total = frames + skip
        do {
            var file: AVAudioFile? = try AVAudioFile(forWriting: tmp, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            var rendered = 0
            var tries = 0
            while rendered < total {
                let n = min(Int(buf.frameCapacity), total - rendered)
                let status = try engine.renderOffline(AVAudioFrameCount(n), to: buf)
                switch status {
                case .success:
                    let got = Int(buf.frameLength)
                    if skip >= got {
                        skip -= got
                    } else if skip > 0 {
                        let keep = got - skip
                        if let s = buf.floatChannelData, let d = part.floatChannelData {
                            for c in 0..<2 { memcpy(d[c], s[c] + skip, keep * MemoryLayout<Float>.size) }
                        }
                        part.frameLength = AVAudioFrameCount(keep)
                        try file?.write(from: part)
                        skip = 0
                    } else {
                        try file?.write(from: buf)
                    }
                    rendered += got
                    progress(min(1, Double(rendered) / Double(total)))
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    tries += 1
                    if tries > 1000 { throw ReverseError.failed("Ljudet fastnade.") }
                case .error:
                    throw ReverseError.failed("Kunde inte göra om ljudet.")
                @unknown default:
                    throw ReverseError.failed("Kunde inte göra om ljudet.")
                }
            }
            file = nil // stänger filen
            _ = file
        }
        player.stop()
        engine.stop()
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// Hela ljudet som 16-bitars stereo, 44,1 kHz.
    static func readPCM(_ asset: AVAsset) throws -> [Int16] {
        guard let at = asset.tracks(withMediaType: .audio).first else {
            throw ReverseError.failed("Klippet har inget ljud.")
        }
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: at, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(o) else { throw ReverseError.failed("Kunde inte läsa ljudet.") }
        reader.add(o)
        guard reader.startReading() else { throw ReverseError.failed("Kunde inte läsa ljudet.") }
        var pcm = [Int16]()
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
        if reader.status == .failed { throw ReverseError.failed("Kunde inte läsa ljudet.") }
        return pcm
    }
}
