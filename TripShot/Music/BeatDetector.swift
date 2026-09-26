// 박자 검출(R3-S5): 음원을 모노 22050Hz로 읽어 온셋 강도 → 자기상관 템포(bpm) → 비트 시각을 찾는다. 계산부는 순수 함수(테스트 대상).
import AVFoundation
import Foundation

enum BeatDetector {
    /// 분석 샘플레이트.
    static let sampleRate: Double = 22050
    /// 프레임·홉 크기(샘플).
    static let frameSize = 1024
    static let hopSize = 512
    /// 템포 탐색 범위(bpm).
    static let minBPM: Double = 60
    static let maxBPM: Double = 180
    /// 긴 곡은 앞부분만 분석한다(초).
    static let maxAnalysisSeconds: Double = 90

    struct Result: Equatable {
        var bpm: Double?
        var beats: [Double]
    }

    // MARK: - 파일 분석 (백그라운드에서 부른다)

    /// 음원 파일 → (bpm, 비트 시각). 무거우므로 `Task.detached(priority: .utility)` 안에서 부른다.
    static func analyze(url: URL, maxSeconds: Double = maxAnalysisSeconds) async throws -> Result {
        let samples = try await loadSamples(url: url, maxSeconds: maxSeconds)
        return analyze(samples: samples, sampleRate: sampleRate)
    }

    /// PCM 샘플 → (bpm, 비트 시각). 순수 계산.
    static func analyze(samples: [Float], sampleRate: Double) -> Result {
        let (envelope, hop) = onsetEnvelope(samples: samples, sampleRate: sampleRate)
        guard let bpm = estimateTempo(envelope: envelope, hopSeconds: hop) else { return Result(bpm: nil, beats: []) }
        return Result(bpm: bpm, beats: beatTimes(envelope: envelope, hopSeconds: hop, bpm: bpm))
    }

