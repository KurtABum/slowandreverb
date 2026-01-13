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
    private let varispeedNode = AVAudioUnitVarispeed() // High quality speed/pitch linking
    private var isVarispeedEnabled = false
    private let reverbNode = AVAudioUnitReverb()       // Applies environmental effects
    private let equalizerNode = AVAudioUnitEQ(numberOfBands: 3) // For Bass, Mids, Treble
    private var isPitchCorrectionEnabled = true
    private var needsReschedule = false
    private var isExporting = false // Flag to prevent concurrent exports
    
    private var audioFile: AVAudioFile?
    private var currentTitle: String?
    private var isPlaying = false
    
    // Properties for progress tracking
    private var audioFileLength: AVAudioFramePosition = 0
    private var audioSampleRate: Double = 0
    private var lastPlaybackPosition: AVAudioFramePosition = 0
    private var pausedPosition: AVAudioFramePosition? // Tracks position when paused
    
    // Property to hold the static Now Playing info
    private var nowPlayingInfo: [String: Any]?
    
    // Closure to notify the UI of external playback changes (e.g., from remote commands)
    var onPlaybackStateChanged: (() -> Void)?
    
    // Closures for playlist navigation from remote commands
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?

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
        engine.attach(varispeedNode)
        engine.attach(equalizerNode)
        engine.attach(reverbNode)

        // The audio format for the connection points must be consistent.
        let commonFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        connectNodes(format: commonFormat)

        // Initial setup for effects
        reverbNode.loadFactoryPreset(.mediumHall)
        reverbNode.wetDryMix = 0.0 // 0% wet (no reverb initially)
        timePitchNode.rate = 1.0   // Normal speed initially
        
        // Initial setup for equalizer bands
        // Band 0: Bass (Low Shelf)
        equalizerNode.bands[0].filterType = .lowShelf
        equalizerNode.bands[0].frequency = 250.0 // Hz
        equalizerNode.bands[0].gain = 0.0 // dB
        equalizerNode.bands[0].bypass = false
        // Band 1: Mids (Parametric)
        equalizerNode.bands[1].filterType = .parametric
        equalizerNode.bands[1].frequency = 1000.0 // Hz
        equalizerNode.bands[1].bandwidth = 1.0 // Octaves
        equalizerNode.bands[1].gain = 0.0 // dB
        equalizerNode.bands[1].bypass = false
        // Band 2: Treble (High Shelf)
        equalizerNode.bands[2].filterType = .highShelf
        equalizerNode.bands[2].frequency = 4000.0 // Hz
        equalizerNode.bands[2].gain = 0.0 // dB
        equalizerNode.bands[2].bypass = false

        do {
            try engine.start()
        } catch {
            print("Error starting AVAudioEngine: \(error.localizedDescription)")
        }
    }
    
    /// Connects the audio nodes based on the current mode (TimePitch or Varispeed).
    private func connectNodes(format: AVAudioFormat) {
        // Disconnect inputs to ensure clean reconfiguration
        engine.disconnectNodeInput(equalizerNode)
        
        if isVarispeedEnabled {
            engine.connect(playerNode, to: varispeedNode, format: format)
            engine.connect(varispeedNode, to: equalizerNode, format: format)
        } else {
            engine.connect(playerNode, to: timePitchNode, format: format)
            engine.connect(timePitchNode, to: equalizerNode, format: format)
        }
        
        engine.connect(equalizerNode, to: reverbNode, format: format)
        engine.connect(reverbNode, to: engine.mainMixerNode, format: format)
    }
    
    // MARK: File Loading and Playback

    /// Loads an audio file and extracts its metadata.
    func loadAudioFile(url: URL) -> (title: String, artist: String?, artwork: UIImage?)? {
        // Stop current playback and reset engine
        playerNode.stop()
        engine.stop()
        isPlaying = false
        
        do {
            self.audioFile = try AVAudioFile(forReading: url)
            guard let file = self.audioFile else { return nil }
            
            self.audioFileLength = file.length
            self.audioSampleRate = file.processingFormat.sampleRate
            self.lastPlaybackPosition = 0 // Reset position for new file
            self.pausedPosition = nil
            
            // Reconnect nodes with the audio file's processing format to ensure effects work correctly.
            let fileFormat = file.processingFormat
            // New chain: Player -> Time/Pitch -> EQ -> Reverb -> Output
            connectNodes(format: fileFormat)
            
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
            self.currentTitle = title
            
            print("Audio file loaded: \(title)")
            return (title: title, artist: artistName, artwork: artworkImage)
            
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
            self.audioFile = nil
            self.nowPlayingInfo = nil // Clear info on failure
            self.currentTitle = nil
            return nil
        }
    }
    
    /// Starts or stops the playback and handles file rescheduling for looping.
    func togglePlayback() {
        guard audioFile != nil else {
            print("No audio file loaded.")
            return
        }

        if isPlaying {
            pausedPosition = getCurrentFramePosition() // Capture position before pausing
            playerNode.pause()
            isPlaying = false
            print("Playback paused.")
        } else {
            // Activate audio session to ensure playback can resume (especially for Bluetooth/Control Center)
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Failed to activate audio session: \(error.localizedDescription)")
            }

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
                pausedPosition = nil
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
            pausedPosition = nil // Clear paused position on resume
            playerNode.play()
            isPlaying = true
            print("Playback started/resumed.")
        }
        updateNowPlayingInfo(isPaused: !isPlaying)
    }
    
    /// Pauses playback explicitly.
    func pause() {
        if playerNode.isPlaying {
            pausedPosition = getCurrentFramePosition() // Capture position before pausing
            playerNode.pause()
        }
        isPlaying = false
        print("Playback paused.")
        updateNowPlayingInfo(isPaused: true)
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
        pausedPosition = startingFrame // Update paused position so UI shows correct time if paused
        needsReschedule = false

        playerNode.scheduleSegment(audioFile, startingFrame: startingFrame, frameCount: frameCount, at: nil) { [weak self] in
            self?.needsReschedule = true
        }

        if wasPlaying {
            pausedPosition = nil
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
        if let paused = pausedPosition, !isPlaying {
            return Double(paused) / audioSampleRate
        }
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

        // Enable commands explicitly
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true

        // Add handler for Play Command
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if self.isCurrentlyPlaying() { return .success }
            
            // Execute synchronously on main thread to ensure state is updated before returning .success
            if Thread.isMainThread {
                self.togglePlayback()
                self.onPlaybackStateChanged?()
            } else {
                DispatchQueue.main.sync {
                    self.togglePlayback()
                    self.onPlaybackStateChanged?()
                }
            }
            return .success
        }

        // Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if !self.isCurrentlyPlaying() { return .success }
            
            if Thread.isMainThread {
                self.togglePlayback()
                self.onPlaybackStateChanged?()
            } else {
                DispatchQueue.main.sync {
                    self.togglePlayback()
                    self.onPlaybackStateChanged?()
                }
            }
            return .success
        }
        
        // Add handler for Toggle Play/Pause Command
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            if Thread.isMainThread {
                self.togglePlayback()
                self.onPlaybackStateChanged?()
            } else {
                DispatchQueue.main.sync {
                    self.togglePlayback()
                    self.onPlaybackStateChanged?()
                }
            }
            return .success
        }
        
        // Add handler for seek/scrub
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            self.onPlaybackStateChanged?()
            return .success
        }
        
        // Add handlers for Next/Previous Track
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            self.onNextTrack?()
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            self.onPreviousTrack?()
            return .success
        }
        
        // Initially disable them; they will be enabled by the view controller
        updatePlaylistRemoteCommands(isEnabled: false)
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : (isVarispeedEnabled ? varispeedNode.rate : timePitchNode.rate)

        // Set the updated information.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    /// Enables or disables the remote commands for playlist navigation.
    func updatePlaylistRemoteCommands(isEnabled: Bool) {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = isEnabled
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = isEnabled
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
                pausedPosition = getCurrentFramePosition()
                playerNode.pause()
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
        if isVarispeedEnabled {
            varispeedNode.rate = rate
        } else {
            timePitchNode.rate = rate
            // If a linked pitch value is provided, use it.
            if let pitch = linkedPitch {
                timePitchNode.pitch = pitch
            }
        }
        updateNowPlayingInfo(isPaused: !isPlaying)
    }
    
    /// Enables or disables Varispeed mode (High Quality Link Pitch & Speed).
    func setVarispeedEnabled(_ enabled: Bool) {
        guard isVarispeedEnabled != enabled else { return }
        isVarispeedEnabled = enabled
        
        // Stop playback and reset engine
        playerNode.stop()
        engine.stop()
        isPlaying = false
        
        if let file = audioFile {
            connectNodes(format: file.processingFormat)
            // Reschedule the file
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
        } else {
            let commonFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            connectNodes(format: commonFormat)
        }
        
        do {
            try engine.start()
        } catch {
            print("Error restarting AVAudioEngine: \(error.localizedDescription)")
        }
        
        lastPlaybackPosition = 0
        pausedPosition = nil
        updateNowPlayingInfo(isPaused: true)
    }
    
    /// Adjusts the song's pitch.
    /// - Parameter pitch: The new pitch in cents (-1200 to 1200).
    func setPitch(pitch: Float) {
        // When pitch correction is on, changing the pitch slider should not
        // be affected by the rate's automatic pitch shift. The `pitch` property
        // is an independent adjustment.
        if !isVarispeedEnabled {
            timePitchNode.pitch = pitch
        }
    }
    
    /// Adjusts the amount of reverb applied to the song.
    /// - Parameter mix: The wet/dry mix percentage (0.0 to 100.0).
    func setReverbMix(mix: Float) {
        reverbNode.wetDryMix = mix
    }
    
    /// Adjusts the gain of the bass frequencies.
    /// - Parameter gain: The gain in decibels (-12 to +12).
    func setBassGain(gain: Float) {
        equalizerNode.bands[0].gain = gain
    }
    /// Adjusts the gain of the mid-range frequencies.
    /// - Parameter gain: The gain in decibels (-12 to +12).
    func setMidsGain(gain: Float) {
        equalizerNode.bands[1].gain = gain
    }
    /// Adjusts the gain of the treble frequencies.
    /// - Parameter gain: The gain in decibels (-12 to +12).
    func setTrebleGain(gain: Float) {
        equalizerNode.bands[2].gain = gain
    }
    
    // MARK: Audio Export

    /// Exports the currently loaded audio file with the applied effects to a temporary file.
    /// - Parameters:
    ///   - completion: A closure called when the export is complete, returning the URL of the exported file or an error.
    func exportAudio(bitrate: Int, progress: ((Float) -> Void)? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
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
        playerNode.stop()
        engine.stop()

        do {
            let maxFrames: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(.offline, format: sourceFile.processingFormat, maximumFrameCount: maxFrames)
            
            // Create a temporary file URL for the output
            // Construct filename: [Song Name] [Speed] [Pitch] [Reverb].m4a
            let name = self.currentTitle ?? "Exported"
            var filenameComponents = [name]
            
            let currentRate = isVarispeedEnabled ? varispeedNode.rate : timePitchNode.rate
            if abs(currentRate - 1.0) > 0.01 {
                filenameComponents.append(String(format: "Speed %.2fx", currentRate))
            }
            
            if !isVarispeedEnabled {
                let pitchSemitones = Int((timePitchNode.pitch / 100.0).rounded())
                if pitchSemitones != 0 {
                    filenameComponents.append(String(format: "Pitch %dst", pitchSemitones))
                }
            } else {
                filenameComponents.append("HQ")
            }
            
            let reverbAmount = Int(reverbNode.wetDryMix.rounded())
            if reverbAmount > 0 {
                filenameComponents.append(String(format: "Reverb %d%%", reverbAmount))
            }
            
            let fileName = filenameComponents.joined(separator: " ")
            let safeName = fileName.replacingOccurrences(of: "/", with: "_")
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).m4a")
            
            // Define AAC settings
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFile.processingFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFile.processingFormat.channelCount,
                AVEncoderBitRateKey: bitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
            
            // Create the output file using the AAC settings.
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: settings)
            
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
                    let p = Float(engine.manualRenderingSampleTime) / Float(sourceFile.length)
                    progress?(p)
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
            
            // Restart engine for future playback
            try engine.start()
            
            // Reset playback to beginning and pause
            lastPlaybackPosition = 0
            pausedPosition = nil
            isPlaying = false
            
            isExporting = false
            completion(.success(outputURL))
            
        } catch {
            // Ensure we clean up on error
            isExporting = false
            engine.stop()
            engine.disableManualRenderingMode()
            
            // Attempt to restore engine state
            try? engine.start()
            playerNode.scheduleFile(sourceFile, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            
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
    func settingsViewController(_ controller: SettingsViewController, didChangeShowAlbumArtState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowExportButtonState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowEQState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangePlaylistModeState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeLoopingState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeRememberSettingsState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAutoPlayNextState isEnabled: Bool)
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
    var isEQEnabled: Bool = false
    var isAlbumArtVisible: Bool = true
    var isPlaylistModeEnabled: Bool = false
    var isLoopingEnabled: Bool = false
    var isRememberSettingsEnabled: Bool = false
    var isAutoPlayNextEnabled: Bool = false
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
    
    private let eqSwitch = UISwitch()
    private let eqLabel = UILabel()

    private let albumArtSwitch = UISwitch()
    private let albumArtLabel = UILabel()
    
    private let playlistModeSwitch = UISwitch()
    private let playlistModeLabel = UILabel()
    
    private let loopingSwitch = UISwitch()
    private let loopingLabel = UILabel()
    
    private let rememberSettingsSwitch = UISwitch()
    private let rememberSettingsLabel = UILabel()
    
    private let autoPlayNextSwitch = UISwitch()
    private let autoPlayNextLabel = UILabel()
    private var autoPlayNextGroup: UIStackView!
    
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
        scrollView.showsVerticalScrollIndicator = false
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
        
        // --- EQ Setting ---
        eqLabel.text = "Show Equalizer"
        eqSwitch.isOn = isEQEnabled
        eqSwitch.addTarget(self, action: #selector(eqSwitchChanged), for: .valueChanged)
        let eqStack = UIStackView(arrangedSubviews: [eqLabel, eqSwitch])
        eqStack.spacing = 20
        let eqDescription = createDescriptionLabel(with: "Shows sliders for Bass, Mids, and Treble control.")
        let eqGroup = UIStackView(arrangedSubviews: [eqStack, eqDescription])
        eqGroup.axis = .vertical
        eqGroup.spacing = 4
        
        // --- Show Album Art Setting ---
        albumArtLabel.text = "Show Album Art"
        albumArtSwitch.isOn = isAlbumArtVisible
        albumArtSwitch.addTarget(self, action: #selector(albumArtSwitchChanged), for: .valueChanged)
        let albumArtStack = UIStackView(arrangedSubviews: [albumArtLabel, albumArtSwitch])
        albumArtStack.spacing = 20
        let albumArtDescription = createDescriptionLabel(with: "Shows or hides the album artwork on the main screen. The dynamic background is not affected.")
        let albumArtGroup = UIStackView(arrangedSubviews: [albumArtStack, albumArtDescription])
        albumArtGroup.axis = .vertical
        albumArtGroup.spacing = 4

        // --- Playlist Mode Setting ---
        playlistModeLabel.text = "Playlist Mode"
        playlistModeSwitch.isOn = isPlaylistModeEnabled
        playlistModeSwitch.addTarget(self, action: #selector(playlistModeSwitchChanged), for: .valueChanged)
        let playlistModeStack = UIStackView(arrangedSubviews: [playlistModeLabel, playlistModeSwitch])
        playlistModeStack.spacing = 20
        let playlistModeDescription = createDescriptionLabel(with: "Select a folder to create a playlist of all its songs. A dropdown will appear to switch between them.")
        let playlistModeGroup = UIStackView(arrangedSubviews: [playlistModeStack, playlistModeDescription])
        playlistModeGroup.axis = .vertical
        playlistModeGroup.spacing = 4
        
        // --- Auto-Play Next Setting ---
        autoPlayNextLabel.text = "Auto-Play Next"
        autoPlayNextSwitch.isOn = isAutoPlayNextEnabled
        autoPlayNextSwitch.addTarget(self, action: #selector(autoPlayNextSwitchChanged), for: .valueChanged)
        let autoPlayNextStack = UIStackView(arrangedSubviews: [autoPlayNextLabel, autoPlayNextSwitch])
        autoPlayNextStack.spacing = 20
        let autoPlayNextDescription = createDescriptionLabel(with: "Automatically plays the next song in the folder when the current one finishes.")
        autoPlayNextGroup = UIStackView(arrangedSubviews: [autoPlayNextStack, autoPlayNextDescription])
        autoPlayNextGroup.axis = .vertical
        autoPlayNextGroup.spacing = 4
        autoPlayNextGroup.isHidden = !isPlaylistModeEnabled
        
        // --- Repeat Song Setting ---
        loopingLabel.text = "Repeat Song"
        loopingSwitch.isOn = isLoopingEnabled
        loopingSwitch.addTarget(self, action: #selector(loopingSwitchChanged), for: .valueChanged)
        let loopingStack = UIStackView(arrangedSubviews: [loopingLabel, loopingSwitch])
        loopingStack.spacing = 20
        let loopingDescription = createDescriptionLabel(with: "Automatically restarts the song when it finishes.")
        let loopingGroup = UIStackView(arrangedSubviews: [loopingStack, loopingDescription])
        loopingGroup.axis = .vertical
        loopingGroup.spacing = 4
        
        // --- Remember Settings Setting ---
        rememberSettingsLabel.text = "Remember Settings"
        rememberSettingsSwitch.isOn = isRememberSettingsEnabled
        rememberSettingsSwitch.addTarget(self, action: #selector(rememberSettingsSwitchChanged), for: .valueChanged)
        let rememberSettingsStack = UIStackView(arrangedSubviews: [rememberSettingsLabel, rememberSettingsSwitch])
        rememberSettingsStack.spacing = 20
        let rememberSettingsDescription = createDescriptionLabel(with: "Keeps the current pitch, speed, and reverb settings when loading a new song.")
        let rememberSettingsGroup = UIStackView(arrangedSubviews: [rememberSettingsStack, rememberSettingsDescription])
        rememberSettingsGroup.axis = .vertical
        rememberSettingsGroup.spacing = 4

        // --- Main Settings Stack ---
        let settingsOptionsStack = UIStackView(arrangedSubviews: [
            linkPitchGroup,
            dynamicThemeGroup,
            eqGroup,
            playlistModeGroup,
            autoPlayNextGroup,
            loopingGroup,
            rememberSettingsGroup,
            reverbSliderGroup,
            resetSlidersOnTapGroup, // Corrected spacing
            albumArtGroup,
            tapArtworkGroup
        ])
        settingsOptionsStack.axis = .vertical // Corrected spacing
        settingsOptionsStack.addArrangedSubview(dynamicBackgroundGroup) // Re-added dynamic background
        settingsOptionsStack.addArrangedSubview(animatedBackgroundGroup)
        settingsOptionsStack.insertArrangedSubview(exportButtonGroup, at: 3)
        settingsOptionsStack.insertArrangedSubview(preciseSpeedGroup, at: 5) // Insert precise speed after precise pitch
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
        let alert = UIAlertController(title: "Change Audio Engine", message: "Changing this setting requires restarting the audio engine. Playback will stop and reset to the beginning.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            sender.setOn(!sender.isOn, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Continue", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.settingsViewController(self, didChangeLinkPitchState: sender.isOn)
            self.impactFeedbackGenerator.impactOccurred()
        }))
        
        present(alert, animated: true)
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
    
    @objc private func eqSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowEQState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func albumArtSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowAlbumArtState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func playlistModeSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangePlaylistModeState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
        
        // Toggle visibility of Auto-Play Next
        UIView.animate(withDuration: 0.3) {
            self.autoPlayNextGroup.isHidden = !sender.isOn
        }
    }
    
    @objc private func loopingSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeLoopingState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func rememberSettingsSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeRememberSettingsState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func autoPlayNextSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeAutoPlayNextState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
}

// MARK: - Playlist View Controller

/// Protocol to delegate song selection from the playlist view back to the main view controller.
protocol PlaylistViewControllerDelegate: AnyObject {
    func playlistViewController(_ controller: PlaylistViewController, didSelectSongAt url: URL)
}

/// Sorting options for the playlist.
private enum PlaylistSortOption: Int, CaseIterable {
    case title, artist, album

    var description: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        }
    }
}

/// A view controller that displays the list of songs in the current playlist.
class PlaylistViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    weak var delegate: PlaylistViewControllerDelegate?
    var playlistURLs: [URL] = []
    var currentAudioURL: URL?
    
    private let tableView = UITableView()
    private var songMetadataList: [(url: URL, title: String, artist: String?, album: String?, artwork: UIImage?)] = []
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    
    private let sortControl = UISegmentedControl(items: PlaylistSortOption.allCases.map { $0.description })
    private let sortOptionKey = "playlistSortOption"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadAllSongMetadata()
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        // Setup Sort Control in Navigation Bar
        let savedSortIndex = UserDefaults.standard.integer(forKey: sortOptionKey)
        sortControl.selectedSegmentIndex = savedSortIndex
        sortControl.addTarget(self, action: #selector(sortOptionChanged), for: .valueChanged)
        navigationItem.titleView = sortControl
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(dismissView))
        
        navigationController?.navigationBar.prefersLargeTitles = false // Use standard title bar for sort control

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongTableViewCell.self, forCellReuseIdentifier: SongTableViewCell.reuseIdentifier)
        tableView.rowHeight = 60
        view.addSubview(tableView)
        
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    @objc private func dismissView() {
        dismiss(animated: true)
    }
    
    @objc private func sortOptionChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: sortOptionKey)
        sortMetadataList()
        tableView.reloadData()
    }
    
    private func loadAllSongMetadata() {
        activityIndicator.startAnimating()
        tableView.isHidden = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let localMetadataList = self.playlistURLs.map { url -> (url: URL, title: String, artist: String?, album: String?, artwork: UIImage?) in
                let asset = AVAsset(url: url)
                let title = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue ?? url.deletingPathExtension().lastPathComponent
                let artist = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue
                let album = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyAlbumName })?.stringValue // Corrected key
                var artwork: UIImage? = nil
                if let artworkItem = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }), let imageData = artworkItem.dataValue {
                    artwork = UIImage(data: imageData)
                }
                return (url, title, artist, album, artwork)
            }
            
            DispatchQueue.main.async {
                self.songMetadataList = localMetadataList
                self.sortMetadataList()
                self.activityIndicator.stopAnimating()
                self.tableView.isHidden = false
                self.tableView.reloadData()
            }
        }
    }
    
    private func sortMetadataList() {
        guard let sortOption = PlaylistSortOption(rawValue: sortControl.selectedSegmentIndex) else { return }
        
        songMetadataList.sort { (song1, song2) in
            switch sortOption {
            case .title:
                return song1.title.localizedCaseInsensitiveCompare(song2.title) == .orderedAscending
            case .artist:
                return (song1.artist ?? "").localizedCaseInsensitiveCompare(song2.artist ?? "") == .orderedAscending
            case .album:
                // Sort by album, then by title within the album
                let albumComparison = (song1.album ?? "").localizedCaseInsensitiveCompare(song2.album ?? "")
                return albumComparison == .orderedSame ? song1.title.localizedCaseInsensitiveCompare(song2.title) == .orderedAscending : albumComparison == .orderedAscending
            }
        }
    }
    
    // MARK: - UITableViewDataSource
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return songMetadataList.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SongTableViewCell.reuseIdentifier, for: indexPath) as? SongTableViewCell else {
            return UITableViewCell()
        }
        let metadata = songMetadataList[indexPath.row]
        cell.configure(with: metadata.artwork, title: metadata.title, artist: metadata.artist)
        
        // Highlight the currently playing song
        if metadata.url == currentAudioURL {
            cell.accessoryType = .checkmark
            cell.tintColor = view.tintColor
        } else {
            cell.accessoryType = .none
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selectedURL = songMetadataList[indexPath.row].url
        delegate?.playlistViewController(self, didSelectSongAt: selectedURL)
        dismiss(animated: true)
    }
}

