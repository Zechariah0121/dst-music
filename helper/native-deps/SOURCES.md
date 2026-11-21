# Native audio dependencies and DSP provenance

Runtime dependencies: NAudio **2.2.1**, Mark Heath, MIT. Only these managed DLLs
are required; no installer, executable, SDK or machine-wide change is needed.
They were extracted from the official NuGet flat-container packages:

- https://api.nuget.org/v3-flatcontainer/naudio.core/2.2.1/naudio.core.2.2.1.nupkg
- https://api.nuget.org/v3-flatcontainer/naudio.winmm/2.2.1/naudio.winmm.2.2.1.nupkg
- https://api.nuget.org/v3-flatcontainer/naudio.wasapi/2.2.1/naudio.wasapi.2.2.1.nupkg

Each DLL is the package's `lib/netstandard2.0` build. Windows PowerShell 5.1
loads the installed .NET Framework netstandard facade from the GAC.

SHA-256:

| DLL | Hash |
| --- | --- |
| NAudio.Core.dll | FCF493FC47A2F478A65303886B975FBDBF714CBB1F2D79F7FCE97E4BB16B01A8 |
| NAudio.WinMM.dll | 749A01EBBB5EDD8B1A03C5263B04DE6ACADECF52E4CC84D7412BC6E93F180958 |
| NAudio.Wasapi.dll | 618EF0E49D64E7A66DFE64BBF6AE81705B9D9683D8A9F321E5C3024D666BDF82 |

License: `NAudio.LICENSE.txt`, from
https://raw.githubusercontent.com/naudio/NAudio/v2.2.1/license.txt

## Environmental DSP

`../EnvironmentDSP.cs` contains the modified environmental algorithm from Sorihiko/DangoMusic,
fixed commit `ffd88ffc9f4b4af30ef7550eb9781468ab180c31`, GPL-3.0.
Unmodified reference source is included as `EnvironmentAudio.reference.kt`.
`MusicPlayer.reference.kt` documents the original normalization/headroom logic.
Corresponding upstream source and license:

- https://github.com/Sorihiko/DangoMusic/blob/ffd88ffc9f4b4af30ef7550eb9781468ab180c31/common/core/src/main/kotlin/me/sorihiko/dango/music/EnvironmentAudio.kt
- https://github.com/Sorihiko/DangoMusic/blob/ffd88ffc9f4b4af30ef7550eb9781468ab180c31/common/core/src/main/kotlin/me/sorihiko/dango/music/MusicPlayer.kt
- `DangoMusic.LICENSE.txt`: https://github.com/Sorihiko/DangoMusic/blob/ffd88ffc9f4b4af30ef7550eb9781468ab180c31/LICENSE

Historical version 0.4 extended the derived implementation with audition presets for DST
cave, lunar island, ocean, ruins, atrium and deciduous forest. These presets are
local adaptations, not upstream DangoMusic presets or measured acoustics.
The reverb uses four damped combs, two unity-gain all-pass filters, and stereo
wet diffusion while preserving independent dry channels. Filter softening uses
two stable one-pole stages rather than the earlier Butterworth curve.
Water retains the 450 Hz cutoff and 0.85 gain; indoor retains a 5 kHz cutoff
and at least 0.3 wet reverb. Base regional settings:

| Region | Cutoff Hz | Wet | Feedback | Damping | Stereo width |
| --- | ---: | ---: | ---: | ---: | ---: |
| surface | 20000 | 0 | .72 | .30 | .30 |
| cave | 20000 | .34 | .81 | .38 | .35 |
| lunar | 20000 | .26 | .84 | .10 | .65 |
| ocean | 20000 | .12 | .60 | .18 | .70 |
| ruins | 6200 | .28 | .65 | .60 | .25 |
| atrium | 9000 | .38 | .87 | .46 | .55 |
| forest | 12000 | .13 | .57 | .48 | .40 |

Rain multiplies the regional cutoff by `(6500/20000)^rain` and gain by
`1 - .08*rain`, so it softens every region independently. It generates no rain
audio. Strength scales filter mix, wet and gain; 80 ms sample-wise ramps avoid
block-sized parameter steps. Identical settings do not restart ramps. Returning
to dry clears history and becomes exact bypass after the transition; Reset/seek
clears the tail immediately. Delay storage is bounded and reused across regions.

