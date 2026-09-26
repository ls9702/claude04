// 쇼츠 칸 즉석 촬영(R3-S3): 영상 녹화(촬영 탭과 같은 보정 파이프라인)에 템플릿 가이드를 겹친다.
// 흐름: 가이드 보고 자리 잡기 → 녹화 버튼 → 3초 카운트다운 → 칸 길이 + 여유만큼 녹화 후 자동 정지 → 사진 앱 저장 → 칸에 넣고 닫기.
import AVFoundation
import Photos
import SwiftData
import SwiftUI

struct SlotCaptureView: View {
    let template: ShortsTemplate
    let slot: SlotSpec
    /// 앞 칸 영상(겹쳐 보기용). 없으면 nil.
    let previousAssetID: String?
    let onSaved: (String) -> Void

    @StateObject private var vm = CaptureViewModel()
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @State private var phase: Phase = .idle
    @State private var ghost: UIImage?
    @State private var showGhost = true
    @State private var countdownTask: Task<Void, Never>?

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case saving
    }

    /// 녹화 길이: 칸 길이 + 앞 여유(버튼 흔들림) + 뒤 여유.
    static func recordSeconds(for slot: SlotSpec) -> Double { slot.seconds + SlotCaptureTiming.leadIn + SlotCaptureTiming.tail }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalPreviewView(coordinator: vm.preview) { devicePoint, _ in _ = vm.focus(at: devicePoint) }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay {
                    if let ghost, showGhost, slot.guide.ghostPrevious, phase != .recording || vm.recordingSeconds < 1.0 {
                        Image(uiImage: ghost).resizable().scaledToFill().opacity(0.35).allowsHitTesting(false)
                    }
                }
                .overlay {
                    SlotGuideOverlay(guide: slot.guide, stage: guideStage)
                        .allowsHitTesting(false)
                }
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if case .countdown(let n) = phase {
                    Text("\(n)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                }
                Spacer()
                bottomBar
            }
        }
        .task {
            vm.configure(services: services)
            vm.syncPresets(presets)
            guard await Permissions.requestCamera() else { return }
            vm.startCamera()
            vm.setVideoMode(true)
            vm.onVideoSaved = { id, _ in
                onSaved(id)
                dismiss()
            }
            ghost = await Self.lastFrame(of: previousAssetID)
        }
        .onDisappear {
            countdownTask?.cancel()
            vm.pause()
        }
        .onChange(of: vm.recordingSeconds) { _, t in
            // 칸 길이만큼 찍히면 자동 정지.
            if phase == .recording, t >= Self.recordSeconds(for: slot) { stop() }
        }
    }

    // MARK: 가이드 단계

    private var guideStage: SlotGuideOverlay.Stage {
        switch phase {
        case .idle, .countdown: return .start
        case .saving: return .end
        case .recording:
            let remaining = Self.recordSeconds(for: slot) - vm.recordingSeconds
            if vm.recordingSeconds < SlotCaptureTiming.leadIn + 1.0 { return .start }
            return remaining <= SlotCaptureTiming.tail + 1.0 ? .end : .middle
        }
    }

    // MARK: 위·아래

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.35)))
                }
                .disabled(phase == .recording || phase == .saving)
                Spacer()
                if slot.guide.ghostPrevious, ghost != nil {
                    Button { showGhost.toggle() } label: {
                        Label("앞 장면", systemImage: showGhost ? "eye.fill" : "eye.slash")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.35)))
                    }
                }
                Button { vm.toggleCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.35)))
                }
                .disabled(phase != .idle)
            }
            Text("\(template.name) · \(slot.index + 1)/\(template.slots.count) \(slot.title)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text(slot.instruction)
                .font(.footnote).foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if phase == .recording {
                let remaining = max(Self.recordSeconds(for: slot) - vm.recordingSeconds, 0)
                Text(String(format: "남은 시간 %.1f초", remaining))
                    .font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.red.opacity(0.8)))
            } else if phase == .saving {
                ProgressView("저장 중…").tint(.white).foregroundStyle(.white)
            } else {
                Text(String(format: "%.1f초 칸 · 버튼을 누르면 3초 뒤 녹화", slot.seconds))
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            ShutterButton(isVideo: true, isRecording: phase == .recording || phase != .idle) {
                switch phase {
                case .idle: startCountdown()
                case .countdown: cancelCountdown()
                case .recording: stop()
                case .saving: break
                }
            }
            .disabled(phase == .saving)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    // MARK: 동작

    private func startCountdown() {
        countdownTask = Task {
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { phase = .idle; return }
            }
            phase = .recording
            vm.startRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        phase = .idle
    }

    private func stop() {
        guard phase == .recording else { return }
        phase = .saving
        Task {
            if await vm.stopRecording() == nil { phase = .idle }   // 실패하면 다시 찍을 수 있게
        }
    }

    /// 앞 칸 영상의 마지막 장면(겹쳐 보기).
    static func lastFrame(of assetID: String?) async -> UIImage? {
        guard let assetID, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in cont.resume(returning: av) }
        }
        guard let avAsset else { return nil }
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        let duration = (try? await avAsset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: max(duration - 0.15, 0), preferredTimescale: 600)
        guard let (cg, _) = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 칸 촬영 시간 여유(초). 조립할 때 앞 `leadIn`을 건너뛴다(버튼 누를 때 흔들림).
enum SlotCaptureTiming {
    static let leadIn: Double = 0.3
    static let tail: Double = 0.7
}

// MARK: - 가이드 그리기

