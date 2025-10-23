import UIKit
import AVFoundation
import UniformTypeIdentifiers
import MediaPlayer // Needed for background media controls and now playing info
import SwiftUI // Added for Canvas Preview support

// MARK: - 1. Audio Engine Logic

/// Custom errors for the audio export process.
enum ExportError: Error, LocalizedError {
    case noAudioFileLoaded
    case exportInProgress
}

/// Manages the AVAudioEngine and applies real-time audio effects (Tempo and Reverb).
class AudioProcessor {
    // MARK: Audio Graph Components

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch() // Controls playback speed (rate) and pitch
    private let reverbNode = AVAudioUnitReverb()       // Applies environmental effects
    private var isPitchCorrectionEnabled = true
    private var needsReschedule = false
    private var isExporting = false // Flag to prevent concurrent exports
    
    private var audioFile: AVAudioFile?
    private var isPlaying = false
    
    // Properties for progress tracking
    private var audioFileLength: AVAudioFramePosition = 0
    private var audioSampleRate: Double = 0
    private var lastPlaybackPosition: AVAudioFramePosition = 0
    
    // Property to hold the static Now Playing info
    private var nowPlayingInfo: [String: Any]?
    
    // Closure to notify the UI of external playback changes (e.g., from remote commands)
    var onPlaybackStateChanged: (() -> Void)?

    // MARK: Initialization

    init() {
        configureAudioSession()
        setupInterruptionObserver() // Add interruption observer
        setupAudioEngine()
    }
    
    
    /// Configures the AVAudioSession for background playback.
    private func configureAudioSession() {
        do {
            // Set the category to .playback so audio continues when the screen is locked
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            print("AVAudioSession configured for background playback.")
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }

    /// Sets up the audio processing chain: Player -> Time/Pitch -> Reverb -> Output.
    private func setupAudioEngine() {
        setupRemoteTransportControls()
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.attach(reverbNode)

        // The audio format for the connection points must be consistent.
        // We'll derive it from the output of the player node once a file is loaded.
        // For now, we connect with a placeholder format and will reconnect later.
        let commonFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        
        engine.connect(playerNode, to: timePitchNode, format: commonFormat)
        engine.connect(timePitchNode, to: reverbNode, format: commonFormat)
        engine.connect(reverbNode, to: engine.mainMixerNode, format: commonFormat)

        // Initial setup for effects
        reverbNode.loadFactoryPreset(.mediumHall)
        reverbNode.wetDryMix = 0.0 // 0% wet (no reverb initially)
        timePitchNode.rate = 1.0   // Normal speed initially

        do {
            try engine.start()
        } catch {
            print("Error starting AVAudioEngine: \(error.localizedDescription)")
        }
    }
    
    // MARK: File Loading and Playback

    /// Loads an audio file and extracts its metadata.
    func loadAudioFile(url: URL) -> (title: String, artist: String?, artwork: UIImage?)? {
        // Stop current playback and reset engine
        playerNode.stop()
        isPlaying = false
        
        do {
            self.audioFile = try AVAudioFile(forReading: url)
            guard let file = self.audioFile else { return nil }
            
            self.audioFileLength = file.length
            self.audioSampleRate = file.processingFormat.sampleRate
            self.lastPlaybackPosition = 0 // Reset position for new file
            
            // Reconnect nodes with the audio file's processing format to ensure effects work correctly.
            let fileFormat = file.processingFormat
            engine.connect(playerNode, to: timePitchNode, format: fileFormat)
            // The connection to reverb and mainMixerNode should use the file's format.
            engine.connect(timePitchNode, to: reverbNode, format: fileFormat)
            engine.connect(reverbNode, to: engine.mainMixerNode, format: fileFormat)
            
            // Extract metadata (title and artwork)
            let asset = AVAsset(url: url)
            let metadata = asset.commonMetadata
            var songTitle: String?
            var artistName: String?
            var artworkImage: UIImage?
            
            for item in metadata {
                // FIX: Use the full AVMetadataKey constants to avoid conflicts
                if item.commonKey == AVMetadataKey.commonKeyTitle, let title = item.stringValue {
                    songTitle = title
                } else if item.commonKey == AVMetadataKey.commonKeyArtist, let artist = item.stringValue {
                    artistName = artist
                } else if item.commonKey == AVMetadataKey.commonKeyArtwork, let data = item.dataValue {
                    artworkImage = UIImage(data: data)
                }
            }

            // Prepare the static "Now Playing" info once.
            self.nowPlayingInfo = [
                MPMediaItemPropertyTitle: songTitle ?? url.deletingPathExtension().lastPathComponent,
                MPMediaItemPropertyArtist: artistName,
                MPMediaItemPropertyPlaybackDuration: getAudioDuration()
            ]
            
            if let artwork = artworkImage {
                self.nowPlayingInfo?[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            }

            // Schedule the file to loop and prepare for playback
            playerNode.scheduleFile(file, at: nil) { [weak self] in // Schedule the whole file initially
                // This completion handler is called when the file has finished playing.
                // We need to reschedule it for the next playback.
                self?.needsReschedule = true
            }

            let title = songTitle ?? url.deletingPathExtension().lastPathComponent
            
            print("Audio file loaded: \(title)")
            return (title: title, artist: artistName, artwork: artworkImage)
            
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
            self.audioFile = nil
            self.nowPlayingInfo = nil // Clear info on failure
            return nil
        }
    }
    
    /// Starts or stops the playback and handles file rescheduling for looping.
    func togglePlayback() {
        guard audioFile != nil else {
            print("No audio file loaded.")
            return
        }

        if playerNode.isPlaying {
            playerNode.pause()
            lastPlaybackPosition = getCurrentFramePosition() ?? lastPlaybackPosition
            isPlaying = false
            print("Playback paused.")
        } else {
            // If the file finished playing, we need to stop, reschedule, and then play.
            if needsReschedule {
                playerNode.stop()
                // Ensure the engine is running before attempting to play after rescheduling
                if !engine.isRunning {
                    do {
                        try engine.start()
                        print("AVAudioEngine restarted for playback after reschedule.")
                    } catch {
                        print("Error restarting AVAudioEngine for reschedule: \(error.localizedDescription)")
                        return // Cannot play if engine fails to start
                    }
                }
                guard let file = audioFile else { return }
                // When re-scheduling after finishing, start from the beginning
                lastPlaybackPosition = 0
                let frameCount = AVAudioFrameCount(audioFileLength - lastPlaybackPosition)
                playerNode.scheduleSegment(file, startingFrame: lastPlaybackPosition, frameCount: frameCount, at: nil) { [weak self] in
                    self?.needsReschedule = true
                }

                needsReschedule = false
            }
            // Ensure the engine is running before attempting to play/resume
            if !engine.isRunning {
                do {
                    try engine.start()
                    print("AVAudioEngine restarted for playback.")
                } catch {
                    print("Error restarting AVAudioEngine: \(error.localizedDescription)")
                    return // Cannot play if engine fails to start
                }
            }
            playerNode.play()
            isPlaying = true
            print("Playback started/resumed.")
        }
        updateNowPlayingInfo(isPaused: !isPlaying)
    }
    
    /// Seeks to a specific time in the audio file.
    /// - Parameter time: The time in seconds to seek to.
    func seek(to time: Double) {
        guard let audioFile = audioFile, audioSampleRate > 0 else { return }

        let wasPlaying = playerNode.isPlaying
        playerNode.stop()

        let startingFrame = AVAudioFramePosition(time * audioSampleRate)
        let frameCount = AVAudioFrameCount(audioFileLength - startingFrame)

        guard frameCount > 0 else {
            print("Seek time is out of bounds.")
            return
        }

        lastPlaybackPosition = startingFrame
        needsReschedule = false

        playerNode.scheduleSegment(audioFile, startingFrame: startingFrame, frameCount: frameCount, at: nil) { [weak self] in
            self?.needsReschedule = true
        }

        if wasPlaying {
            playerNode.play()
        }
        updateNowPlayingInfo(isPaused: !wasPlaying)
    }
    
    func isCurrentlyPlaying() -> Bool {
        return isPlaying
    }
    
    /// Returns the total duration of the audio file in seconds.
    func getAudioDuration() -> Double {
        guard audioSampleRate > 0 else { return 0 }
        return Double(audioFileLength) / audioSampleRate
    }

    /// Returns the current playback time in seconds.
    func getCurrentTime() -> Double {
        guard let position = getCurrentFramePosition() else { return Double(lastPlaybackPosition) / audioSampleRate }
        return Double(position) / audioSampleRate
    }
    
    private func getCurrentFramePosition() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime, let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        return lastPlaybackPosition + playerTime.sampleTime
    }
    
    // MARK: Now Playing Info & Remote Commands
    
    /// Configures the handlers for remote commands from Control Center and the lock screen.
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Add handler for Play Command
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let self = self, !self.isCurrentlyPlaying() else { return .commandFailed }
            self.togglePlayback()
            self.onPlaybackStateChanged?()
            return .success
        }

        // Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let self = self, self.isCurrentlyPlaying() else { return .commandFailed }
            self.togglePlayback()
            self.onPlaybackStateChanged?()
            return .success
        }
        
        // Add handler for seek/scrub
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            self.onPlaybackStateChanged?()
            return .success
        }
    }

    /// Updates the Now Playing information on the lock screen and Control Center.
    func updateNowPlayingInfo(isPaused: Bool = false) {
        guard var info = self.nowPlayingInfo else {
            // Clear now playing info if no file is loaded
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        // Update only the dynamic properties: elapsed time and playback rate.
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = getCurrentTime()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : timePitchNode.rate

        // Set the updated information.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    /// Sets up an observer for audio session interruptions.
    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }
    
    /// Handles audio session interruptions (e.g., phone calls).
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("Audio session interruption began.")
            // Pause playback if currently playing
            if isPlaying {
                playerNode.pause()
                lastPlaybackPosition = getCurrentFramePosition() ?? lastPlaybackPosition
                isPlaying = false
                updateNowPlayingInfo(isPaused: true)
                onPlaybackStateChanged?() // Notify UI to update play/pause button
            }
            // The engine might stop automatically. We don't explicitly stop it here
            // as the system often handles it, and we'll restart it if needed on resume.
            
        case .ended:
            print("Audio session interruption ended.")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                print("Audio session should resume. Attempting to reactivate.")
                // Reactivate the session. The engine will be restarted by togglePlayback if needed.
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        @unknown default:
            print("Unknown audio session interruption type.")
        }
    }
    
    // MARK: Effect Controls

    /// Adjusts the song's playback rate (speed/tempo).
    /// - Parameter rate: The new playback rate (0.5 to 2.0).
    func setPlaybackRate(rate: Float, linkedPitch: Float?) {
        timePitchNode.rate = rate
        
        // If a linked pitch value is provided, use it.
        // Otherwise, use the existing pitch value to maintain separation.
        if let pitch = linkedPitch {
            timePitchNode.pitch = pitch
        }
    }
    
    /// Adjusts the song's pitch.
    /// - Parameter pitch: The new pitch in cents (-1200 to 1200).
    func setPitch(pitch: Float) {
        // When pitch correction is on, changing the pitch slider should not
        // be affected by the rate's automatic pitch shift. The `pitch` property
        // is an independent adjustment.
        timePitchNode.pitch = pitch
    }
    
    /// Adjusts the amount of reverb applied to the song.
    /// - Parameter mix: The wet/dry mix percentage (0.0 to 100.0).
    func setReverbMix(mix: Float) {
        reverbNode.wetDryMix = mix
    }
    
    // MARK: Audio Export

    /// Exports the currently loaded audio file with the applied effects to a temporary file.
    /// - Parameters:
    ///   - completion: A closure called when the export is complete, returning the URL of the exported file or an error.
    func exportAudio(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let sourceFile = self.audioFile else {
            completion(.failure(ExportError.noAudioFileLoaded))
            return
        }
        
        if isExporting {
            completion(.failure(ExportError.exportInProgress))
            return
        }
        
        isExporting = true
        
        // Stop playback to avoid issues with the engine state
        let wasPlaying = playerNode.isPlaying
        if wasPlaying {
            playerNode.pause()
        }

        do {
            let maxFrames: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(.offline, format: sourceFile.processingFormat, maximumFrameCount: maxFrames)
            
            // Create a temporary file URL for the output
            // Saving as an uncompressed .caf file is more robust than encoding to .m4a.
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("exported-\(UUID().uuidString).caf")
            
            // Create the output file using the engine's uncompressed rendering format.
            // This avoids any potential encoding errors.
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: engine.manualRenderingFormat.settings)
            
            // Schedule the entire source file for rendering
            playerNode.scheduleFile(sourceFile, at: nil, completionHandler: nil)
            
            // Start the engine and player for rendering
            try engine.start()
            playerNode.play()
            
            // The buffer to pull rendered audio into
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
                isExporting = false
                return
            }

            while engine.manualRenderingSampleTime < sourceFile.length {
                let framesToRender = min(buffer.frameCapacity, AVAudioFrameCount(sourceFile.length - engine.manualRenderingSampleTime))
                let status = try engine.renderOffline(framesToRender, to: buffer)
                
                switch status {
                case .success:
                    try outputFile.write(from: buffer)
                case .cannotDoInCurrentContext:
                    continue // Try again
                case .error:
                    throw NSError(domain: "AVAudioEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline rendering error."])
                @unknown default:
                    break
                }
            }
            
            // Clean up
            playerNode.stop()
            engine.stop()
            engine.disableManualRenderingMode()
            
            // Reschedule the original file for normal playback
            playerNode.scheduleFile(sourceFile, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            if wasPlaying {
                playerNode.play()
            }
            
            isExporting = false
            completion(.success(outputURL))
            
        } catch {
            // Ensure we clean up on error
            isExporting = false
            engine.disableManualRenderingMode()
            completion(.failure(error))
        }
    }
}

// MARK: - Theme Management

enum ThemeColor: String, CaseIterable {
    case blue, pink, green, red, orange, purple, yellow

    var uiColor: UIColor {
        switch self {
        case .blue: return .systemBlue
        case .pink: return .systemPink
        case .green: return .systemGreen
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .yellow: return .systemYellow
        }
    }

    var capitalized: String {
        return self.rawValue.capitalized
    }
}

class ThemeManager {
    static let shared = ThemeManager()
    private let themeKey = "selectedTheme"

    var currentTheme: ThemeColor {
        get {
            let savedTheme = UserDefaults.standard.string(forKey: themeKey) ?? ThemeColor.blue.rawValue
            return ThemeColor(rawValue: savedTheme) ?? .blue
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }

    private init() {}
}

// MARK: - Settings View Controller

/// Protocol to delegate changes from the settings sheet back to the main view controller.
protocol SettingsViewControllerDelegate: AnyObject {
    func settingsViewController(_ controller: SettingsViewController, didChangeLinkPitchState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicBackgroundState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAnimatedBackgroundState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicThemeState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeTheme theme: ThemeColor)
    func settingsViewController(_ controller: SettingsViewController, didChangeReverbSliderState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeResetSlidersOnTapState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeTapArtworkToChangeSongState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangePrecisePitchState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAccurateSpeedState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowExportButtonState isEnabled: Bool)
}

/// A simple view controller to display app settings.
class SettingsViewController: UIViewController {
    weak var delegate: SettingsViewControllerDelegate?
    var isPitchLinked: Bool = false
    var isDynamicBackgroundEnabled: Bool = false
    var isAnimatedBackgroundEnabled: Bool = true
    var isDynamicThemeEnabled: Bool = false
    var currentTheme: ThemeColor = .blue
    var isReverbSliderEnabled: Bool = true
    var isResetSlidersOnTapEnabled: Bool = true
    var isTapArtworkToChangeSongEnabled: Bool = true
    var isAccuratePitchEnabled: Bool = false
    var isAccurateSpeedEnabled: Bool = false
    var isExportButtonEnabled: Bool = true
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    
    private let scrollView = UIScrollView()

    private let linkPitchSwitch = UISwitch()
    private let linkPitchLabel = UILabel()
    
    private let dynamicBackgroundSwitch = UISwitch()
    private let dynamicBackgroundLabel = UILabel()
    
    private let animatedBackgroundSwitch = UISwitch()
    private let animatedBackgroundLabel = UILabel()
    
    private let dynamicThemeSwitch = UISwitch()
    private let dynamicThemeLabel = UILabel()
    
    private let reverbSliderSwitch = UISwitch()
    private let reverbSliderLabel = UILabel()
    
    private let resetSlidersOnTapSwitch = UISwitch()
    private let resetSlidersOnTapLabel = UILabel()
    
    private let tapArtworkSwitch = UISwitch()
    private let tapArtworkLabel = UILabel()
    
