# Slowed + Reverb

<p align="center">
  <img src="images/screenshot1.png" width="30%" />
  <img src="images/screenshot2.png" width="30%" />
  <img src="images/screenshot3.png" width="30%" />
</p>

An iOS application designed for real-time audio manipulation, allowing users to create, listen to, and export "slowed and reverb" remixes with professional-grade audio effects.

## Key Features

### 🎛 Advanced Audio Engine
*   **Independent Time & Pitch Shifting**: Utilizes `AVAudioUnitTimePitch` to adjust playback rate (0.5x to 2.0x) and pitch (-12 to +12 semitones) separately.
*   **Vinyl Emulation**: Optional "Link Pitch to Speed" mode simulates the physics of a record player.
*   **3-Band Equalizer**: Dedicated `AVAudioUnitEQ` nodes for shaping Bass, Mids, and Treble frequencies.
*   **Environmental Reverb**: Integrated `AVAudioUnitReverb` with adjustable wet/dry mix for spatial depth.

### 💾 High-Fidelity Export
*   **Offline Rendering**: Uses `AVAudioEngine`'s manual rendering mode to export processed audio faster than real-time.
*   **Customizable Quality**: Supports AAC export at variable bitrates (128kbps up to 320kbps).
*   **Smart Naming**: Automatically generates filenames containing the original title and applied effect parameters (e.g., "Song Speed 0.85x Pitch -2st.m4a").

### 🎨 Dynamic User Interface
*   **Adaptive Theming**: The `ThemeManager` analyzes album artwork to extract vibrant dominant colors, tinting the UI to match the current track.
*   **Live Backgrounds**: Features a dynamic, blurred background that animates (zooms) based on the active media.
*   **Haptic Feedback**: Integrated `UIImpactFeedbackGenerator` and `UISelectionFeedbackGenerator` provide tactile responses when sliders snap to precise values (semitones or 0.05x speed increments).

### 📂 Playlist & File Management
*   **Folder-Based Playlists**: Supports importing entire directories via `UIDocumentPickerViewController`.
*   **Security-Scoped Persistence**: Utilizes URL bookmarks to maintain access to user-selected files and folders across app launches without re-importing.
*   **Metadata Extraction**: Parses `AVAsset` metadata for high-resolution artwork, artist, and title information.

### 🎧 System Integration
*   **Background Playback**: Configured `AVAudioSession` for seamless playback while the device is locked or the app is backgrounded.
*   **Remote Command Center**: Full support for lock screen and Control Center media controls, including scrubbing and track navigation.