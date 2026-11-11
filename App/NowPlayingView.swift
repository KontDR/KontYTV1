import SwiftUI
import AVKit
import MediaPlayer

struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .systemMint; return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
struct NowPlayingView: View {
    // One sheet slot for every pop-up. Chaining several .sheet modifiers on the same view is
    // fragile across SwiftUI versions; a single item-driven sheet is predictable and cheaper.
    private enum PlayerSheet: String, Identifiable {
        case lyrics, queue
        var id: String { rawValue }
    }
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var audioOnly = false
    @State private var activeSheet: PlayerSheet?
    @State private var scrubbing = false
    @State private var position: Double = 0
    @State private var showEffects = false
    @State private var fullscreen = false
    /// Mirrors the Ayarlar switch: one value, two entry points.
    @AppStorage("pictureInPicture") private var pipEnabled = false
    private var itemsByID: [UUID: MediaItem] {
        var map: [UUID: MediaItem] = [:]
        map.reserveCapacity(library.items.count)
        for item in library.items { map[item.id] = item }
        return map
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                visual
                if let item = library.current {
                    InlineLyrics(item: item, onOpen: { activeSheet = .lyrics })
                }
                titleBlock
                timeline
                transport
                quickActions
                soundControls
                if let operation = library.processingTitle {
                    HStack {
                        ProgressView(); Text(operation).font(.caption).lineLimit(1)
                        Button("İptal") { library.cancelProcessing() }
                    }
                }
                if let message = library.message {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.orange)
                        Button("Kapat") { library.message = nil }
                    }
                }
                playlistButtons
                trackDetails
            }.padding(16)
        }
        .background(LinearGradient(colors: [.mint.opacity(0.10), .black], startPoint: .top, endPoint: .bottom))
        .onReceive(library.$elapsed) { value in
            if !scrubbing { position = min(max(0, value), max(library.duration, 1)) }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .lyrics:
                if let item = library.current {
                    LyricsView(item: item)
                        .environmentObject(library)
                        .onDisappear { NotificationCenter.default.post(name: .kontytLyricsChanged, object: item.id) }
                }
            case .queue: queueSheet
            }
        }
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $fullscreen) { FullscreenPlayer().environmentObject(library) }
    }
    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 36, height: 40) }
            Spacer(); BrandHeader(); Spacer()
            AirPlayPicker().frame(width: 30, height: 30)
            Menu {
                if library.current?.isVideo == true { Toggle("Yalnızca sesi dinle", isOn: $audioOnly) }
                if library.current?.isVideo == true {
                    Toggle(isOn: $pipEnabled) {
                        Label("Resim içinde resim (PiP)", systemImage: "pip")
                    }
                }
                if library.current?.isVideo == true && library.videoDetached {
                    Button { library.videoDetached = false } label: { Label("Videoyu göster", systemImage: "rectangle.on.rectangle") }
                }
                if library.current?.isVideo == true && !library.videoDetached {
                    Button { audioOnly = false; library.detachVideoSurface() } label: {
                        Label("Videoyu kapat, ses devam etsin", systemImage: "rectangle.slash")
                    }
                }
                Menu("dB artırılmış M4A kopyası") {
                    if let item = library.current {
                        Button("+3 dB · yeni dosya") { library.boostAudio(item, decibels: 3) }
                        Button("+6 dB · yeni dosya") { library.boostAudio(item, decibels: 6) }
                    }
                }
                Button(library.loopB != nil ? "A–B kapat" : (library.loopA != nil ? "B noktası" : "A noktası")) { library.markLoop() }
                if let item = library.current { ShareLink(item: library.file(item)) { Label("Dosyayı paylaş", systemImage: "square.and.arrow.up") } }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 40) }
                .accessibilityLabel("Diğer oynatma ve dB kopyası seçenekleri")
        }
    }
    @ViewBuilder private var visual: some View {
        if library.current?.isVideo == true && !audioOnly && !library.videoDetached {
            ZStack(alignment: .bottomTrailing) {
                if fullscreen {
                    // The full screen cover owns the player while it is up: one AVPlayerViewController at
                    // a time, never two views fighting for the same AVPlayer.
                    Color.black.frame(height: 205).clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    PlayerSurface(player: library.player, allowsPiP: pipEnabled,
                                  onStopped: { library.ensureAudioContinues() })
                        .frame(height: 205).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Button { fullscreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.bold()).foregroundStyle(.white)
                        .padding(9).background(.black.opacity(0.45), in: Circle())
                }
                .padding(8)
                .accessibilityLabel("Tam ekran")
            }
        } else if let item = library.current {
            TrackArtwork(item: item).frame(height: 190).frame(maxWidth: .infinity)
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(library.current?.name ?? "Dosya seç").font(.headline).lineLimit(2)
            if let channel = library.current?.channel, !channel.isEmpty {
                Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var timeline: some View {
        VStack(spacing: 1) {
            Slider(value: $position, in: 0...max(library.duration, 1), onEditingChanged: { editing in
                scrubbing = editing
                if !editing { library.seek(position) }
            }).tint(.mint)
            HStack {
                Text(time(position))
                Spacer()
                if let deadline = library.sleepUntil {
                    let left = max(0, Int(deadline.timeIntervalSinceNow / 60) + 1)
                    Label("\(left) dk", systemImage: "moon.fill").labelStyle(.titleAndIcon)
                }
                Spacer()
                Text(time(library.duration))
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private var transport: some View {
        HStack(spacing: 16) {
            Button { library.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(library.shuffled ? Color.mint : Color.secondary).frame(width: 38, height: 44)
            }.accessibilityLabel(library.shuffled ? "Karıştırmayı kapat" : "Karışık çal")
            Button { library.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 38, height: 44) }.accessibilityLabel("Önceki")
            Button { library.playing ? library.pause() : library.resume() } label: {
                Image(systemName: library.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56)).foregroundStyle(.mint)
            }.accessibilityLabel(library.playing ? "Duraklat" : "Oynat")
            Button { library.next() } label: { Image(systemName: "forward.end.fill").frame(width: 38, height: 44) }.accessibilityLabel("Sonraki")
            Button { library.repeatMode = (library.repeatMode + 1) % 3 } label: {
                Image(systemName: library.repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(library.repeatMode == 0 ? Color.secondary : Color.mint).frame(width: 38, height: 44)
            }.accessibilityLabel("Tekrar modu \(library.repeatMode)")
        }.font(.title3).buttonStyle(.plain).frame(maxWidth: .infinity)
    }
    private var quickActions: some View {
        HStack {
            Button { library.seek(library.elapsed - 15) } label: { Image(systemName: "gobackward.15").frame(width: 38, height: 36) }.accessibilityLabel("15 saniye geri")
            Button { activeSheet = .lyrics } label: { Label("Sözler", systemImage: "text.quote").font(.caption) }.disabled(library.current == nil)
            Spacer()
            Button { showEffects = true } label: {
                Image(systemName: library.liveEffectsActive ? "waveform.badge.plus" : "slider.horizontal.3")
                    .foregroundStyle(library.liveEffectsActive ? Color.mint : Color.secondary).frame(width: 32, height: 36)
            }.accessibilityLabel("Canlı ses efektleri")
            Menu {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                    Button("\(value.formatted())×") { library.setRate(value) }
                }
            } label: { Text("\(library.rate.formatted())×").font(.caption.bold()).frame(height: 36) }
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) dakika") { library.setSleep(minutes: minutes) } }
                Button("Zamanlayıcıyı kapat") { library.setSleep(minutes: 0) }
            } label: { Image(systemName: library.sleepUntil == nil ? "moon" : "moon.fill").frame(width: 36, height: 36) }.accessibilityLabel("Uyku zamanlayıcısı")
            Button { library.seek(library.elapsed + 15) } label: { Image(systemName: "goforward.15").frame(width: 38, height: 36) }.accessibilityLabel("15 saniye ileri")
        }.buttonStyle(.plain)
    }
    // Effects live behind one button instead of a permanently expanded disclosure block, so the
    // player screen stays short during normal listening.
    private var soundControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(library.liveEffectsActive ? Color.mint : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(library.liveEffectsActive ? "Canlı efekt açık" : "Canlı efektler kapalı").font(.caption.bold())
                Text(library.liveGainStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if library.liveEffectsActive { Button("Sıfırla") { library.resetLiveEffects() }.font(.caption) }
            Button("Ayarlar") { showEffects = true }.font(.caption.bold())
        }
        .padding(10)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showEffects) { effectsSheet }
    }
    private var effectsSheet: some View {
        NavigationStack {
            Form {
                volumeSection
                gainSection
                reverbSection
                pitchSection
                slowSection
                effectsFooter
            }
            .navigationTitle("Canlı efektler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { showEffects = false } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private var volumeSection: some View {
        Section("Cihaz ses düzeyi") { SystemVolumeSlider().frame(height: 30) }
    }
    private var gainSection: some View {
        Section("Ses yüksekliği · canlı") {
            HStack {
                Text("\(Int((library.liveGainFactor * 100).rounded()))%")
                    .monospacedDigit().frame(width: 52, alignment: .leading)
                Slider(value: gainBinding, in: 1...2, step: 0.05).tint(.mint)
            }
            Button("Normal (%100)") { library.setLiveGain(1) }.font(.caption)
            Text("Dosya değişmez. Yumuşak tepe sınırlama açıktır; bozulma olursa değeri düşür. Kalıcı kopya için Diğer → dB artırılmış M4A.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var reverbSection: some View {
        Section("Yankı · canlı") {
            HStack {
                Text("%\(Int((library.liveReverbMix * 100).rounded()))")
                    .monospacedDigit().frame(width: 52, alignment: .leading)
                Slider(value: reverbBinding, in: 0...0.6, step: 0.02).tint(.mint)
            }
            Button("Yankıyı kapat") { library.setLiveReverb(0) }.font(.caption)
        }
    }
    private var pitchSection: some View {
        Section("Ses tonu · canlı") {
            HStack {
                Text(String(format: "%+.1f", library.livePitchSemitones))
                    .monospacedDigit().frame(width: 52, alignment: .leading)
                Slider(value: pitchBinding, in: -6...6, step: 0.5).tint(.mint)
            }
            HStack {
                Button("Kalın ses") { library.setLivePitch(-3) }.font(.caption)
                Spacer()
                Button("Normal") { library.setLivePitch(0) }.font(.caption)
                Spacer()
                Button("İnce ses") { library.setLivePitch(3) }.font(.caption)
            }
            Text("Yarım perde cinsinden. Yüksek değerlerde hafif metalik renk normaldir; canlı efekttir, dosyayı değiştirmez.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var slowSection: some View {
        Section("Yavaşlat · perde korunur") {
            HStack {
                ForEach([Float(0.5), 0.75, 1], id: \.self) { value in slowButton(value) }
            }
            Text("Oynatma hızı. Ses tonu efektinden bağımsızdır; ikisi birlikte kullanılabilir.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func slowButton(_ value: Float) -> some View {
        Button("\(value.formatted())×") { library.setRate(value) }
            .buttonStyle(.bordered)
            .tint(abs(library.rate - value) < 0.01 ? Color.mint : Color.secondary)
    }
    private var effectsFooter: some View {
        Section {
            Text(library.liveGainStatus).font(.caption2).foregroundStyle(.secondary)
            Button("Tüm canlı efektleri sıfırla") { library.resetLiveEffects() }
            Button("Hızı normale al") { library.setRate(1) }
        }
    }
    private var gainBinding: Binding<Double> {
        Binding(get: { Double(library.liveGainFactor) }, set: { library.setLiveGain(Float($0)) })
    }
    private var reverbBinding: Binding<Double> {
        Binding(get: { Double(library.liveReverbMix) }, set: { library.setLiveReverb(Float($0)) })
    }
    private var pitchBinding: Binding<Double> {
        Binding(get: { Double(library.livePitchSemitones) }, set: { library.setLivePitch(Float($0)) })
    }
    private var playlistButtons: some View {
        Button { activeSheet = .queue } label: { Label("Sıradakiler · \(library.queue.count)", systemImage: "text.line.first.and.arrowtriangle.forward") }
            .font(.caption).buttonStyle(.bordered)
    }

    /// Track details below the queue: file info, source, and useful actions that fill the empty space.
    private var trackDetails: some View {
        guard let item = library.current else { return AnyView(EmptyView()) }
        let fileSize = (try? DiskFile.size(library.file(item))) ?? 0
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("Dosya bilgileri").font(.caption.bold()).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Label("Süre", systemImage: "clock")
                    Spacer()
                    Text(time(item.duration ?? 0)).foregroundStyle(.secondary)
                }
                HStack {
                    Label("Tür", systemImage: item.isVideo ? "film" : "music.note")
                    Spacer()
                    Text(item.isVideo ? "Video" : "Müzik").foregroundStyle(.secondary)
                }
                HStack {
                    Label("Kaynak", systemImage: "link")
                    Spacer()
                    Text(item.sourceVideoID ?? "Yerel dosya").foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    Label("Boyut", systemImage: "doc.fill")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)).foregroundStyle(.secondary)
                }
                HStack {
                    Label("Ekleme tarihi", systemImage: "calendar")
                    Spacer()
                    Text(item.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Divider()
                HStack(spacing: 16) {
                    Button { activeSheet = .lyrics } label: {
                        VStack(spacing: 2) { Image(systemName: "text.quote").font(.title2); Text("Sözler").font(.caption2) }
                    }.buttonStyle(.plain).disabled(modelLyricsEmpty(item))
                    Button { /* duplicate handling could go here */ } label: {
                        VStack(spacing: 2) { Image(systemName: "square.on.square").font(.title2); Text("Kopyala").font(.caption2) }
                    }.buttonStyle(.plain)
                    Button { library.remove(item) } label: {
                        VStack(spacing: 2) { Image(systemName: "trash").font(.title2).foregroundStyle(.red); Text("Kaldır").font(.caption2) }
                    }.buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        )
    }

    private func modelLyricsEmpty(_ item: MediaItem) -> Bool {
        // placeholder guard so the lyrics button state stays sensible without extra state
        return false
    }
    private var queueSheet: some View {
        NavigationStack {
            List {
                if library.queue.isEmpty { Text("Sırada parça yok.").foregroundStyle(.secondary) }
                ForEach(library.queue, id: \.self) { id in
                    if let item = itemsByID[id] { queueRow(item, id: id) }
                }
                .onMove { from, to in library.moveQueue(fromOffsets: from, toOffset: to) }
            }.navigationTitle("Sıradakiler").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Kapat") { activeSheet = nil } }
                    ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func queueRow(_ item: MediaItem, id: UUID) -> some View {
        Button { library.play(item); activeSheet = nil } label: {
            HStack {
                Image(systemName: id == library.current?.id ? "waveform" : "music.note")
                Text(item.name).foregroundStyle(id == library.current?.id ? Color.mint : Color.primary)
                Spacer()
                Text(time(item.duration ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            Button("Sıradan çıkar", role: .destructive) { library.removeFromQueue(id) }
        }
        .contextMenu {
            Button { library.moveQueueItem(id, by: -1) } label: { Label("Yukarı taşı", systemImage: "arrow.up") }
            Button { library.moveQueueItem(id, by: 1) } label: { Label("Aşağı taşı", systemImage: "arrow.down") }
            Button(role: .destructive) { library.removeFromQueue(id) } label: { Label("Sıradan çıkar", systemImage: "minus.circle") }
        }
    }
}
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let view = MPVolumeView(); view.showsRouteButton = false; return view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Full screen picture for a video. One AVPlayer, one AVPlayerViewController: the inline surface hides
/// itself while this is up so AVKit never owns the same player twice. Closing it never stops the sound.
struct FullscreenPlayer: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pictureInPicture") private var pipEnabled = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: library.player, allowsPiP: pipEnabled,
                          onStopped: { library.ensureAudioContinues() })
                .ignoresSafeArea()
            VStack {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Tam ekranı kapat")
                    Spacer()
                    Text(library.current?.name ?? "").font(.caption).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).padding(8).background(.black.opacity(0.35), in: Capsule())
                }
                Spacer()
                transportBar
            }
            .padding(16)
        }
        .statusBarHidden()
    }
    /// Watching a video should not mean leaving full screen to skip a track.
    private var transportBar: some View {
        HStack(spacing: 20) {
            Button { library.previous() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                .accessibilityLabel("Önceki")
            Button { library.playing ? library.pause() : library.resume() } label: {
                Image(systemName: library.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
            }.accessibilityLabel(library.playing ? "Duraklat" : "Oynat")
            Button { library.next() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                .accessibilityLabel("Sonraki")
            Text(clock(library.elapsed) + " / " + clock(library.duration)).font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .buttonStyle(.plain)
    }
    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
