import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class TakeAudioPlayer: NSObject {
    private let audioSessionManager: any AudioSessionManaging
    private let notificationCenter: NotificationCenter
    private let playerVolume: Float

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var loadedURL: URL?
    private var observerGeneration: UInt64 = 0

    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    init(
        audioSessionManager: (any AudioSessionManaging)? = nil,
        notificationCenter: NotificationCenter = .default,
        playerVolume: Float = 1.0
    ) {
        self.audioSessionManager = audioSessionManager ?? SystemAudioSessionManager()
        self.notificationCenter = notificationCenter
        self.playerVolume = min(max(playerVolume, 0), 1)
        super.init()
    }

    func load(url: URL) {
        if loadedURL == url, isLoaded, player != nil {
            return
        }
        stop()
        errorMessage = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "The recording file could not be found on this device."
            isLoaded = false
            duration = 0
            currentTime = 0
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = playerVolume
            newPlayer.delegate = self
            guard newPlayer.prepareToPlay(), newPlayer.duration.isFinite, newPlayer.duration > 0 else {
                newPlayer.delegate = nil
                errorMessage = "This audio file could not be prepared for playback."
                isLoaded = false
                duration = 0
                return
            }
            player = newPlayer
            loadedURL = url
            duration = newPlayer.duration
            currentTime = 0
            isLoaded = true
            isPlaying = false
        } catch {
            errorMessage = "Spelum could not open this recording: \(error.localizedDescription)"
            isLoaded = false
            duration = 0
            currentTime = 0
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player, isLoaded else { return }
        errorMessage = nil
        do {
            try audioSessionManager.activateForPlayback()
        } catch {
            errorMessage = "Audio playback session could not start: \(error.localizedDescription)"
            return
        }
        if currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        installObservers()
        if player.play() {
            isPlaying = true
            startProgressTimer()
        } else {
            errorMessage = "Playback could not start."
            isPlaying = false
        }
    }

    func pause() {
        guard let player else { return }
        player.pause()
        currentTime = clampedTime(player.currentTime)
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        stopProgressTimer()
        removeObservers()
        if let current = player {
            player = nil
            current.delegate = nil
            current.stop()
        }
        loadedURL = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        audioSessionManager.deactivate()
    }

    func seek(to time: TimeInterval, autoPlay: Bool = false) {
        guard let player, isLoaded else { return }
        let clamped = clampedTime(time)
        player.currentTime = clamped
        currentTime = clamped
        if autoPlay && !isPlaying {
            play()
        }
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta, autoPlay: false)
    }

    func handleAudioInterruptionBegan() {
        if isPlaying {
            pause()
        }
    }
}

extension TakeAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let senderBox = WeakObjectBox(player)
        Task { @MainActor [weak self] in
            guard let self,
                  let activePlayer = self.player,
                  let sender = senderBox.value,
                  activePlayer === sender else {
                return
            }
            self.stopProgressTimer()
            self.isPlaying = false
            self.currentTime = flag ? self.duration : self.clampedTime(activePlayer.currentTime)
            self.audioSessionManager.deactivate()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let senderBox = WeakObjectBox(player)
        Task { @MainActor [weak self] in
            guard let self,
                  let activePlayer = self.player,
                  let sender = senderBox.value,
                  activePlayer === sender else {
                return
            }
            self.stopProgressTimer()
            self.isPlaying = false
            self.errorMessage = error?.localizedDescription ?? "An error occurred while decoding this recording."
            self.audioSessionManager.deactivate()
        }
    }
}

private extension TakeAudioPlayer {
    func clampedTime(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(0, value), max(0, duration))
    }

    func startProgressTimer() {
        progressTimer?.invalidate()
        guard let activePlayer = player else { return }
        let expectedBox = WeakObjectBox(activePlayer)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.player,
                      let expected = expectedBox.value,
                      current === expected else {
                    return
                }
                self.currentTime = self.clampedTime(current.currentTime)
                if !current.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopProgressTimer()
                }
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func installObservers() {
        removeObservers()
        observerGeneration &+= 1
        let activeGeneration = observerGeneration
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      self.observerGeneration == activeGeneration,
                      let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                      type == .began else {
                    return
                }
                self.handleAudioInterruptionBegan()
            }
        }
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      self.observerGeneration == activeGeneration,
                      let reasonValue,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable else {
                    return
                }
                self.handleAudioInterruptionBegan()
            }
        }
    }

    func removeObservers() {
        observerGeneration &+= 1
        if let interruptionObserver {
            notificationCenter.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
    }
}
