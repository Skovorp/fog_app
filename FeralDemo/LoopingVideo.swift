import AVKit
import SwiftUI
import UIKit

/// Silent, auto-playing, infinitely-looping video for the instruction screen
/// hero illustrations. Built on AVQueuePlayer + AVPlayerLooper — the looper
/// queues a duplicate of the asset behind the current item so playback never
/// stalls on the seek-to-zero boundary.
///
/// **Asset conventions** (see `Evaluation.demoVideoResource` for the full
/// spec): the clips it plays are silent, short (~5–10 s), framed on a hand
/// or body part performing the gesture on a neutral background, encoded as
/// H.264 baseline at ~480p, with the first and last frames close enough that
/// the loop seam is invisible. Audio is always stripped at encode time AND
/// muted at playback so we don't need to worry about either path.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingVideoView {
        LoopingVideoView(url: url)
    }

    func updateUIView(_ uiView: LoopingVideoView, context: Context) {
        if uiView.currentURL != url {
            uiView.replace(url: url)
        }
    }
}

final class LoopingVideoView: UIView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer: AVPlayerLayer
    private(set) var currentURL: URL?

    init(url: URL) {
        self.playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        player.isMuted = true
        player.actionAtItemEnd = .none
        replace(url: url)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func replace(url: URL) {
        currentURL = url
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    deinit {
        player.pause()
    }
}
