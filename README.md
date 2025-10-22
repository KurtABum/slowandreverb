# Slowed and Reverb

Slowed and Reverb is an iOS application that allows users to play audio files and apply real-time tempo (speed), pitch, and reverb effects. It's built using `AVAudioEngine` for audio processing and `UIKit` for the user interface, with `SwiftUI` for previewing.

## Features

- **Audio Playback:** Load and play MP3 audio files.
- **Real-time Effects:**
    - **Tempo Control:** Adjust playback speed (0.5x to 2.0x).
    - **Pitch Control:** Adjust pitch independently or linked to tempo (-12 to +12 semitones).
    - **Reverb:** Apply environmental reverb effects with adjustable wet/dry mix.
- **Background Playback:** Audio continues playing when the app is in the background or the screen is locked.
- **Remote Control Integration:** Control playback (play/pause, seek) from the Control Center and lock screen.
- **Now Playing Info:** Displays song title, artist, artwork, and playback progress on the lock screen.
- **State Persistence:** Remembers the last played song, playback position, and effect settings across app launches.
- **Customizable Settings:**
    - Link Pitch to Speed (like a record player).
    - Dynamic Background (blurs album art for background).
    - Dynamic Theme (extracts dominant color from album art).
    - Toggle Reverb Slider visibility.
    - Double-tap labels to reset sliders.
    - Tap artwork to open file picker.
- **Basic Playback Controls:** Play/Pause, Rewind 10s, Skip 10s.

## How to Use

1. Tap the `+` button or the album artwork to open the file picker and select an MP3 audio file.
2. Use the play/pause button to control playback.
3. Adjust the "Pitch", "Speed", and "Reverb" sliders to apply effects.
4. Tap the `gear` icon to access settings and customize the app's behavior and appearance.
