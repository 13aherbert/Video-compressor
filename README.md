# Video Compressor (portable, flash-drive edition)

Shrinks videos to **under a size limit you choose (default 40 MB)** while keeping as much
quality as the limit allows. Runs from a flash drive on a locked-down Windows 10/11 PC:

- **Nothing to install.** No admin rights, no .NET runtime download, no registry changes.
- It uses the same encoders HandBrake uses (x265 / x264) through a single dependency-free
  `ffmpeg.exe`, and a small window built on the PowerShell and .NET Framework that are already
  part of Windows. (HandBrake's portable build needs the newer .NET 6/8 runtime; this does not.)
- **Size-targeted two-pass encoding**, so the result really lands under the limit instead of
  guessing with a quality slider.
- Drag-and-drop, a preview of what will happen to each file, progress bars, Cancel.

```
Video-compressor\
  Compress-Videos.bat   <- double-click, or drop videos / folders onto it
  settings.json         <- defaults (limit, codec, speed, output folder)
  bin\ffmpeg.exe        <- downloaded once by tools\Get-FFmpeg.ps1
  src\                  <- the PowerShell scripts
  logs\                 <- one log per run, with the exact ffmpeg commands
```

## One-time setup (on a computer with internet, e.g. at home)

1. Get the folder:
   - **Easiest:** download `Video-compressor-win64.zip` from the GitHub Releases page. It already
     contains ffmpeg. Unzip it onto the flash drive. Done.
   - **From source:** clone or download this repository, then run
     `powershell -ExecutionPolicy Bypass -File tools\Get-FFmpeg.ps1` once. It downloads a static
     ffmpeg build (about 115 MB) into `bin\`. Copy the whole folder to the flash drive.
2. Test it at home first: double-click `Compress-Videos.bat`, drop a video on the window, click
   **Start**.

## Daily use (on the work PC)

1. Plug in the drive and double-click `Compress-Videos.bat`, or drop video files or a folder
   straight onto the `.bat` file.
2. The window lists each file with what it will do: output resolution, frame rate, bitrate,
   estimated size and a **quality grade** (Good / OK / Poor). Change the limit, codec or speed
   and the preview updates immediately.
3. Click **Start**. Compressed files are saved next to the originals as `name.compressed.mp4`
   (or into a folder you choose). Originals are never modified.

### What to expect at 40 MB (1080p source, HEVC)

| Length  | Output          | Video bitrate | Grade |
|---------|-----------------|---------------|-------|
| 1 min   | 1920x1080       | ~5000 kbps    | Good  |
| 2 min   | 1920x1080       | ~2500 kbps    | Good  |
| 3 min   | 1280x720        | ~1600 kbps    | Good  |
| 5 min   | 960x540         | ~940 kbps     | Good  |
| 10 min  | 854x480         | ~450 kbps     | Good  |
| 20 min  | 640x360         | ~230 kbps     | OK    |
| 30 min+ | 640x360         | <150 kbps     | Poor  |

40 MB is a hard budget: a longer video simply gets fewer bits per second. The tool spends them
as well as it can (HEVC, two passes, lower frame rate before lower resolution, smaller audio),
and tells you honestly when the result will look rough. For long recordings, trim them or
split them first.

### Options in the window

| Option | Meaning |
|--------|---------|
| Max size (MB) | Hard limit. Counted as 1 MB = 1,000,000 bytes with a 3 % safety margin, so the file is under 40 MB however the receiving system counts. |
| Codec | **HEVC (H.265)**: 30 to 40 % better quality per MB. Plays in VLC, phones, Macs, Chrome, Edge and Windows 10/11 with the HEVC Video Extensions. **H.264**: plays on absolutely anything, lower quality per MB. |
| Speed | Fast / Balanced / Best quality = encoder presets fast / medium / slow. Slower presets squeeze a little more quality into the same bytes. |
| Max resolution | Auto lets the tool decide. Force 720p or 480p if you prefer smooth over sharp. |
| Save to | Next to the original, or a folder you pick. |
| Also re-encode files already under the limit | Off by default: small files are skipped untouched. |

Settings you change in the window are remembered in `settings.json` when you click Start.

### Console mode

If the window cannot open (see Troubleshooting) the tool automatically runs in the console with
the defaults from `settings.json`: drop files onto the `.bat` and watch the progress text.
You can also run it by hand:

```
Compress-Videos.bat "D:\clips\a.mp4" "D:\clips\b.mov"
powershell -ExecutionPolicy Bypass -File src\Main.ps1 -NoGui -TargetMB 25 -Codec h264 "D:\clips\a.mp4"
```

## How it decides

1. Reads the file with `ffprobe` (length, size, resolution, frame rate, audio).
2. Budget = limit minus a 3 % margin for container overhead.
3. Audio: AAC 96 kbps stereo, stepping down to 64 / 48 / 32 kbps mono only when audio would
   eat more than 15 % of the budget. Mono sources stay mono.
4. Video bitrate = whatever is left, divided by the length. Never higher than the source's
   bitrate, so small files are not inflated.
5. If the bits per pixel per frame fall below a quality threshold (HEVC 0.035, H.264 0.065):
   first cap frame rates above 30 fps (60 to 30, 50 to 25), then step the resolution down
   1440 / 1080 / 720 / 540 / 480 / 360 until the threshold is met. Portrait videos scale on
   their width. Dimensions stay even and the aspect ratio is kept.
6. Two-pass encode (`libx265` or `libx264`, `yuv420p`, `+faststart`, HEVC tagged `hvc1` so
   Apple devices play it). Pass-1 stats go to the local `%TEMP%` folder, not the flash drive.
7. Verifies the size. If it is still over, pass 2 is re-run at a proportionally lower bitrate
   (up to 2 retries).

## Troubleshooting

**"Something went wrong" / the window never appears.** Open the newest file in `logs\`. The
first lines say why. Common cases:

- *Running scripts is disabled / Constrained Language Mode.* The launcher already passes
  `-ExecutionPolicy Bypass`. If your IT policy also forces Constrained Language Mode, the window
  cannot be built, and the tool automatically falls back to console mode, which still compresses
  with the `settings.json` defaults.
- *"This app has been blocked by your system administrator" / AppLocker.* The PC refuses to run
  any `.exe` from removable drives. No software can work around that; try copying the folder to
  your Documents folder, which some policies allow.
- *Antivirus quarantines ffmpeg.exe.* Restore it or ask IT to whitelist it; it is the standard
  open-source build from gyan.dev / BtbN.

**The video will not play on the work PC.** Windows' built-in player needs the free "HEVC Video
Extensions from Device Manufacturer" from the Microsoft Store, which you may not be able to
install. VLC, Chrome and Edge play it. If the recipient cannot play HEVC, choose **H.264**.

**It is slow.** Two passes at the Balanced preset take roughly 1 to 3 times the video's length on
a typical office laptop. Pick **Fast** for a quick result; the size target is unaffected.

**Output is still over the limit.** Rare, and reported in the Status column. Lower the limit by
a megabyte and run again.

**HDR / 10-bit phone videos** are converted to standard 8-bit colour without tone mapping, so
very bright scenes may look flatter than the original. Fine for sharing, mentioned for honesty.

## Development

- Scripts target Windows PowerShell 5.1 syntax so they run on stock Windows; they also run on
  PowerShell 7 on Linux/macOS for testing (with `ffmpeg` on PATH).
- `tests\Run-Tests.ps1` runs planner unit tests and end-to-end encodes against synthetic clips
  generated by `tests\Make-Fixtures.ps1` (no downloads). `-SkipEncode` runs only the unit tests.
- GitHub Actions runs the suite under Windows PowerShell 5.1 and PowerShell 7, and a `v*` tag
  builds `Video-compressor-win64.zip` with ffmpeg included.
- `tools\Build-Package.ps1` builds the same zip locally.

## Licences

The scripts in this repository are MIT licensed. `ffmpeg.exe` is a GPL build from
gyan.dev or BtbN; its licence text is copied into `bin\FFMPEG-LICENSE.txt` by the download script.