/// 템플릿 칸 가이드(실루엣·화살표·원·수평선·지시 문구). 화면 비율 좌표(0~1, 원점 좌상단).
struct SlotGuideOverlay: View {
    enum Stage { case start, middle, end }
    let guide: SlotGuide
    let stage: Stage

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let y = guide.horizonY {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height * y))
                        p.addLine(to: CGPoint(x: size.width, y: size.height * y))
                    }
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                }
                if guide.centerCircle {
                    Circle()
                        .stroke(.yellow.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                        .frame(width: size.width * 0.36, height: size.width * 0.36)
                        .position(x: size.width / 2, y: size.height / 2)
                }
                if let kind = guide.silhouette {
                    let rect = SlotGuideGeometry.silhouetteRect(guide: guide, in: size)
                    SilhouetteShape(kind: kind)
                        .fill(.white.opacity(0.12))
                        .overlay(SilhouetteShape(kind: kind).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    // 발 기준선
                    Path { p in
                        p.move(to: CGPoint(x: rect.minX - 20, y: rect.maxY))
                        p.addLine(to: CGPoint(x: rect.maxX + 20, y: rect.maxY))
                    }
                    .stroke(.yellow.opacity(0.8), lineWidth: 2)
                }
                if let arrow = currentArrow {
                    ArrowBadge(arrow: arrow)
                        .position(SlotGuideGeometry.arrowPosition(arrow, in: size))
                }
                if let cue = currentCue {
                    Text(cue)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.yellow))
                        .position(x: size.width / 2, y: size.height * 0.3)
                }
            }
        }
    }

    private var currentArrow: SlotGuide.Arrow? {
        switch stage {
        case .start: return guide.startArrow
        case .middle: return nil
        case .end: return guide.endArrow
        }
    }

    private var currentCue: String? {
        switch stage {
        case .start: return guide.startCue
        case .middle: return nil
        case .end: return guide.endCue
        }
    }
}

/// 가이드 좌표 계산(순수 함수, 테스트 대상).
enum SlotGuideGeometry {
    /// 실루엣 사각형(폭 = 키의 0.42배). 발끝이 `silhouetteFootY`, 가운데가 `silhouetteX`.
    static func silhouetteRect(guide: SlotGuide, in size: CGSize) -> CGRect {
        let h = size.height * guide.silhouetteHeight
        let w = h * 0.42
        return CGRect(x: size.width * guide.silhouetteX - w / 2, y: size.height * guide.silhouetteFootY - h, width: w, height: h)
    }

    static func arrowPosition(_ arrow: SlotGuide.Arrow, in size: CGSize) -> CGPoint {
        switch arrow {
        case .enterFromLeft: return CGPoint(x: size.width * 0.18, y: size.height * 0.55)
        case .enterFromRight: return CGPoint(x: size.width * 0.82, y: size.height * 0.55)
        case .exitLeft: return CGPoint(x: size.width * 0.18, y: size.height * 0.55)
        case .exitRight: return CGPoint(x: size.width * 0.82, y: size.height * 0.55)
        case .up: return CGPoint(x: size.width / 2, y: size.height * 0.2)
        case .down: return CGPoint(x: size.width / 2, y: size.height * 0.2)
        case .whipRight: return CGPoint(x: size.width * 0.7, y: size.height * 0.5)
        case .rotate: return CGPoint(x: size.width / 2, y: size.height * 0.5)
        }
    }
}

private struct ArrowBadge: View {
    let arrow: SlotGuide.Arrow

    var body: some View {
        let (symbol, text): (String, String) = {
            switch arrow {
            case .enterFromLeft: return ("arrow.right", "들어오기")
            case .enterFromRight: return ("arrow.left", "들어오기")
            case .exitLeft: return ("arrow.left", "나가기")
            case .exitRight: return ("arrow.right", "나가기")
            case .up: return ("arrow.up", "위로")
            case .down: return ("arrow.down", "아래로")
            case .whipRight: return ("arrow.right.to.line", "휙!")
            case .rotate: return ("arrow.clockwise", "돌리기")
            }
        }()
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 44, weight: .bold))
            Text(text).font(.caption.weight(.bold))
        }
        .foregroundStyle(.yellow)
        .shadow(color: .black.opacity(0.6), radius: 4)
    }
}

/// 단순한 사람 실루엣(머리 + 몸통 + 다리, 포즈별 팔). 틀 크기에 맞춰 그린다.
struct SilhouetteShape: Shape {
    let kind: SlotGuide.Silhouette

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        // 머리
        p.addEllipse(in: CGRect(x: r.minX + w * 0.36, y: r.minY, width: w * 0.28, height: h * 0.13))
        // 몸통(어깨 → 허리)
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.24, y: r.minY + h * 0.15, width: w * 0.52, height: h * 0.38),
                         cornerSize: CGSize(width: w * 0.12, height: w * 0.12))
        // 다리
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.28, y: r.minY + h * 0.52, width: w * 0.2, height: h * 0.48),
                         cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.52, y: r.minY + h * 0.52, width: w * 0.2, height: h * 0.48),
                         cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
        // 팔
        switch kind {
        case .standing, .back:
            p.addRoundedRect(in: CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.17, width: w * 0.14, height: h * 0.34),
                             cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
            p.addRoundedRect(in: CGRect(x: r.minX + w * 0.78, y: r.minY + h * 0.17, width: w * 0.14, height: h * 0.34),
                             cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
        case .armsUp:
            var left = Path()
            left.move(to: pt(0.28, 0.2)); left.addLine(to: pt(0.02, -0.08))
            var right = Path()
            right.move(to: pt(0.72, 0.2)); right.addLine(to: pt(0.98, -0.08))
            p.addPath(left.strokedPath(StrokeStyle(lineWidth: w * 0.13, lineCap: .round)))
            p.addPath(right.strokedPath(StrokeStyle(lineWidth: w * 0.13, lineCap: .round)))
        }
        return p
    }
}