`desired.audio.env` is `{enabled, water, cave, indoor, rain:0..1, region, strength:0..1}`.
Absent region retains old clients' cave/surface mapping; water/indoor remain
compatible legacy flags. DST telemetry keeps water/indoor false.
`desired.audio.{baseVolume,normalize,gainDb,peak}` provides native PCM
normalization; gain is limited to 0.25..2 with 0.98/peak headroom as upstream.
When absent, `desired.volume` remains the backward-compatible volume input.

## Local changes in 0.5 (2026-11-04)

The GPL-derived environmental class is now in `EnvironmentDSP.cs`; the complete
modified source is included, along with the original reference and GPL text.
`NativeDSP.cs` now hosts native decoding, streaming buffers and device output.
This distribution preserves the applicable component licenses, including GPLv3
for the derived native audio implementation and any covered combined work.
Complete implementation source and build scripts accompany the Windows player
in the Workshop source ZIP. No blanket license is asserted for independent
components or user-supplied artwork; see LICENSE-DECISION.md in the bundle.

The new reverb uses eight stationary delay lines and twelve early reflection
taps, with regional weights, 180 Hz high-pass on the reverb input, an independent
dry path (0.88 at full regional strength), and linked .98 peak protection with
80 ms recovery. Regional wet/early/feedback/width are respectively:
cave `.48/.30/.84/.65`, lunar `.56/.24/.91/.95`, ocean `.27/.32/.55/1`,
ruins `.46/.38/.66/.38`, atrium `.62/.30/.965/.8`, forest `.25/.30/.48/.6`.
The table above describes the historical 0.4 baseline, not the current presets.
Rain remains independent. Stationary taps and 80 ms coefficient ramps avoid
pitch modulation during region changes; bypass and reset clear stored tails.

Current decode/output: progressive MP3 frames decoded by Windows ACM, PCM
spooled to disk with a fixed 16×64 KiB read-ahead cache, float PCM processing,
then 16-bit WASAPI shared output, falling back to waveOut if initialization
fails. Both request a 60 ms total output buffer; this is not a measured
end-to-end latency. `SharedAudioOutput.cs` owns WASAPI initialization, clock
sampling and COM cleanup on a dedicated STA. Pause captures the played source
position and asynchronously stops/rebuilds the WASAPI output, so resume does
not include the paused silence clock; this also resets the DSP tail. WaveOut
retains its native pause behavior. EOF is tracked at the provider and retains
the final content position after the device clock resets. Other formats retain full-file Media Foundation
decoding. Compressed and PCM files are each bounded at 256 MiB. There is a
30-second response-header deadline and 60-second individual network-read idle
deadline, with no total healthy-download duration limit. Files are cleaned on
replacement/exit. Codec availability follows the user's Windows installation.

Most regression tests use generated silence. Opt-in `native-output-timing`
tests play quiet, locally synthesized tones and inspect Windows render-loopback
timestamps without saving raw captured audio. Other applications must be quiet
for trustworthy frequency matching. This measures the endpoint mix, not the
physical speaker, game-frame presentation or a Voicemeeter routing chain.
`tests/native-player-silence.mp3` was generated
locally with ffmpeg's `anullsrc`, 8 seconds, 44.1 kHz stereo, libmp3lame 64 kbps;
it contains no third-party recording. PCM DSP tests use synthetic sine/impulse.

## QQ Music interoperability (0.6 test candidate)

`helper/qqmusic.mjs`, `helper/qq-login.mjs` and `helper/qq-lyrics.mjs`
are adapted from Sorihiko / DangoMusic at commit
`7d1609d6b259a6b439542058b3f8f0c5969b6e2b`, under GPL-3.0.
Upstream files: `QqMusicSource.kt`, `QqCatalog.kt`, `QqPlayback.kt`,
`QqLyrics.kt`, `NativeLogin.kt`, `QqAppChannel.kt`, `QqAppSession.kt`
and the associated account helpers in
https://github.com/Sorihiko/DangoMusic/tree/7d1609d6b259a6b439542058b3f8f0c5969b6e2b/common/core/src/main/kotlin/me/sorihiko/dango/music

The Node adaptation adds source-qualified IDs, bounded asynchronous login
sessions, source-isolated local credentials, fixed HTTPS CDN validation,
and the bridge's existing seconds-based lyric format. It does not import
desktop QQ Music credentials or decrypt protected audio. QQ's app QR flow
requires confirmation in the user's phone app; playback remains subject to
the platform's account and song permissions. Corresponding implementation
and tests are included in the Source archive; the full upstream license is
included as `DangoMusic.LICENSE.txt`. This component notice does not assign
a new blanket license to unrelated files or user artwork.