    /// `AVAssetReader`로 오디오를 모노 float32 PCM(22050Hz)으로 읽는다. 앞 `maxSeconds`초만.
    static func loadSamples(url: URL, maxSeconds: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MusicImportError.unreadableFile }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicImportError.unreadableFile }
        reader.add(output)
        guard reader.startReading() else { throw MusicImportError.unreadableFile }

        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * min(maxSeconds, 600)))
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw reader.error ?? MusicImportError.unreadableFile }
        return samples
    }

    // MARK: - 순수 계산

    /// 온셋 강도: 1024 샘플 프레임·512 홉, 프레임 RMS 로그 에너지의 차분(양수만), 최대값 1로 정규화.
    /// 프레임 i는 i·홉 시각을 가운데로 두므로 envelope[i]의 시각은 i × hopSeconds.
    static func onsetEnvelope(samples: [Float], sampleRate: Double) -> (envelope: [Float], hopSeconds: Double) {
        let hopSeconds = Double(hopSize) / sampleRate
        guard !samples.isEmpty else { return ([], hopSeconds) }
        let half = frameSize / 2
        let count = samples.count / hopSize + 1
        var logEnergy = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { s in
            for i in 0..<count {
                let center = i * hopSize
                let a = max(center - half, 0)
                let b = min(center + half, s.count)
                var acc: Float = 0
                if a < b { for j in a..<b { acc += s[j] * s[j] } }
                let rms = (acc / Float(frameSize)).squareRoot()
                logEnergy[i] = log(rms + 1e-4)
            }
        }
        var envelope = [Float](repeating: 0, count: count)
        var peak: Float = 0
        for i in 1..<max(count, 1) {
            let d = max(logEnergy[i] - logEnergy[i - 1], 0)
            envelope[i] = d
            peak = max(peak, d)
        }
        if peak > 0 { for i in 0..<count { envelope[i] /= peak } }
        return (envelope, hopSeconds)
    }

    /// 템포: 온셋 강도(살짝 흐림)의 자기상관에서 60~180bpm 시차의 봉우리 중 최대(120bpm 근처를 약하게 선호) →
    /// 포물선 보간 → 4배·2배 시차 봉우리로 소수 시차를 다듬는다. 박자를 못 찾으면 nil.
    static func estimateTempo(envelope: [Float], hopSeconds: Double) -> Double? {
        let n = envelope.count
        guard n > 0, hopSeconds > 0 else { return nil }
        let minLag = max(1, Int((60 / maxBPM / hopSeconds).rounded(.down)))
        let maxLag = Int((60 / minBPM / hopSeconds).rounded(.up))
        guard minLag <= maxLag, maxLag + 2 < n else { return nil }
        let smooth = smoothed(envelope)
        let top = min(n - 2, 4 * maxLag + 2)
        let ac = autocorrelation(smooth, maxLag: top)
        guard ac[0] > 0 else { return nil }

        var best: Int?
        var bestScore = -Double.infinity
        for lag in max(minLag, 1)...maxLag where ac[lag] > ac[lag - 1] && ac[lag] >= ac[lag + 1] && ac[lag] > 0 {
            let bpm = 60 / (Double(lag) * hopSeconds)
            let prior = exp(-0.5 * pow(log2(bpm / 120), 2))
            let score = ac[lag] * prior
            if score > bestScore { bestScore = score; best = lag }
        }
        guard let lag = best else { return nil }
        var period = parabolicPeak(ac, at: lag)
        // 배수 시차 봉우리로 다듬기(정수 시차 양자화 오차를 1/m로 줄인다).
        for m in [4, 2] {
            let center = Int((Double(m) * period).rounded())
            guard center + m + 1 <= top else { continue }
            let lo = max(center - m, 1)
            let hi = min(center + m, top - 1)
            guard lo <= hi else { continue }
            var p = lo
            for l in lo...hi where ac[l] > ac[p] { p = l }
            period = parabolicPeak(ac, at: p) / Double(m)
            break
        }
        guard period > 0 else { return nil }
        return 60 / (period * hopSeconds)
    }

    /// 비트 시각: bpm 간격 격자의 위상을 온셋 강도와의 합이 최대가 되게 고르고,
    /// 첫 비트부터 "앞 비트 + 간격" 예측 위치를 ±간격/8 안의 온셋 봉우리로 스냅하며 따라간다(드리프트 보정).
    static func beatTimes(envelope: [Float], hopSeconds: Double, bpm: Double) -> [Double] {
        let n = envelope.count
        guard n > 0, bpm > 0, hopSeconds > 0 else { return [] }
        let period = 60 / bpm / hopSeconds
        guard period >= 1 else { return [] }
        func value(_ i: Int) -> Float { i >= 0 && i < n ? envelope[i] : 0 }

        var bestPhase = 0
        var bestScore: Float = -1
        for phase in 0..<Int(period.rounded(.up)) {
            var score: Float = 0
            var t = Double(phase)
            while t < Double(n) {
                let i = Int(t.rounded())
                score += max(value(i - 1), value(i), value(i + 1))
                t += period
            }
            if score > bestScore { bestScore = score; bestPhase = phase }
        }

        let window = max(1, Int(period / 8))
        let threshold = 0.1 * (envelope.max() ?? 0)
        var beats: [Double] = []
        var t = Double(bestPhase)
        while t < Double(n) {
            let c = Int(t.rounded())
            let lo = max(c - window, 0)
            let hi = min(c + window, n - 1)
            var snapped = t
            if lo <= hi {
                var p = lo
                for i in lo...hi where envelope[i] > envelope[p] { p = i }
                if envelope[p] >= threshold, envelope[p] > 0 { snapped = Double(p) }
            }
            beats.append(snapped * hopSeconds)
            t = snapped + period
        }
        return beats
    }

    /// 분석 구간(앞 90초) 뒤로 bpm 간격 비트를 이어 붙인다(곡 끝 `until`까지).
    static func extendBeats(_ beats: [Double], bpm: Double?, until end: Double) -> [Double] {
        guard let bpm, bpm > 0, var last = beats.last else { return beats }
        let step = 60 / bpm
        var out = beats
        while last + step <= end {
            last += step
            out.append(last)
        }
        return out
    }

    // MARK: 도우미

    /// 5탭 가우시안으로 살짝 흐린다(정수 시차 사이 봉우리가 보간되게).
    static func smoothed(_ x: [Float]) -> [Double] {
        let kernel: [Double] = [0.06, 0.24, 0.4, 0.24, 0.06]
        let n = x.count
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for (j, w) in kernel.enumerated() {
                let idx = i + j - 2
                if idx >= 0 && idx < n { acc += w * Double(x[idx]) }
            }
            out[i] = acc
        }
        return out
    }

    /// 평균을 뺀 자기상관(시차 0...maxLag).
    static func autocorrelation(_ x: [Double], maxLag: Int) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        let mean = x.reduce(0, +) / Double(n)
        let y = x.map { $0 - mean }
        var ac = [Double](repeating: 0, count: maxLag + 1)
        y.withUnsafeBufferPointer { p in
            for lag in 0...min(maxLag, n - 1) {
                var acc = 0.0
                for i in 0..<(n - lag) { acc += p[i] * p[i + lag] }
                ac[lag] = acc
            }
        }
        return ac
    }

    /// 봉우리 위치를 이웃 세 점 포물선으로 보간(±0.5 안).
    static func parabolicPeak(_ values: [Double], at i: Int) -> Double {
        guard i > 0, i + 1 < values.count else { return Double(i) }
        let a = values[i - 1], b = values[i], c = values[i + 1]
        let d = a - 2 * b + c
        guard d < 0 else { return Double(i) }
        let offset = 0.5 * (a - c) / d
        return Double(i) + min(max(offset, -0.5), 0.5)
    }
}