/// A custom table view cell to display song information.
class SongTableViewCell: UITableViewCell {
    static let reuseIdentifier = "SongTableViewCell"
    
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCellUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupCellUI() {
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = 4
        artworkImageView.clipsToBounds = true
        artworkImageView.backgroundColor = .secondarySystemBackground
        contentView.addSubview(artworkImageView)
        
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        artistLabel.font = .systemFont(ofSize: 14)
        artistLabel.textColor = .secondaryLabel
        
        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        contentView.addSubview(textStack)
        
        NSLayoutConstraint.activate([
            artworkImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artworkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 44),
            artworkImageView.heightAnchor.constraint(equalToConstant: 44),
            
            textStack.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    
    func configure(with artwork: UIImage?, title: String, artist: String?) {
        titleLabel.text = title
        artistLabel.text = artist
        artistLabel.isHidden = artist == nil
        artworkImageView.image = artwork ?? UIImage(systemName: "music.note")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        artworkImageView.image = nil
        titleLabel.text = nil
        artistLabel.text = nil
        accessoryType = .none
    }
}

// MARK: - 2. User Interface and File Picker

class AudioEffectsViewController: UIViewController, UIDocumentPickerDelegate, SettingsViewControllerDelegate, PlaylistViewControllerDelegate {

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
    
    private let playlistButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private var progressUpdateTimer: Timer?
    
    private let pitchLabel = UILabel()
    private let pitchSlider = UISlider()
    private var pitchControlStack: UIStackView!
    
    private let speedLabel = UILabel()
    private let speedSlider = UISlider()
    
    private let reverbLabel = UILabel()
    private let reverbSlider = UISlider()
    
    // EQ Components
    private let bassLabel = UILabel()
    private let bassSlider = UISlider()
    
    private let midsLabel = UILabel()
    private let midsSlider = UISlider()
    
    private let trebleLabel = UILabel()
    private let trebleSlider = UISlider()
    
    private let resetButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    
    // New buttons for rewind and skip
    private let rewindButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    
    // New buttons for playlist navigation
    private let previousTrackButton = UIButton(type: .system)
    private let nextTrackButton = UIButton(type: .system)
    
    // Scroll View for main content
    private let scrollView = UIScrollView()
    
    // Gesture Recognizers
    private let albumArtTapGesture = UITapGestureRecognizer()
    
    // Settings state
    private var isAccuratePitchEnabled = false
    private var isAccurateSpeedEnabled = false
    private var lastSnappedPitchValue: Float = 0.0 // To track discrete pitch changes for haptics
    private var lastSnappedSpeedValue: Float = 1.0 // To track discrete speed changes for haptics
    private var isLoopingEnabled = false
    private var isRememberSettingsEnabled = false
    private var isAutoPlayNextEnabled = false
    
    // Playlist state
    private var playlistURLs: [URL] = []
    private var currentAudioURL: URL?
    
    // MARK: View Lifecycle
    
    private var hasLoadedInitialState = false

    override func viewDidLoad() {
        self.isAccurateSpeedEnabled = UserDefaults.standard.bool(forKey: "isAccurateSpeedEnabled")
        self.isAccuratePitchEnabled = UserDefaults.standard.bool(forKey: "isAccuratePitchEnabled")
        self.isLoopingEnabled = UserDefaults.standard.bool(forKey: "isLoopingEnabled")
        self.isRememberSettingsEnabled = UserDefaults.standard.bool(forKey: "isRememberSettingsEnabled")
        self.isAutoPlayNextEnabled = UserDefaults.standard.bool(forKey: "isAutoPlayNextEnabled")
        
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
        audioProcessor.onNextTrack = { [weak self] in self?.playNextSong() }
        audioProcessor.onPreviousTrack = { [weak self] in self?.playPreviousSong() }
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
        
        // Playlist Button
        playlistButton.setImage(UIImage(systemName: "music.note.list"), for: .normal)
        playlistButton.addTarget(self, action: #selector(openPlaylistView), for: .touchUpInside)
        playlistButton.translatesAutoresizingMaskIntoConstraints = false
        playlistButton.isHidden = true // Hidden by default
        
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
        bassLabel.textAlignment = .center
        midsLabel.textAlignment = .center
        trebleLabel.textAlignment = .center
        songTitleLabel.text = "No File Loaded"

        // 3. Play/Pause Button
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        // Make play/pause button larger and square
        playPauseButton.imageView?.contentMode = .scaleAspectFit
        playPauseButton.contentVerticalAlignment = .fill
        playPauseButton.contentHorizontalAlignment = .fill
        playPauseButton.imageEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10) // Add some padding

        // Rewind 10s button
        rewindButton.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        rewindButton.addTarget(self, action: #selector(rewind10Seconds), for: .touchUpInside)

        // Skip 10s button
        skipButton.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        skipButton.addTarget(self, action: #selector(skip10Seconds), for: .touchUpInside)
        
        // Previous Track button
        previousTrackButton.setImage(UIImage(systemName: "backward.end.fill"), for: .normal)
        previousTrackButton.addTarget(self, action: #selector(playPreviousSong), for: .touchUpInside)
        
        // Next Track button
        nextTrackButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)
        nextTrackButton.addTarget(self, action: #selector(playNextSong), for: .touchUpInside)

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
        let playbackControlsStack = UIStackView(arrangedSubviews: [previousTrackButton, rewindButton, playPauseButton, skipButton, nextTrackButton])
        playbackControlsStack.axis = .horizontal
        playbackControlsStack.alignment = .center
        playbackControlsStack.distribution = .equalSpacing // Distribute space evenly

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
        
        // EQ Sliders Setup (Gain: -12dB to +12dB)
        bassLabel.text = "Bass (0 dB)"
        bassSlider.minimumValue = -12
        bassSlider.maximumValue = 12
        bassSlider.value = 0
        bassSlider.addTarget(self, action: #selector(bassSliderChanged), for: .valueChanged)
        
        midsLabel.text = "Mids (0 dB)"
        midsSlider.minimumValue = -12
        midsSlider.maximumValue = 12
        midsSlider.value = 0
        midsSlider.addTarget(self, action: #selector(midsSliderChanged), for: .valueChanged)
        
        trebleLabel.text = "Treble (0 dB)"
        trebleSlider.minimumValue = -12
        trebleSlider.maximumValue = 12
        trebleSlider.value = 0
        trebleSlider.addTarget(self, action: #selector(trebleSliderChanged), for: .valueChanged)
        
        // Initialize EQ slider visibility based on saved settings
        let isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
        [bassLabel, bassSlider, midsLabel, midsSlider, trebleLabel, trebleSlider].forEach {
            $0.isHidden = !isEQEnabled
        }
        
        // 6. Reset Button Setup (replaces File Picker button)
        // Group the effect sliders with their labels for consistent spacing
        pitchControlStack = UIStackView(arrangedSubviews: [pitchLabel, pitchSlider])
        pitchControlStack.axis = .vertical
        pitchControlStack.spacing = 8
        let speedControlStack = UIStackView(arrangedSubviews: [speedLabel, speedSlider])
        speedControlStack.axis = .vertical
        speedControlStack.spacing = 8
        let reverbControlStack = UIStackView(arrangedSubviews: [reverbLabel, reverbSlider])
        reverbControlStack.axis = .vertical
        reverbControlStack.spacing = 8
        let bassControlStack = UIStackView(arrangedSubviews: [bassLabel, bassSlider])
        bassControlStack.axis = .vertical
        bassControlStack.spacing = 8
        let midsControlStack = UIStackView(arrangedSubviews: [midsLabel, midsSlider])
        midsControlStack.axis = .vertical
        midsControlStack.spacing = 8
        let trebleControlStack = UIStackView(arrangedSubviews: [trebleLabel, trebleSlider])
        trebleControlStack.axis = .vertical
        trebleControlStack.spacing = 8
        
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
            bassControlStack,
            midsControlStack,
            trebleControlStack,
            UIView(), // Spacer
            actionButtonsStack
        ])
        
        stackView.axis = .vertical
        stackView.spacing = 20
        // Set custom spacing to create groups of controls
        stackView.setCustomSpacing(30, after: playbackControlsStack)
        stackView.setCustomSpacing(12, after: pitchControlStack)
        stackView.setCustomSpacing(12, after: speedControlStack)
        stackView.setCustomSpacing(12, after: reverbControlStack)
        stackView.setCustomSpacing(12, after: bassControlStack)
        stackView.setCustomSpacing(12, after: midsControlStack)
        stackView.setCustomSpacing(30, after: trebleControlStack)
        
        // The spacer view should have a low-priority constraint to allow it to shrink
        if let spacer = stackView.arrangedSubviews[7] as? UIView {
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        }
        
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(settingsButton)
        view.addSubview(addFileButton)
        view.addSubview(playlistButton)
        view.addSubview(stackView)
        
        // Setup ScrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        
        // Set alignment for grouped controls
        pitchControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        speedControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        reverbControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        bassControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        midsControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        trebleControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        
        // Bring buttons to the front so they don't get scrolled over
        view.bringSubviewToFront(settingsButton)
        view.bringSubviewToFront(addFileButton)
        view.bringSubviewToFront(playlistButton)
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
            
            // Playlist button in the top center
            playlistButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            playlistButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playlistButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            
            // ScrollView constraints
            scrollView.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            
            // StackView constraints inside ScrollView
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 30),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -30),
            
            // This is crucial: make the stackView's width equal to the scrollView's frame width (minus padding)
            // to enable vertical-only scrolling.
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -60),
            
            // Album Art size constraint
            albumArtImageView.heightAnchor.constraint(equalTo: albumArtImageView.widthAnchor, multiplier: 1.0),
            albumArtImageView.widthAnchor.constraint(equalTo: stackView.widthAnchor, multiplier: 0.7), // 70% width
            
            // Make sliders and button take up more width
            speedSlider.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            progressStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            actionButtonsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
        
        // Constraints for the new playback control buttons
        playbackControlsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true // Ensure the stack fills the width
        
        playPauseButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: 0.22).isActive = true
        playPauseButton.heightAnchor.constraint(equalTo: playPauseButton.widthAnchor).isActive = true
        
        let secondaryButtonMultiplier = 0.13
        
        rewindButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        rewindButton.heightAnchor.constraint(equalTo: rewindButton.widthAnchor).isActive = true
        previousTrackButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        previousTrackButton.heightAnchor.constraint(equalTo: previousTrackButton.widthAnchor).isActive = true
        skipButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        skipButton.heightAnchor.constraint(equalTo: skipButton.widthAnchor).isActive = true
        nextTrackButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        nextTrackButton.heightAnchor.constraint(equalTo: nextTrackButton.widthAnchor).isActive = true
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
        rewindButton.isHidden = isHidden
        skipButton.isHidden = isHidden
        previousTrackButton.isHidden = isHidden
        nextTrackButton.isHidden = isHidden
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
        
        bassLabel.isHidden = isHidden
        bassSlider.isHidden = isHidden
        midsLabel.isHidden = isHidden
        midsSlider.isHidden = isHidden
        trebleLabel.isHidden = isHidden
        trebleSlider.isHidden = isHidden

        // When controls are being hidden, also hide the artist label.
        // When controls are shown, its visibility will be determined by `loadAudioFile`.
        artistNameLabel.isHidden = isHidden
        
        // Reset to initial values
        if isHidden || !isRememberSettingsEnabled {
            resetSliders()
        }
        
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
    }
    
    /// Resets only the effect sliders to their default values.
    @objc private func resetSliders() {
        speedSlider.value = 1.0
        pitchSlider.value = 0.0
        lastSnappedSpeedValue = 1.0 // Reset for haptics
        lastSnappedPitchValue = 0.0 // Reset for haptics
        reverbSlider.value = 0.0
        bassSlider.value = 0.0
        midsSlider.value = 0.0
        trebleSlider.value = 0.0

        // Trigger the change handlers to update labels and the audio processor
        speedSliderChanged(speedSlider)
        pitchSliderChanged(pitchSlider)
        reverbSliderChanged(reverbSlider)
        bassSliderChanged(bassSlider)
        midsSliderChanged(midsSlider)
        trebleSliderChanged(trebleSlider)
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
    
    @objc private func resetBassSlider() {
        bassSlider.value = 0.0
        bassSliderChanged(bassSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetMidsSlider() {
        midsSlider.value = 0.0
        midsSliderChanged(midsSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetTrebleSlider() {
        trebleSlider.value = 0.0
        trebleSliderChanged(trebleSlider)
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
        // Restore settings regardless of whether a file is loaded
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
        let isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
        let isAlbumArtVisible = UserDefaults.standard.bool(forKey: "isAlbumArtVisible", defaultValue: true)
        let isPlaylistModeEnabled = UserDefaults.standard.bool(forKey: "isPlaylistModeEnabled")
        let isLoopingEnabled = UserDefaults.standard.bool(forKey: "isLoopingEnabled")
        let isRememberSettingsEnabled = UserDefaults.standard.bool(forKey: "isRememberSettingsEnabled")
        let isAutoPlayNextEnabled = UserDefaults.standard.bool(forKey: "isAutoPlayNextEnabled")
        
        settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)
        settingsViewController(SettingsViewController(), didChangeAnimatedBackgroundState: isAnimatedBackgroundEnabled)
        settingsViewController(SettingsViewController(), didChangeDynamicBackgroundState: isDynamicBackgroundEnabled)
        settingsViewController(SettingsViewController(), didChangeDynamicThemeState: isDynamicThemeEnabled)
        settingsViewController(SettingsViewController(), didChangeResetSlidersOnTapState: isResetSlidersOnTapEnabled)
        settingsViewController(SettingsViewController(), didChangeTapArtworkToChangeSongState: isTapArtworkToChangeSongEnabled)
        settingsViewController(SettingsViewController(), didChangePrecisePitchState: isAccuratePitchEnabled)
        settingsViewController(SettingsViewController(), didChangeAccurateSpeedState: isAccurateSpeedEnabled)
        settingsViewController(SettingsViewController(), didChangeShowExportButtonState: isExportButtonEnabled)
        settingsViewController(SettingsViewController(), didChangeShowEQState: isEQEnabled)
        settingsViewController(SettingsViewController(), didChangeShowAlbumArtState: isAlbumArtVisible)
        settingsViewController(SettingsViewController(), didChangePlaylistModeState: isPlaylistModeEnabled)
        settingsViewController(SettingsViewController(), didChangeLoopingState: isLoopingEnabled)
        settingsViewController(SettingsViewController(), didChangeRememberSettingsState: isRememberSettingsEnabled)
        settingsViewController(SettingsViewController(), didChangeAutoPlayNextState: isAutoPlayNextEnabled)
        
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
                if isPlaylistModeEnabled {
                    loadPlaylistFromBookmarks()
                }
                
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
                
                let bass = UserDefaults.standard.float(forKey: "bassValue")
                bassSlider.value = bass
                bassSliderChanged(bassSlider)
                
                let mids = UserDefaults.standard.float(forKey: "midsValue")
                midsSlider.value = mids
                midsSliderChanged(midsSlider)
                
                let treble = UserDefaults.standard.float(forKey: "trebleValue")
                trebleSlider.value = treble
                trebleSliderChanged(trebleSlider)

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
        
        // Clear only file-related UserDefaults
        UserDefaults.standard.removeObject(forKey: "lastAudioFileBookmark")
        UserDefaults.standard.removeObject(forKey: "lastPlaybackPosition")
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
        
        // If song finishes, update play button icon
        if currentTime >= duration {
            if isLoopingEnabled {
                audioProcessor.seek(to: 0)
                progressSlider.value = 0
                currentTimeLabel.text = formatTime(seconds: 0)
            } else if UserDefaults.standard.bool(forKey: "isPlaylistModeEnabled") && isAutoPlayNextEnabled {
                playNextSong()
            } else {
                audioProcessor.pause()
                audioProcessor.seek(to: 0)
                playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
                progressSlider.value = 0 // Reset slider to beginning
                currentTimeLabel.text = formatTime(seconds: 0)
            }
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
    
    @objc private func openPlaylistView() {
        let playlistVC = PlaylistViewController()
        playlistVC.delegate = self
        playlistVC.playlistURLs = self.playlistURLs
        playlistVC.currentAudioURL = self.currentAudioURL
        
        let navController = UINavigationController(rootViewController: playlistVC)
        if let sheet = navController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        
        present(navController, animated: true)
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
        settingsVC.isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
        settingsVC.isAlbumArtVisible = UserDefaults.standard.bool(forKey: "isAlbumArtVisible", defaultValue: true)
        settingsVC.isPlaylistModeEnabled = UserDefaults.standard.bool(forKey: "isPlaylistModeEnabled")
        settingsVC.isLoopingEnabled = self.isLoopingEnabled
        settingsVC.isRememberSettingsEnabled = self.isRememberSettingsEnabled
        settingsVC.isAutoPlayNextEnabled = self.isAutoPlayNextEnabled
        
        // Embed the SettingsViewController in a UINavigationController to display a navigation bar
        let navController = UINavigationController(rootViewController: settingsVC)
        
        // Present as a sheet
        if let sheet = navController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            impactFeedbackGenerator.impactOccurred()
        }
        present(navController, animated: true)
    }
    
    // MARK: SettingsViewControllerDelegate
    
    func settingsViewController(_ controller: SettingsViewController, didChangeLinkPitchState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isPitchLinked")
        pitchControlStack.isHidden = isEnabled
        audioProcessor.setVarispeedEnabled(isEnabled)
        speedSliderChanged(speedSlider) // Re-apply speed/pitch logic
        updatePlayPauseButtonState()
        progressSlider.value = 0
        currentTimeLabel.text = formatTime(seconds: 0)
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
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowEQState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isEQEnabled")
        let views = [bassLabel, bassSlider, midsLabel, midsSlider, trebleLabel, trebleSlider]
        views.forEach { $0.isHidden = !isEnabled }
        // Re-apply reverb slider visibility based on user settings
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowAlbumArtState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isAlbumArtVisible")
        albumArtImageView.isHidden = !isEnabled
        let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangePlaylistModeState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isPlaylistModeEnabled")
        
        // Stop playback and clear the current song when mode changes
        clearCurrentSongAndStopPlayback()
        
        if isEnabled && playlistURLs.isEmpty {
            // If turning on and no playlist is loaded, prompt to select a folder
            openFolderPicker()
        } else if !isEnabled { // When turning off
            // When turning off, also clear the saved playlist bookmarks and the URL list
            playlistURLs = []
            UserDefaults.standard.removeObject(forKey: "playlistBookmarks")
        }
        
        updatePlaylistControls(isPlaylistMode: isEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeLoopingState isEnabled: Bool) {
        self.isLoopingEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isLoopingEnabled")
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeRememberSettingsState isEnabled: Bool) {
        self.isRememberSettingsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isRememberSettingsEnabled")
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAutoPlayNextState isEnabled: Bool) {
        self.isAutoPlayNextEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isAutoPlayNextEnabled")
    }
    
    /// Stops playback and resets the UI to the "No File Loaded" state.
    private func clearCurrentSongAndStopPlayback() {
        if audioProcessor.isCurrentlyPlaying() {
            audioProcessor.togglePlayback() // This will stop playback and update the Now Playing info
        }
        
        // Reset UI elements
        resetControlsState(isHidden: true)
        songTitleLabel.text = "No File Loaded"
        artistNameLabel.text = nil
        albumArtImageView.image = UIImage(systemName: "music.note")
        updateBackground(with: nil)
        
        // Clear state variables and saved data for the last song
        currentAudioURL = nil
        UserDefaults.standard.removeObject(forKey: "lastAudioFileBookmark")
        UserDefaults.standard.removeObject(forKey: "lastPlaybackPosition")
    }
    
    /// Updates the skip/rewind buttons to be next/previous track buttons.
    private func updatePlaylistControls(isPlaylistMode: Bool) {
        audioProcessor.updatePlaylistRemoteCommands(isEnabled: isPlaylistMode)
        playlistButton.isHidden = !isPlaylistMode
        
        let addFileIconName = isPlaylistMode ? "folder.badge.plus" : "plus"
        addFileButton.setImage(UIImage(systemName: addFileIconName), for: .normal)
        
        // Show/hide the next/previous track buttons based on playlist mode
        previousTrackButton.isHidden = !isPlaylistMode
        nextTrackButton.isHidden = !isPlaylistMode
        
        // The 10-second skip buttons are always visible when controls are shown,
        // so we don't need to change their icons or visibility here.
        // Their actions are now directly tied to their selectors.
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
        bassLabel.gestureRecognizers?.forEach(bassLabel.removeGestureRecognizer)
        midsLabel.gestureRecognizers?.forEach(midsLabel.removeGestureRecognizer)
        trebleLabel.gestureRecognizers?.forEach(trebleLabel.removeGestureRecognizer)
        
        pitchLabel.isUserInteractionEnabled = isEnabled
        speedLabel.isUserInteractionEnabled = isEnabled
        reverbLabel.isUserInteractionEnabled = isEnabled
        bassLabel.isUserInteractionEnabled = isEnabled
        midsLabel.isUserInteractionEnabled = isEnabled
        trebleLabel.isUserInteractionEnabled = isEnabled
        
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
            
            let bassTap = UITapGestureRecognizer(target: self, action: #selector(resetBassSlider))
            bassTap.numberOfTapsRequired = 2
            bassLabel.addGestureRecognizer(bassTap)
            
            let midsTap = UITapGestureRecognizer(target: self, action: #selector(resetMidsSlider))
            midsTap.numberOfTapsRequired = 2
            midsLabel.addGestureRecognizer(midsTap)
            
            let trebleTap = UITapGestureRecognizer(target: self, action: #selector(resetTrebleSlider))
            trebleTap.numberOfTapsRequired = 2
            trebleLabel.addGestureRecognizer(trebleTap)
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
        
        // Check if pitch control is hidden (linked pitch is ON)
        if pitchControlStack.isHidden {
            // When using Varispeed, we just set the rate. The engine handles the pitch linking.
            // We pass nil for linkedPitch because Varispeed doesn't use the TimePitch node's pitch property.
            audioProcessor.setPlaybackRate(rate: finalRate, linkedPitch: nil)
            // We don't update pitchSlider.value here because it's hidden and irrelevant in Varispeed mode.
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
    
    @objc func bassSliderChanged(_ sender: UISlider) {
        let gain = sender.value
        audioProcessor.setBassGain(gain: gain)
        UserDefaults.standard.set(gain, forKey: "bassValue")
        bassLabel.text = String(format: "Bass (%.1f dB)", gain)
    }
    
    @objc func midsSliderChanged(_ sender: UISlider) {
        let gain = sender.value
        audioProcessor.setMidsGain(gain: gain)
        UserDefaults.standard.set(gain, forKey: "midsValue")
        midsLabel.text = String(format: "Mids (%.1f dB)", gain)
    }
    
    @objc func trebleSliderChanged(_ sender: UISlider) {
        let gain = sender.value
        audioProcessor.setTrebleGain(gain: gain)
        UserDefaults.standard.set(gain, forKey: "trebleValue")
        trebleLabel.text = String(format: "Treble (%.1f dB)", gain)
    }

    // MARK: File Picker Logic

    @objc func openFilePicker() {
        let isPlaylistMode = UserDefaults.standard.bool(forKey: "isPlaylistModeEnabled")
        
        let supportedTypes: [UTType]
        if isPlaylistMode {
            supportedTypes = [.folder]
        } else {
            supportedTypes = [.mp3, .mpeg4Audio]
        }
        
        // Use 'asCopy: true' to ensure the file is copied into the app's sandbox
        let shouldCopy = !isPlaylistMode
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: shouldCopy)
        
        picker.directoryURL = getDocumentsDirectory() // Start in a known directory
        
        picker.delegate = self
        picker.allowsMultipleSelection = false
        
        impactFeedbackGenerator.impactOccurred()
        present(picker, animated: true, completion: nil)
    }

    private func openFolderPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.directoryURL = getDocumentsDirectory()
        
        impactFeedbackGenerator.impactOccurred()
        present(picker, animated: true, completion: nil)
    }
    
    private func getDocumentsDirectory() -> URL {
        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
    
    private func processFolder(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to start accessing security-scoped resource for folder.")
            return
        }
        
        defer { url.stopAccessingSecurityScopedResource() }
        
        var fileURLs: [URL] = []
        var bookmarkDataArray: [Data] = []
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            let allowedExtensions = ["mp3", "m4a"]
            let audioFiles = contents.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            for fileURL in audioFiles {
                // We need to get a bookmark for each individual file to have persistent access
                let bookmarkData = try fileURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                bookmarkDataArray.append(bookmarkData)
                
                // Resolve the bookmark immediately to get a security-scoped URL that can be accessed independently later
                var isStale = false
                let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                fileURLs.append(resolvedURL)
            }
            
            self.playlistURLs = fileURLs
            UserDefaults.standard.set(bookmarkDataArray, forKey: "playlistBookmarks")
            
            // Load the first song from the new playlist
            if let firstSongURL = fileURLs.first {
                loadAudioFile(url: firstSongURL, andPlay: true)
            }
            
        } catch {
            print("Error processing folder contents: \(error)")
        }
    }
    
    private func loadPlaylistFromBookmarks() {
        guard let bookmarkDataArray = UserDefaults.standard.array(forKey: "playlistBookmarks") as? [Data] else { return }
        
        self.playlistURLs = bookmarkDataArray.compactMap { data in
            do {
                var isStale = false
                return try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
            } catch {
                print("Failed to resolve playlist bookmark: \(error)")
                return nil
            }
        }
    }

    // MARK: UIDocumentPickerDelegate Methods

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        do {
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "lastAudioFileBookmark")
        } catch {
            print("Failed to save bookmark data: \(error)")
        }
        
        // Check if a folder was picked
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            processFolder(url: url)
        } else {
            loadAudioFile(url: url, andPlay: true)
        }
    }
    
    private func loadAudioFile(url: URL, andPlay: Bool) {
        // **CRITICAL FIX**: Start accessing the security-scoped resource before trying to read the file.
        // This is necessary for any URL obtained from a bookmark, which is how the playlist works.
        let shouldAccess = url.startAccessingSecurityScopedResource()
        
        // Use a defer block to ensure we stop accessing the resource when the function exits,
        // whether it succeeds or fails.
        defer {
            if shouldAccess { url.stopAccessingSecurityScopedResource() }
        }
        self.currentAudioURL = url
        
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
            
            // Re-apply EQ slider visibility based on user settings
            let isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
            settingsViewController(SettingsViewController(), didChangeShowEQState: isEQEnabled)

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
        // If user cancels folder selection when turning on playlist mode, turn it back off.
        if UserDefaults.standard.bool(forKey: "isPlaylistModeEnabled") && playlistURLs.isEmpty {
            settingsViewController(SettingsViewController(), didChangePlaylistModeState: false)
        }
    }
    
    // MARK: PlaylistViewControllerDelegate
    
    func playlistViewController(_ controller: PlaylistViewController, didSelectSongAt url: URL) {
        loadAudioFile(url: url, andPlay: true)
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
    
    // MARK: Playlist Navigation
    
    @objc private func playNextSong() {
        guard !playlistURLs.isEmpty else { return }
        
        let currentIndex = playlistURLs.firstIndex(of: currentAudioURL ?? URL(fileURLWithPath: "")) ?? -1
        let nextIndex = (currentIndex + 1) % playlistURLs.count
        
        let nextURL = playlistURLs[nextIndex]
        loadAudioFile(url: nextURL, andPlay: true)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func playPreviousSong() {
        guard !playlistURLs.isEmpty else { return }
        
        let currentIndex = playlistURLs.firstIndex(of: currentAudioURL ?? URL(fileURLWithPath: "")) ?? 0
        var prevIndex = currentIndex - 1
        if prevIndex < 0 {
            prevIndex = playlistURLs.count - 1
        }
        
        let prevURL = playlistURLs[prevIndex]
        loadAudioFile(url: prevURL, andPlay: true)
        impactFeedbackGenerator.impactOccurred()
    }
    
    // MARK: Export Action
    
    @objc private func exportTapped() {
        let alert = UIAlertController(title: "Export Quality", message: "Select the audio quality for export.", preferredStyle: .actionSheet)
        
        let options: [(title: String, bitrate: Int)] = [
            ("Low (128 kbps)", 128000),
            ("Medium (192 kbps)", 192000),
            ("High (256 kbps)", 256000),
            ("Best (320 kbps)", 320000)
        ]
        
        for option in options {
            alert.addAction(UIAlertAction(title: option.title, style: .default) { [weak self] _ in
                self?.startExportProcess(bitrate: option.bitrate)
            })
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = exportButton
            popover.sourceRect = exportButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    private func startExportProcess(bitrate: Int) {
        // Create a custom overlay view for progress
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        let containerView = UIView()
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 12
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = "Exporting..."
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let progressBar = UIProgressView(progressViewStyle: .default)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        
        containerView.addSubview(titleLabel)
        containerView.addSubview(progressBar)
        overlayView.addSubview(containerView)
        view.addSubview(overlayView)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 220),
            containerView.heightAnchor.constraint(equalToConstant: 100),
            
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            
            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            progressBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20)
        ])
        
        view.isUserInteractionEnabled = false // Prevent user interaction during export
        
        audioProcessor.exportAudio(bitrate: bitrate, progress: { progress in
            DispatchQueue.main.async {
                progressBar.setProgress(progress, animated: true)
            }
        }) { [weak self] result in
            DispatchQueue.main.async {
                // Remove overlay
                overlayView.removeFromSuperview()
                self?.view.isUserInteractionEnabled = true
                
                // Update UI to reflect paused state at beginning
                self?.updatePlayPauseButtonState()
                self?.progressSlider.value = 0
                self?.currentTimeLabel.text = self?.formatTime(seconds: 0)
                self?.audioProcessor.updateNowPlayingInfo(isPaused: true)
                
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
            "isExportButtonEnabled": true,
            "isEQEnabled": false,
            "isPlaylistModeEnabled": false,
            "isAlbumArtVisible": true,
            "isLoopingEnabled": false,
            "isRememberSettingsEnabled": false,
            "isAutoPlayNextEnabled": false
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
