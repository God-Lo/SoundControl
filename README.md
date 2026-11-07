# Sound Control

An unofficial iOS remote for compatible wireless headphones that expose the `link2` accessory protocol (tested with the WF-1000XM5).

- Noise cancelling, Ambient (levels 1–20) and Off
- Equalizer presets, a draggable 5-band curve and Clear Bass
- Battery levels for each earbud and the case
- Switching playback between two connected devices (multipoint)
- Optional live audio waveform through a screen-broadcast extension
- Siri Shortcuts and `soundcontrol://` links

## Install

**Add as a source** in LiveContainer, AltStore or SideStore:

```
https://raw.githubusercontent.com/God-Lo/SoundControl/main/source.json
```

Or download `SoundControl.ipa` from [Releases](../../releases). It is unsigned: sign it with your own Apple ID or certificate (Xcode, Sideloadly, AltStore, SideStore) or load it in LiveContainer.

For the live waveform and Shortcuts inside LiveContainer, use [my LiveContainer fork](https://github.com/God-Lo/LiveContainer), which supports broadcast extensions and shortcuts.

## Build

Open `SoundControl/SoundControl.xcodeproj` in Xcode 26 or later, choose your signing team for both targets, and run on an iPhone. Pair the headphones in iOS Settings first.

## Contributors

- [God-Lo](https://github.com/God-Lo)
- [Claude](https://claude.com/claude-code) (Anthropic)

## Disclaimer

Sound Control is an independent project. It is not affiliated with, endorsed by, or supported by Sony Group Corporation or any headphone manufacturer. All product names and trademarks belong to their owners and are used only to describe compatibility. It contains no code, assets, or files from any manufacturer's app. Use it at your own risk.