    private let accuratePitchSwitch = UISwitch()
    private let accuratePitchLabel = UILabel()
    
    private let accurateSpeedSwitch = UISwitch()
    private let accurateSpeedLabel = UILabel()
    
    private let exportButtonSwitch = UISwitch()
    private let exportButtonLabel = UILabel()
    
    private var themeStack: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        title = "Settings"
        impactFeedbackGenerator.prepare()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(dismissSettings))
    }

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        // Add scroll view to the main view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        // Helper to create description labels
        func createDescriptionLabel(with text: String) -> UILabel {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            return label
        }

        // --- Link Pitch Setting ---
        linkPitchLabel.text = "Link Pitch to Speed"
        linkPitchSwitch.isOn = isPitchLinked
        linkPitchSwitch.addTarget(self, action: #selector(linkPitchSwitchChanged), for: .valueChanged)
        let linkPitchStack = UIStackView(arrangedSubviews: [linkPitchLabel, linkPitchSwitch])
        linkPitchStack.spacing = 20
        let linkPitchDescription = createDescriptionLabel(with: "When enabled, changing the speed will also adjust the pitch, like a record player.")
        let linkPitchGroup = UIStackView(arrangedSubviews: [linkPitchStack, linkPitchDescription])
        linkPitchGroup.axis = .vertical
        linkPitchGroup.spacing = 4

        // --- Dynamic Background Setting ---
        dynamicBackgroundLabel.text = "Dynamic Background"
        dynamicBackgroundSwitch.isOn = isDynamicBackgroundEnabled
        dynamicBackgroundSwitch.addTarget(self, action: #selector(dynamicBackgroundSwitchChanged), for: .valueChanged)
        let dynamicBackgroundStack = UIStackView(arrangedSubviews: [dynamicBackgroundLabel, dynamicBackgroundSwitch])
        dynamicBackgroundStack.spacing = 20
        let dynamicBackgroundDescription = createDescriptionLabel(with: "Uses the song's album art to create a blurred background.")
        let dynamicBackgroundGroup = UIStackView(arrangedSubviews: [dynamicBackgroundStack, dynamicBackgroundDescription])
        dynamicBackgroundGroup.axis = .vertical
        dynamicBackgroundGroup.spacing = 4
        
        // --- Animated Background Setting ---
        animatedBackgroundLabel.text = "Animated Background"
        animatedBackgroundSwitch.isOn = isAnimatedBackgroundEnabled
        animatedBackgroundSwitch.addTarget(self, action: #selector(animatedBackgroundSwitchChanged), for: .valueChanged)
        let animatedBackgroundStack = UIStackView(arrangedSubviews: [animatedBackgroundLabel, animatedBackgroundSwitch])
        animatedBackgroundStack.spacing = 20
        let animatedBackgroundDescription = createDescriptionLabel(with: "Enables a slow zooming animation on the dynamic background.")
        let animatedBackgroundGroup = UIStackView(arrangedSubviews: [animatedBackgroundStack, animatedBackgroundDescription])
        animatedBackgroundGroup.axis = .vertical
        animatedBackgroundGroup.spacing = 4

        // --- Dynamic Theme Setting ---
        dynamicThemeLabel.text = "Dynamic Theme"
        dynamicThemeSwitch.isOn = isDynamicThemeEnabled
        dynamicThemeSwitch.addTarget(self, action: #selector(dynamicThemeSwitchChanged), for: .valueChanged)
        let dynamicThemeStack = UIStackView(arrangedSubviews: [dynamicThemeLabel, dynamicThemeSwitch])
        dynamicThemeStack.spacing = 20
        let dynamicThemeDescription = createDescriptionLabel(with: "Automatically picks a theme color from the song's album art.")
        let dynamicThemeGroup = UIStackView(arrangedSubviews: [dynamicThemeStack, dynamicThemeDescription])
        dynamicThemeGroup.axis = .vertical
        dynamicThemeGroup.spacing = 4

        // --- Reverb Slider Setting ---
        reverbSliderLabel.text = "Show Reverb Slider"
        reverbSliderSwitch.isOn = isReverbSliderEnabled
        reverbSliderSwitch.addTarget(self, action: #selector(reverbSliderSwitchChanged), for: .valueChanged)
        let reverbSliderStack = UIStackView(arrangedSubviews: [reverbSliderLabel, reverbSliderSwitch])
        reverbSliderStack.spacing = 20
        let reverbSliderDescription = createDescriptionLabel(with: "Shows or hides the reverb effect slider on the main screen.")
        let reverbSliderGroup = UIStackView(arrangedSubviews: [reverbSliderStack, reverbSliderDescription])
        reverbSliderGroup.axis = .vertical
        reverbSliderGroup.spacing = 4

        // --- Double-Tap to Reset Setting ---
        resetSlidersOnTapLabel.text = "Double-Tap to Reset Sliders"
        resetSlidersOnTapSwitch.isOn = isResetSlidersOnTapEnabled
        resetSlidersOnTapSwitch.addTarget(self, action: #selector(resetSlidersOnTapSwitchChanged), for: .valueChanged)
        let resetSlidersOnTapStack = UIStackView(arrangedSubviews: [resetSlidersOnTapLabel, resetSlidersOnTapSwitch])
        resetSlidersOnTapStack.spacing = 20
        let resetSlidersOnTapDescription = createDescriptionLabel(with: "Allows you to double-tap on the 'Pitch', 'Speed', or 'Reverb' labels to reset their values.")
        let resetSlidersOnTapGroup = UIStackView(arrangedSubviews: [resetSlidersOnTapStack, resetSlidersOnTapDescription])
        resetSlidersOnTapGroup.axis = .vertical
        resetSlidersOnTapGroup.spacing = 4

        // --- Tap Artwork to Change Song Setting ---
        tapArtworkLabel.text = "Tap Artwork to Change Song"
        tapArtworkSwitch.isOn = isTapArtworkToChangeSongEnabled
        tapArtworkSwitch.addTarget(self, action: #selector(tapArtworkSwitchChanged), for: .valueChanged)
        let tapArtworkStack = UIStackView(arrangedSubviews: [tapArtworkLabel, tapArtworkSwitch])
        tapArtworkStack.spacing = 20
        let tapArtworkDescription = createDescriptionLabel(with: "Allows you to tap the album artwork to open the file picker and choose a new song.")
        let tapArtworkGroup = UIStackView(arrangedSubviews: [tapArtworkStack, tapArtworkDescription])
        tapArtworkGroup.axis = .vertical
        tapArtworkGroup.spacing = 4
        
        // --- Accurate Pitch Setting ---
        accuratePitchLabel.text = "Accurate Pitch"
        accuratePitchSwitch.isOn = isAccuratePitchEnabled
        accuratePitchSwitch.addTarget(self, action: #selector(accuratePitchSwitchChanged), for: .valueChanged)
        let accuratePitchStack = UIStackView(arrangedSubviews: [accuratePitchLabel, accuratePitchSwitch])
        accuratePitchStack.spacing = 20
        let accuratePitchDescription = createDescriptionLabel(with: "When enabled, the pitch slider will snap to whole semitones.")
        let accuratePitchGroup = UIStackView(arrangedSubviews: [accuratePitchStack, accuratePitchDescription])
        accuratePitchGroup.axis = .vertical
        accuratePitchGroup.spacing = 4
        
        // --- Accurate Speed Setting ---
        accurateSpeedLabel.text = "Accurate Speed"
        accurateSpeedSwitch.isOn = isAccurateSpeedEnabled
        accurateSpeedSwitch.addTarget(self, action: #selector(accurateSpeedSwitchChanged), for: .valueChanged)
        let accurateSpeedStack = UIStackView(arrangedSubviews: [accurateSpeedLabel, accurateSpeedSwitch])
        accurateSpeedStack.spacing = 20
        let accurateSpeedDescription = createDescriptionLabel(with: "When enabled, the speed slider will snap to 0.05x increments.")
        let preciseSpeedGroup = UIStackView(arrangedSubviews: [accurateSpeedStack, accurateSpeedDescription])
        preciseSpeedGroup.axis = .vertical
        preciseSpeedGroup.spacing = 4
        
        // --- Export Button Setting ---
        exportButtonLabel.text = "Show Export Button"
        exportButtonSwitch.isOn = isExportButtonEnabled
        exportButtonSwitch.addTarget(self, action: #selector(exportButtonSwitchChanged), for: .valueChanged)
        let exportButtonStack = UIStackView(arrangedSubviews: [exportButtonLabel, exportButtonSwitch])
        exportButtonStack.spacing = 20
        let exportButtonDescription = createDescriptionLabel(with: "Shows a button to export the audio with all effects applied.")
        let exportButtonGroup = UIStackView(arrangedSubviews: [exportButtonStack, exportButtonDescription])
        exportButtonGroup.axis = .vertical
        exportButtonGroup.spacing = 4

        // --- Main Settings Stack ---
        let settingsOptionsStack = UIStackView(arrangedSubviews: [
            linkPitchGroup,
            dynamicThemeGroup,
            exportButtonGroup,
            reverbSliderGroup,
            resetSlidersOnTapGroup,
            tapArtworkGroup
        ])
        settingsOptionsStack.axis = .vertical // Corrected spacing
        settingsOptionsStack.addArrangedSubview(dynamicBackgroundGroup) // Re-added dynamic background
        settingsOptionsStack.addArrangedSubview(animatedBackgroundGroup)
        settingsOptionsStack.insertArrangedSubview(preciseSpeedGroup, at: 4) // Insert precise speed after precise pitch
        settingsOptionsStack.insertArrangedSubview(accuratePitchGroup, at: 2)
        settingsOptionsStack.spacing = 25
        settingsOptionsStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Create a content view inside the scroll view to hold all elements
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        
        contentView.addSubview(settingsOptionsStack)

        NSLayoutConstraint.activate([
            settingsOptionsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            settingsOptionsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            settingsOptionsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
        
        // Theme Selection UI
        let themeTitleLabel = UILabel()
        themeTitleLabel.text = "Theme"
        themeTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        
        let colorButtonsStack = UIStackView()
        colorButtonsStack.axis = .horizontal
        colorButtonsStack.distribution = .fillEqually
        colorButtonsStack.spacing = 10
        
        for theme in ThemeColor.allCases {
            let button = UIButton(type: .system)
            button.backgroundColor = theme.uiColor
            button.layer.cornerRadius = 15
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.accessibilityLabel = theme.capitalized
            
            if theme == currentTheme {
                button.layer.borderColor = UIColor.label.cgColor
                button.layer.borderWidth = 2
            }
            
            button.addAction(UIAction { [weak self] _ in
                self?.delegate?.settingsViewController(self!, didChangeTheme: theme)
                self?.dismiss(animated: true)
                self?.impactFeedbackGenerator.impactOccurred()
            }, for: .touchUpInside)
            colorButtonsStack.addArrangedSubview(button)
        }
        
        themeStack = UIStackView(arrangedSubviews: [themeTitleLabel, colorButtonsStack])
        themeStack.axis = .vertical
        themeStack.spacing = 15
        themeStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(themeStack)
        
        NSLayoutConstraint.activate([
            themeStack.topAnchor.constraint(equalTo: settingsOptionsStack.bottomAnchor, constant: 40),
            themeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            themeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            themeStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20), // Important for contentSize
            
            // Content view constraints to scroll view
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor) // Ensure vertical scrolling only
        ])
        
        // Initial state for theme picker
        themeStack.isHidden = isDynamicThemeEnabled
    }
    
    @objc private func dismissSettings() {
        dismiss(animated: true, completion: nil)
        impactFeedbackGenerator.impactOccurred()
    }

    @objc private func linkPitchSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeLinkPitchState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func dynamicBackgroundSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeDynamicBackgroundState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func animatedBackgroundSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeAnimatedBackgroundState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func dynamicThemeSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeDynamicThemeState: sender.isOn)
        themeStack.isHidden = sender.isOn
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func reverbSliderSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeReverbSliderState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetSlidersOnTapSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeResetSlidersOnTapState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func tapArtworkSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeTapArtworkToChangeSongState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func accuratePitchSwitchChanged(_ sender: UISwitch) {
        impactFeedbackGenerator.impactOccurred()
        delegate?.settingsViewController(self, didChangePrecisePitchState: sender.isOn)
    }
    
    @objc private func accurateSpeedSwitchChanged(_ sender: UISwitch) {
        impactFeedbackGenerator.impactOccurred()
        delegate?.settingsViewController(self, didChangeAccurateSpeedState: sender.isOn)
    }
    
    @objc private func exportButtonSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowExportButtonState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
}

// MARK: - 2. User Interface and File Picker

class AudioEffectsViewController: UIViewController, UIDocumentPickerDelegate, SettingsViewControllerDelegate {

    // MARK: Properties
    
    private let audioProcessor = AudioProcessor()
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedbackGenerator = UISelectionFeedbackGenerator()
    
    // Background Image View
    private let backgroundImageView = UIImageView()
    private let blurEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .prominent))

    // UI Components
    private let albumArtImageView = UIImageView()
    private let songTitleLabel = UILabel()
    private let artistNameLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let addFileButton = UIButton(type: .system)
    
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private var progressUpdateTimer: Timer?
    
    private let pitchLabel = UILabel()
    private let pitchSlider = UISlider()
    
    private let speedLabel = UILabel()
    private let speedSlider = UISlider()
    
    private let reverbLabel = UILabel()
    private let reverbSlider = UISlider()
    
    private let resetButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    
    // New buttons for rewind and skip
    private let rewindButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    
    // Scroll View for main content
    private let scrollView = UIScrollView()
    
    // Gesture Recognizers
    private let albumArtTapGesture = UITapGestureRecognizer()
    
    // Settings state
    private var isAccuratePitchEnabled = false
    private var isAccurateSpeedEnabled = false
    private var lastSnappedPitchValue: Float = 0.0 // To track discrete pitch changes for haptics
    private var lastSnappedSpeedValue: Float = 1.0 // To track discrete speed changes for haptics
    
    // MARK: View Lifecycle
    
    private var hasLoadedInitialState = false

    override func viewDidLoad() {
        self.isAccurateSpeedEnabled = UserDefaults.standard.bool(forKey: "isAccurateSpeedEnabled")
        self.isAccuratePitchEnabled = UserDefaults.standard.bool(forKey: "isAccuratePitchEnabled")
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark // Lock the app in dark mode
        setupUI()
        resetControlsState(isHidden: true)
        setupAudioProcessorHandler()
        setupStatePersistence()
        setupProgressUpdater()
        setupSliderLabelTapGestures(isEnabled: UserDefaults.standard.bool(forKey: "isResetSlidersOnTapEnabled"))
        impactFeedbackGenerator.prepare()
        selectionFeedbackGenerator.prepare()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // We load state here because it's the first point where `view.window` is guaranteed
        // to be non-nil, which is required for applying the theme's tint color.
        if !hasLoadedInitialState {
            loadSavedState()
            hasLoadedInitialState = true
            updateBackgroundAnimation()
        }
    }

    // MARK: UI Setup
    
    private func applyTheme(color: UIColor) {
        view.window?.tintColor = color
        resetButton.setTitleColor(color, for: .normal)
    }
    
    private func setupAudioProcessorHandler() {
        audioProcessor.onPlaybackStateChanged = { [weak self] in
            self?.updatePlayPauseButtonState()
        }
    }

    private func setupUI() {
        // Background Image and Blur
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundImageView)
        
        // The blur effect view should be a subview of the background image view to fade in together.
        blurEffectView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.addSubview(blurEffectView) // Add blur as a subview
        NSLayoutConstraint.activate([
            blurEffectView.topAnchor.constraint(equalTo: backgroundImageView.topAnchor),
            blurEffectView.bottomAnchor.constraint(equalTo: backgroundImageView.bottomAnchor),
            blurEffectView.leadingAnchor.constraint(equalTo: backgroundImageView.leadingAnchor),
            blurEffectView.trailingAnchor.constraint(equalTo: backgroundImageView.trailingAnchor)
        ])
        blurEffectView.alpha = 1.0 // Always visible when parent is visible
        
        // Set the default background color
        backgroundImageView.alpha = 0 // Parent view is initially hidden
        updateBackground(with: nil, isDynamicEnabled: UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled"))
        
        // The main view background should be clear to see the image behind it
        view.backgroundColor = .black
        
        // Settings Button
        settingsButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        
        // Add File Button (replaces Clear button)
        addFileButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addFileButton.addTarget(self, action: #selector(openFilePicker), for: .touchUpInside)
        addFileButton.translatesAutoresizingMaskIntoConstraints = false
        
        // 1. Album Art Setup
        albumArtImageView.contentMode = .scaleAspectFit
        albumArtImageView.layer.cornerRadius = 12
        albumArtImageView.clipsToBounds = true
        albumArtImageView.backgroundColor = .secondarySystemBackground
        albumArtImageView.image = UIImage(systemName: "music.note")
        albumArtImageView.tintColor = .systemGray
        
        // Enable user interaction and add tap gesture to open file picker
        albumArtImageView.isUserInteractionEnabled = true
        albumArtTapGesture.addTarget(self, action: #selector(openFilePicker))
        albumArtImageView.addGestureRecognizer(albumArtTapGesture)
        
        // 2. Song Title Setup
        songTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        songTitleLabel.textAlignment = .center
        songTitleLabel.numberOfLines = 0 // Allow title to wrap if long
        
        // Artist Name Setup
        artistNameLabel.font = .italicSystemFont(ofSize: 16) // Increased font size
        artistNameLabel.textColor = .secondaryLabel
        artistNameLabel.textAlignment = .center
        artistNameLabel.numberOfLines = 0
        
        let songInfoStack = UIStackView(arrangedSubviews: [songTitleLabel, artistNameLabel])
        songInfoStack.axis = .vertical
        songInfoStack.spacing = 4

        // Center text for labels
        speedLabel.textAlignment = .center
        pitchLabel.textAlignment = .center
        reverbLabel.textAlignment = .center
        songTitleLabel.text = "No File Loaded"

        // 3. Play/Pause Button
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        // Make play/pause button larger and square
        playPauseButton.imageView?.contentMode = .scaleAspectFit
        playPauseButton.contentVerticalAlignment = .fill
        playPauseButton.contentHorizontalAlignment = .fill
        playPauseButton.imageEdgeInsets = UIEdgeInsets(top: 15, left: 15, bottom: 15, right: 15) // Add some padding

        // Rewind 10 seconds button
        rewindButton.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        rewindButton.addTarget(self, action: #selector(rewind10Seconds), for: .touchUpInside)

        // Skip 10 seconds button
        skipButton.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        skipButton.addTarget(self, action: #selector(skip10Seconds), for: .touchUpInside)

        // Progress Slider & Labels
        progressSlider.minimumValue = 0
        progressSlider.addTarget(self, action: #selector(progressSliderScrubbing), for: .valueChanged)
        
        currentTimeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentTimeLabel.text = "0:00"
        
        durationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        durationLabel.text = "0:00"
        
        // Create a horizontal stack view for the slider and its time labels
        let progressStack = UIStackView(arrangedSubviews: [currentTimeLabel, progressSlider, durationLabel])
        progressStack.axis = .horizontal
        progressStack.spacing = 10
        progressStack.alignment = .center

        // Give the labels a fixed width so the slider can fill the remaining space
        currentTimeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        durationLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        // Horizontal stack for playback controls (rewind, play/pause, skip)
        let playbackControlsStack = UIStackView(arrangedSubviews: [rewindButton, playPauseButton, skipButton])
        playbackControlsStack.axis = .horizontal
        playbackControlsStack.spacing = 20 // Adjust spacing as needed
        playbackControlsStack.alignment = .center
        playbackControlsStack.distribution = .fillEqually // Distribute space evenly

        // Pitch Slider Setup (Pitch: -12 semitones to +12 semitones)
        pitchLabel.text = "Pitch (0 st)"
        pitchSlider.minimumValue = -1200 // -12 semitones in cents
        pitchSlider.maximumValue = 1200  // +12 semitones in cents
        pitchSlider.value = 0
        pitchSlider.addTarget(self, action: #selector(pitchSliderChanged), for: .valueChanged)

        // 4. Speed Slider Setup (Rate: 0.5 to 2.0)
        speedLabel.text = "Speed (1.0x)"
        speedSlider.minimumValue = 0.5
        speedSlider.maximumValue = 2.0
        speedSlider.value = 1.0
        speedSlider.addTarget(self, action: #selector(speedSliderChanged), for: .valueChanged)

        // 5. Reverb Slider Setup (Mix: 0.0 to 100.0)
        reverbLabel.text = "Reverb (0%)"
        reverbSlider.minimumValue = 0.0
        reverbSlider.maximumValue = 100.0
        reverbSlider.value = 0.0
        reverbSlider.addTarget(self, action: #selector(reverbSliderChanged), for: .valueChanged)
        // Initialize reverb slider visibility based on saved settings
        let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        reverbLabel.isHidden = !isReverbSliderEnabled
        reverbSlider.isHidden = !isReverbSliderEnabled
        
        // 6. Reset Button Setup (replaces File Picker button)
        // Group the effect sliders with their labels for consistent spacing
        let pitchControlStack = UIStackView(arrangedSubviews: [pitchLabel, pitchSlider])
        pitchControlStack.axis = .vertical
        pitchControlStack.spacing = 8
        let speedControlStack = UIStackView(arrangedSubviews: [speedLabel, speedSlider])
        speedControlStack.axis = .vertical
        speedControlStack.spacing = 8
        let reverbControlStack = UIStackView(arrangedSubviews: [reverbLabel, reverbSlider])
        reverbControlStack.axis = .vertical
        reverbControlStack.spacing = 8
        
        var resetButtonConfig = UIButton.Configuration.filled()
        resetButtonConfig.title = "Reset"
        resetButtonConfig.baseBackgroundColor = .secondarySystemFill
        resetButtonConfig.baseForegroundColor = .label
        resetButtonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        resetButton.configuration = resetButtonConfig
        resetButton.addTarget(self, action: #selector(resetSliders), for: .touchUpInside)

        // Export Button Setup
        var exportButtonConfig = UIButton.Configuration.filled()
        exportButtonConfig.title = "Export"
        exportButtonConfig.baseBackgroundColor = .secondarySystemFill
        exportButtonConfig.baseForegroundColor = .label
        exportButtonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        exportButton.configuration = exportButtonConfig
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        // Horizontal stack for Reset and Export buttons
        let actionButtonsStack = UIStackView(arrangedSubviews: [resetButton, exportButton])
        actionButtonsStack.axis = .horizontal
        actionButtonsStack.spacing = 20
        actionButtonsStack.distribution = .fillEqually

        // 7. Stack View for Layout
        let stackView = UIStackView(arrangedSubviews: [
            albumArtImageView,
            songInfoStack,
            progressStack, // Keep progress stack above playback controls
            playbackControlsStack, // Use the new playback controls stack here
            pitchControlStack,
            speedControlStack,
            reverbControlStack,
            UIView(), // Spacer
            actionButtonsStack
        ])
        
        stackView.axis = .vertical
        stackView.spacing = 20
        // Set custom spacing to create groups of controls
        stackView.setCustomSpacing(30, after: playbackControlsStack)
        stackView.setCustomSpacing(12, after: pitchControlStack)
        stackView.setCustomSpacing(12, after: speedControlStack)
        stackView.setCustomSpacing(30, after: reverbControlStack)
        
        // The spacer view should have a low-priority constraint to allow it to shrink
        if let spacer = stackView.arrangedSubviews[4] as? UIView {
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        }
        
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(settingsButton)
        view.addSubview(addFileButton)
        view.addSubview(stackView)
        
        // Setup ScrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        
        // Set alignment for grouped controls
        pitchControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        speedControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        reverbControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        
        // Bring buttons to the front so they don't get scrolled over
        view.bringSubviewToFront(settingsButton)
        view.bringSubviewToFront(addFileButton)
        // Auto Layout Constraints
        NSLayoutConstraint.activate([
            // Background constraints
            backgroundImageView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Settings button in top left
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            settingsButton.widthAnchor.constraint(equalToConstant: 30),
            settingsButton.heightAnchor.constraint(equalToConstant: 30),
            
            // Add File button in top right
            addFileButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            addFileButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            addFileButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            
            // ScrollView constraints
            scrollView.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            
            // StackView constraints inside ScrollView
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 30),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -30),
            
            // This is crucial: make the stackView's width equal to the scrollView's frame width (minus padding)
            // to enable vertical-only scrolling.
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -60),
            
            // Album Art size constraint
            albumArtImageView.heightAnchor.constraint(equalTo: albumArtImageView.widthAnchor, multiplier: 1.0),
            albumArtImageView.widthAnchor.constraint(equalTo: stackView.widthAnchor, multiplier: 0.65), // 65% width
            
            // Make sliders and button take up more width
            speedSlider.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            progressStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            actionButtonsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
        
        // Constraints for the new playback control buttons
        playbackControlsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true // Ensure the stack fills the width
        playPauseButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 80).isActive = true
        rewindButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        rewindButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        skipButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        skipButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
    }
    
    private func updateBackgroundAnimation() {
        let isAnimated = UserDefaults.standard.bool(forKey: "isAnimatedBackgroundEnabled", defaultValue: true)
        
        // Always remove existing animations to avoid conflicts
        backgroundImageView.layer.removeAllAnimations()
        
        if isAnimated {
            UIView.animate(withDuration: 20, delay: 0, options: [.allowUserInteraction, .autoreverse, .repeat], animations: {
                self.backgroundImageView.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
            })
        } else {
            // Reset transform if animation is disabled
            backgroundImageView.transform = .identity
        }
    }
    
    /// Hides/shows the controls until a file is loaded.
    private func resetControlsState(isHidden: Bool) {
        playPauseButton.isHidden = isHidden
        rewindButton.isHidden = isHidden // Hide new buttons
        skipButton.isHidden = isHidden   // Hide new buttons
        resetButton.isHidden = isHidden
        exportButton.isHidden = isHidden
        progressSlider.isHidden = isHidden
        currentTimeLabel.isHidden = isHidden
        durationLabel.isHidden = isHidden
        
        pitchLabel.isHidden = isHidden
        pitchSlider.isHidden = isHidden
        speedLabel.isHidden = isHidden
        speedSlider.isHidden = isHidden
        reverbLabel.isHidden = isHidden
        reverbSlider.isHidden = isHidden

        // When controls are being hidden, also hide the artist label.
        // When controls are shown, its visibility will be determined by `loadAudioFile`.
        artistNameLabel.isHidden = isHidden
        
        // Reset to initial values
        resetSliders()
        
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
    }
    
    /// Resets only the effect sliders to their default values.
    @objc private func resetSliders() {
        speedSlider.value = 1.0
        pitchSlider.value = 0.0
        lastSnappedSpeedValue = 1.0 // Reset for haptics
        lastSnappedPitchValue = 0.0 // Reset for haptics
        reverbSlider.value = 0.0

        // Trigger the change handlers to update labels and the audio processor
        speedSliderChanged(speedSlider)
        pitchSliderChanged(pitchSlider)
        reverbSliderChanged(reverbSlider)
        impactFeedbackGenerator.impactOccurred() // Add haptic feedback for the global reset button
    }
    
    @objc private func resetPitchSlider() {
        pitchSlider.value = 0.0
        lastSnappedPitchValue = 0.0 // Reset for haptics
        pitchSliderChanged(pitchSlider)
        impactFeedbackGenerator.impactOccurred()
    }

    @objc private func resetSpeedSlider() {
        speedSlider.value = 1.0
        speedSliderChanged(speedSlider)
        lastSnappedSpeedValue = 1.0 // Reset for haptics
        impactFeedbackGenerator.impactOccurred()
    }


    @objc private func resetReverbSlider() {
        reverbSlider.value = 0.0
        reverbSliderChanged(reverbSlider)
        impactFeedbackGenerator.impactOccurred()
    }

    // MARK: State Persistence
    
    private func setupStatePersistence() {
        NotificationCenter.default.addObserver(self, selector: #selector(savePlaybackPosition), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    
    @objc private func savePlaybackPosition() {
        UserDefaults.standard.set(audioProcessor.getCurrentTime(), forKey: "lastPlaybackPosition")
    }
    
    private func loadSavedState() {
        // Restore the last audio file
        // Restore the last audio file first, as it provides the artwork for dynamic theming.
        guard let bookmarkData = UserDefaults.standard.data(forKey: "lastAudioFileBookmark") else {
            // If no saved file, load the default song.mp3 from the app bundle
            if let defaultSongURL = Bundle.main.url(forResource: "song", withExtension: "mp3") {
                print("No saved song found. Loading default song.")
                loadAudioFile(url: defaultSongURL, andPlay: false)
            }
            return
        }
        
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if isStale {
                print("Bookmark is stale, clearing saved state.")
                clearState()
            } else {
                // Now that the file is about to be loaded, restore the state of other settings.
                let isPitchLinked = UserDefaults.standard.bool(forKey: "isPitchLinked")
                settingsViewController(SettingsViewController(), didChangeLinkPitchState: isPitchLinked)
                
                let isDynamicBackgroundEnabled = UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
                let isAnimatedBackgroundEnabled = UserDefaults.standard.bool(forKey: "isAnimatedBackgroundEnabled", defaultValue: true)
                let isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
                let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
                let isResetSlidersOnTapEnabled = UserDefaults.standard.bool(forKey: "isResetSlidersOnTapEnabled")
                let isTapArtworkToChangeSongEnabled = UserDefaults.standard.bool(forKey: "isTapArtworkToChangeSongEnabled")
                let isAccuratePitchEnabled = UserDefaults.standard.bool(forKey: "isAccuratePitchEnabled")
                let isAccurateSpeedEnabled = UserDefaults.standard.bool(forKey: "isAccurateSpeedEnabled")
                let isExportButtonEnabled = UserDefaults.standard.bool(forKey: "isExportButtonEnabled", defaultValue: true)
                
                settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)
                settingsViewController(SettingsViewController(), didChangeAnimatedBackgroundState: isAnimatedBackgroundEnabled)
                settingsViewController(SettingsViewController(), didChangeDynamicBackgroundState: isDynamicBackgroundEnabled)
                settingsViewController(SettingsViewController(), didChangeDynamicThemeState: isDynamicThemeEnabled)
                settingsViewController(SettingsViewController(), didChangeResetSlidersOnTapState: isResetSlidersOnTapEnabled)
                settingsViewController(SettingsViewController(), didChangeTapArtworkToChangeSongState: isTapArtworkToChangeSongEnabled)
                settingsViewController(SettingsViewController(), didChangePrecisePitchState: isAccuratePitchEnabled)
                settingsViewController(SettingsViewController(), didChangeAccurateSpeedState: isAccurateSpeedEnabled)
                settingsViewController(SettingsViewController(), didChangeShowExportButtonState: isExportButtonEnabled)
                
                // Restore slider values after other settings are applied
                let pitch = UserDefaults.standard.float(forKey: "pitchValue")
                pitchSlider.value = pitch
                pitchSliderChanged(pitchSlider)
                
                let speed = UserDefaults.standard.float(forKey: "speedValue")
                speedSlider.value = speed != 0 ? speed : 1.0 // Default to 1.0 if not set
                speedSliderChanged(speedSlider)
                
                let reverb = UserDefaults.standard.float(forKey: "reverbValue")
                reverbSlider.value = reverb
                reverbSliderChanged(reverbSlider)

                // Load the file but don't auto-play
                loadAudioFile(url: url, andPlay: false)
                
                // Restore playback position after the file is loaded
                let lastPosition = UserDefaults.standard.double(forKey: "lastPlaybackPosition")
                if lastPosition > 0 {
                    audioProcessor.seek(to: lastPosition)
                    progressSlider.value = Float(lastPosition)
                    currentTimeLabel.text = formatTime(seconds: lastPosition)
                }
            }
        } catch {
            print("Failed to resolve bookmark data: \(error)")
            clearState()
        }
    }
    
    @objc private func clearState() {
        audioProcessor.togglePlayback() // Stop playback if active
        
        // Clear UserDefaults
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        
        // Reset UI to initial state
        resetControlsState(isHidden: true)
        songTitleLabel.text = "No File Loaded"
        albumArtImageView.image = UIImage(systemName: "music.note")
        artistNameLabel.text = nil
        updateBackground(with: nil)
        print("State cleared and UI reset.")
        audioProcessor.clearNowPlayingInfo() // Clear lock screen info
    }

    // MARK: Progress Tracking
    
    private func setupProgressUpdater() {
        progressUpdateTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(updateProgress), userInfo: nil, repeats: true)
    }
    
    @objc private func updateProgress() {
        guard audioProcessor.isCurrentlyPlaying() else { return }
        
        let currentTime = audioProcessor.getCurrentTime()
        let duration = audioProcessor.getAudioDuration()
        
        progressSlider.value = Float(currentTime)
        currentTimeLabel.text = formatTime(seconds: currentTime)
        audioProcessor.updateNowPlayingInfo(isPaused: false) // Update elapsed time
        
        // If song finishes, update play button icon
        if currentTime >= duration {
            audioProcessor.togglePlayback() // This will set isPlaying to false
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            progressSlider.value = 0 // Reset slider to beginning
            currentTimeLabel.text = formatTime(seconds: 0)
        }
    }
    
    private func formatTime(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    // MARK: Actions

    @objc func togglePlayback() {
        audioProcessor.togglePlayback()
        updatePlayPauseButtonState()
        impactFeedbackGenerator.impactOccurred()
    }
    
    private func updatePlayPauseButtonState() {
        let isPlaying = audioProcessor.isCurrentlyPlaying()
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
        
        // Animate the album art based on playback state
        let targetTransform = isPlaying ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
        
        UIView.animate(withDuration: 0.6,
                       delay: 0,
                       usingSpringWithDamping: 0.6,
                       initialSpringVelocity: 0.8,
                       options: [.allowUserInteraction, .beginFromCurrentState],
                       animations: {
            self.albumArtImageView.transform = targetTransform
        }, completion: nil)
    }
    
    
    @objc func progressSliderScrubbing(_ sender: UISlider) {
        audioProcessor.seek(to: Double(sender.value))
        audioProcessor.updateNowPlayingInfo(isPaused: !audioProcessor.isCurrentlyPlaying())
    }
    
    @objc func openSettings() {
        let settingsVC = SettingsViewController()
        settingsVC.delegate = self
        settingsVC.currentTheme = ThemeManager.shared.currentTheme
        settingsVC.isPitchLinked = !pitchSlider.isEnabled // Pass current state
        settingsVC.isAnimatedBackgroundEnabled = UserDefaults.standard.bool(forKey: "isAnimatedBackgroundEnabled", defaultValue: true)
        settingsVC.isDynamicBackgroundEnabled = UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
        settingsVC.isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
        settingsVC.isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        settingsVC.isResetSlidersOnTapEnabled = UserDefaults.standard.bool(forKey: "isResetSlidersOnTapEnabled")
        settingsVC.isTapArtworkToChangeSongEnabled = UserDefaults.standard.bool(forKey: "isTapArtworkToChangeSongEnabled")
        settingsVC.isAccuratePitchEnabled = self.isAccuratePitchEnabled
        settingsVC.isAccurateSpeedEnabled = self.isAccurateSpeedEnabled
        settingsVC.isExportButtonEnabled = UserDefaults.standard.bool(forKey: "isExportButtonEnabled", defaultValue: true)
        
        // Embed the SettingsViewController in a UINavigationController to display a navigation bar
        let navController = UINavigationController(rootViewController: settingsVC)
        
        // Present as a sheet
        if let sheet = navController.sheetPresentationController {
            sheet.detents = [.medium()]
            impactFeedbackGenerator.impactOccurred()
        }
        present(navController, animated: true)
    }
    
    // MARK: SettingsViewControllerDelegate
    
    func settingsViewController(_ controller: SettingsViewController, didChangeLinkPitchState isEnabled: Bool) {
        pitchSlider.isEnabled = !isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isPitchLinked")
        speedSliderChanged(speedSlider) // Re-apply speed/pitch logic
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicBackgroundState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isDynamicBackgroundEnabled")
        updateBackground(with: albumArtImageView.image, isDynamicEnabled: isEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAnimatedBackgroundState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isAnimatedBackgroundEnabled")
        updateBackgroundAnimation()
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicThemeState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isDynamicThemeEnabled")
        
        // If dynamic theme is enabled, try to apply color from current artwork.
        // Otherwise, apply the saved manual theme.
        applyDynamicTheme(isEnabled: isEnabled, image: albumArtImageView.image)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeReverbSliderState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isReverbSliderEnabled")
        reverbLabel.isHidden = !isEnabled
        reverbSlider.isHidden = !isEnabled
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeResetSlidersOnTapState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isResetSlidersOnTapEnabled")
        setupSliderLabelTapGestures(isEnabled: isEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeTapArtworkToChangeSongState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isTapArtworkToChangeSongEnabled")
        albumArtTapGesture.isEnabled = isEnabled
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangePrecisePitchState isEnabled: Bool) {
        self.isAccuratePitchEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isAccuratePitchEnabled")
        pitchSliderChanged(pitchSlider) // Re-evaluate current pitch value
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAccurateSpeedState isEnabled: Bool) {
        self.isAccurateSpeedEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isAccurateSpeedEnabled")
        speedSliderChanged(speedSlider) // Re-evaluate current speed value
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowExportButtonState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isExportButtonEnabled")
        exportButton.isHidden = !isEnabled
    }
    
    private func updateBackground(with image: UIImage?, isDynamicEnabled: Bool? = nil) {
        let useDynamic = isDynamicEnabled ?? UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
        let shouldShowDynamicBackground = useDynamic && image != nil && image != UIImage(systemName: "music.note") && image != UIImage(systemName: "music.note.list")

        // Always update the image, even if it's about to be faded out
        if image != backgroundImageView.image {
            backgroundImageView.image = image
        }
        
        UIView.animate(withDuration: 0.5) {
            let targetAlpha: CGFloat = shouldShowDynamicBackground ? 1.0 : 0.0
            self.backgroundImageView.alpha = targetAlpha // Only animate the parent view
        }
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeTheme theme: ThemeColor) {
        ThemeManager.shared.currentTheme = theme
        applyTheme(color: theme.uiColor)
    }
    
    private func applyDynamicTheme(isEnabled: Bool, image: UIImage?) {
        if isEnabled {
            if let artwork = image,
               artwork.cgImage != nil, // Ensure it's a real image
               let dominantColor = getDominantColor(from: artwork),
               let vibrantColor = makeVibrant(color: dominantColor) {
                applyTheme(color: vibrantColor)
            } else {
                // Fallback to default theme if no artwork or color can be extracted
                applyTheme(color: ThemeManager.shared.currentTheme.uiColor)
            }
        } else {
            // Dynamic theme is off, use the manually selected theme
            applyTheme(color: ThemeManager.shared.currentTheme.uiColor)
        }
    }
    
    /// Takes a UIColor and returns a brighter, more vibrant version suitable for a theme.
    private func makeVibrant(color: UIColor) -> UIColor? {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return nil
        }

        // Increase brightness to make it stand out, but cap at 1.0
        // Also ensure a minimum brightness to avoid very dark, unusable colors.
        brightness = max(min(brightness * 1.8, 1.0), 0.7)
        
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
    
    /// Extracts the dominant color from an image by scaling it down to 1x1 and sampling the pixel.
    private func getDominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let width = 1
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData: [UInt8] = [0, 0, 0, 0]

        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return UIColor(red: CGFloat(pixelData[0]) / 255.0, green: CGFloat(pixelData[1]) / 255.0, blue: CGFloat(pixelData[2]) / 255.0, alpha: 1.0)
    }
    @objc func pitchSliderChanged(_ sender: UISlider) {
        let pitchInCents = sender.value
        
        var finalPitch = pitchInCents
        
        if isAccuratePitchEnabled {
            let roundedPitch = (pitchInCents / 100.0).rounded() * 100.0
            
            if roundedPitch != lastSnappedPitchValue {
                selectionFeedbackGenerator.selectionChanged()
                lastSnappedPitchValue = roundedPitch
            }
            
            sender.value = roundedPitch // Snap the slider's visual position
            finalPitch = roundedPitch
        }
        audioProcessor.setPitch(pitch: finalPitch)
        UserDefaults.standard.set(pitchInCents, forKey: "pitchValue")
        let semitones = Int((pitchInCents / 100.0).rounded())
        pitchLabel.text = String(format: "Pitch (%d st)", semitones)
    }
    
    private func setupSliderLabelTapGestures(isEnabled: Bool) {
        // Remove any existing gestures to avoid duplicates
        pitchLabel.gestureRecognizers?.forEach(pitchLabel.removeGestureRecognizer)
        speedLabel.gestureRecognizers?.forEach(speedLabel.removeGestureRecognizer)
        reverbLabel.gestureRecognizers?.forEach(reverbLabel.removeGestureRecognizer)
        
        pitchLabel.isUserInteractionEnabled = isEnabled
        speedLabel.isUserInteractionEnabled = isEnabled
        reverbLabel.isUserInteractionEnabled = isEnabled
        
        if isEnabled {
            let pitchTap = UITapGestureRecognizer(target: self, action: #selector(resetPitchSlider))
            pitchTap.numberOfTapsRequired = 2
            pitchLabel.addGestureRecognizer(pitchTap)

            let speedTap = UITapGestureRecognizer(target: self, action: #selector(resetSpeedSlider))
            speedTap.numberOfTapsRequired = 2
            speedLabel.addGestureRecognizer(speedTap)

            let reverbTap = UITapGestureRecognizer(target: self, action: #selector(resetReverbSlider))
            reverbTap.numberOfTapsRequired = 2
            reverbLabel.addGestureRecognizer(reverbTap)
        }
    }
    
    @objc func speedSliderChanged(_ sender: UISlider) {
        let rawRate = sender.value // The actual slider position
        UserDefaults.standard.set(rawRate, forKey: "speedValue")

        var finalRate = rawRate
        if isAccurateSpeedEnabled {
            // Snap to 0.05 increments (e.g., 0.50, 0.55, 0.60...)
            let roundedRate = (rawRate * 20).rounded() / 20
            
            if roundedRate != lastSnappedSpeedValue {
                selectionFeedbackGenerator.selectionChanged()
                lastSnappedSpeedValue = roundedRate
            }
            sender.value = roundedRate // Snap the slider's visual position
            finalRate = roundedRate
        }

        speedLabel.text = String(format: "Speed (%.2fx)", finalRate) // Display the potentially snapped value
        
        // Check if the pitch slider is disabled, which means linking is ON
        if !pitchSlider.isEnabled {
            // Calculate pitch from the raw (continuous) rate for smooth linking
            let pitchInCents = 1200 * log2(rawRate)
            audioProcessor.setPlaybackRate(rate: finalRate, linkedPitch: pitchInCents)
            pitchSlider.value = pitchInCents // This will trigger pitchSliderChanged
        } else {
            audioProcessor.setPlaybackRate(rate: finalRate, linkedPitch: nil)
        }
    }
    
    @objc func reverbSliderChanged(_ sender: UISlider) {
        let mix = sender.value
        audioProcessor.setReverbMix(mix: mix)
        UserDefaults.standard.set(mix, forKey: "reverbValue")
        reverbLabel.text = String(format: "Reverb (%d%%)", Int(mix.rounded()))
    }

    // MARK: File Picker Logic

    @objc func openFilePicker() {
        // Define the types of files we want to allow the user to select.
        let supportedTypes: [UTType] = [.mp3]
        
        // Use 'asCopy: true' to ensure the file is copied into the app's sandbox
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        
        picker.delegate = self
        picker.allowsMultipleSelection = false
        
        impactFeedbackGenerator.impactOccurred()
        present(picker, animated: true, completion: nil)
    }

    // MARK: UIDocumentPickerDelegate Methods

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        // Save a bookmark to the file URL for persistence
        do {
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "lastAudioFileBookmark")
        } catch {
            print("Failed to save bookmark data: \(error)")
        }
        
        loadAudioFile(url: url, andPlay: true)
    }
    
    private func loadAudioFile(url: URL, andPlay: Bool) {
        // Load the audio file and get its metadata
        if let metadata = audioProcessor.loadAudioFile(url: url) {
            // Update UI with file information
            songTitleLabel.text = metadata.title
            artistNameLabel.text = metadata.artist
            artistNameLabel.isHidden = metadata.artist == nil
            
            let newImage: UIImage

            if let artwork = metadata.artwork {
                newImage = artwork.cgImage != nil ? artwork : UIImage(systemName: "music.note.list")!
            } else {
                newImage = UIImage(systemName: "music.note.list")!
            }
            UIView.transition(with: self.albumArtImageView,
                              duration: 0.4,
                              options: .transitionCrossDissolve,
                              animations: { self.albumArtImageView.image = newImage },
                              completion: nil)
            // Update dynamic background
            let isDynamicEnabled = UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
            updateBackground(with: metadata.artwork, isDynamicEnabled: isDynamicEnabled)
            
            // Update dynamic theme
            let isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
            applyDynamicTheme(isEnabled: isDynamicThemeEnabled, image: metadata.artwork)
            
            // Reset and show controls
            resetControlsState(isHidden: false)
            resetButton.isHidden = false
            exportButton.isHidden = !UserDefaults.standard.bool(forKey: "isExportButtonEnabled", defaultValue: true)

            // Re-apply reverb slider visibility based on user settings
            let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
            settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)

            // Update progress slider and labels for the new song
            let duration = audioProcessor.getAudioDuration()
            progressSlider.maximumValue = Float(duration)
            durationLabel.text = formatTime(seconds: duration)
            
            audioProcessor.updateNowPlayingInfo(isPaused: true)
            if andPlay {
                // Automatically start playing
                togglePlayback()
            } else {
                // If not playing, update the button state (and album art size)
                updatePlayPauseButtonState()
            }
        } else {
            // Handle error (e.g., failed to load)
            songTitleLabel.text = "Error Loading File"
            resetControlsState(isHidden: true)
            updateBackground(with: nil)
            audioProcessor.clearNowPlayingInfo() // Clear lock screen info
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        print("File picking was cancelled.")
    }

    // MARK: New Rewind/Skip Actions
    @objc private func rewind10Seconds() {
        let currentTime = audioProcessor.getCurrentTime()
        let newTime = max(0, currentTime - 10)
        audioProcessor.seek(to: newTime)
        progressSlider.value = Float(newTime)
        currentTimeLabel.text = formatTime(seconds: newTime)
        impactFeedbackGenerator.impactOccurred()
        audioProcessor.updateNowPlayingInfo(isPaused: !audioProcessor.isCurrentlyPlaying())
    }

    @objc private func skip10Seconds() {
        let currentTime = audioProcessor.getCurrentTime()
        let duration = audioProcessor.getAudioDuration()
        impactFeedbackGenerator.impactOccurred()
        let newTime = min(duration, currentTime + 10)
        audioProcessor.seek(to: newTime)
        progressSlider.value = Float(newTime)
        currentTimeLabel.text = formatTime(seconds: newTime)
        audioProcessor.updateNowPlayingInfo(isPaused: !audioProcessor.isCurrentlyPlaying())
    }
    
    // MARK: Export Action
    
    @objc private func exportTapped() {
        let alert = UIAlertController(title: "Export Audio", message: "This will export the current track with all applied effects. This may take a moment.", preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        alert.addAction(UIAlertAction(title: "Export", style: .default, handler: { [weak self] _ in
            self?.startExportProcess()
        }))
        
        present(alert, animated: true)
    }
    
    private func startExportProcess() {
        // Show a loading indicator
        let activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.center = view.center
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)
        view.isUserInteractionEnabled = false // Prevent user interaction during export
        
        audioProcessor.exportAudio { [weak self] result in
            DispatchQueue.main.async {
                // Hide loading indicator
                activityIndicator.stopAnimating()
                activityIndicator.removeFromSuperview()
                self?.view.isUserInteractionEnabled = true
                
                switch result {
                case .success(let url):
                    // Present the share sheet
                    let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    self?.present(activityVC, animated: true, completion: nil)
                    
                case .failure(let error):
                    // Show an error alert
                    let errorAlert = UIAlertController(title: "Export Failed", message: error.localizedDescription, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self?.present(errorAlert, animated: true)
                }
            }
        }
    }
}

// Helper extension to provide a default value for bool(forKey:)
extension UserDefaults {
    func bool(forKey defaultName: String, defaultValue: Bool) -> Bool {
        if object(forKey: defaultName) == nil {
            return defaultValue
        }
        return bool(forKey: defaultName)
    }
}
// MARK: - 3. SwiftUI Preview and App Entry Point

/// Wraps the UIKit ViewController for display in the SwiftUI Canvas Preview.
struct AudioEffectsAppPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AudioEffectsViewController {
        return AudioEffectsViewController()
    }
    
    func updateUIViewController(_ uiViewController: AudioEffectsViewController, context: Context) {
        // No updates needed
    }
}

// Replaced the old PreviewProvider with the correct @main App structure.
@main
struct AudioEffectsApp: App {
    init() {
        // Register default values for app settings.
        // This ensures that on the first launch, these features are enabled.
        UserDefaults.standard.register(defaults: [
            "isDynamicBackgroundEnabled": true,
            "isAnimatedBackgroundEnabled": true,
            "isDynamicThemeEnabled": true,
            "isReverbSliderEnabled": true,
            "isResetSlidersOnTapEnabled": true,
            "isTapArtworkToChangeSongEnabled": true,
            "isAccuratePitchEnabled": false,
            "isAccurateSpeedEnabled": false,
            "isExportButtonEnabled": true
        ])
    }
    var body: some Scene {
        WindowGroup {
            AudioEffectsAppPreview().ignoresSafeArea()
        }
    }
}

#Preview {
    AudioEffectsAppPreview()
}
