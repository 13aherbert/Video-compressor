# Video Compressor (portable, flash-drive edition)

Shrinks videos to **under a size limit you choose (default 40 MB)** while keeping as much
quality as the limit allows. Runs from a flash drive on a locked-down Windows 10/11 PC:

- **Nothing to install.** No admin rights, no .NET runtime download, no registry changes.
- It uses the same encoders HandBrake uses (x265 / x264) through a single dependency-free
  `ffmpeg.exe`, and a small window built on the PowerShell and .NET Framework that are already
  part of Windows. (HandBrake's portable build needs the newer .NET 6/8 runtime; this does not.)
- **HandBrake-style quality setting** (RF, default 32), with the size limit always winning.
- **Never goes below 720p.** When a video is too long to fit, the bitrate drops instead of the
  resolution.
- Drag-and-drop, a preview of what will happen to each file, progress bars, Cancel.

```
Video-compressor\
  Compress-Videos.bat   <- double-click, or drop videos / folders onto it
  settings.json         <- defaults (limit, quality, codec, speed, output folder)
  bin\ffmpeg.exe        <- included in the release zip (or downloaded on first run)
  src\                  <- the PowerShell scripts
  logs\                 <- one log per run, with the exact ffmpeg commands
```

## Setup (one step)

1. On the repository's **Releases** page, download **`Video-compressor-win64.zip`**. It already
   contains ffmpeg.
2. Right-click the zip, choose **Properties**, tick **Unblock**, click OK. (Windows otherwise marks
   downloaded scripts as untrusted.)
3. Unzip it onto the flash drive. You need about 250 MB free. Any drive format works.
4. Try it once at home: double-click `Compress-Videos.bat`, add a short video, click **Start**.

Downloaded the repository as a plain "Download ZIP" instead? That works too: the first time you
run `Compress-Videos.bat` on a computer with internet, it downloads ffmpeg into `bin\` by itself
(about 115 MB, once). Do that at home, then copy the finished folder to the flash drive.

## Install on your computer (no flash drive needed)

The tool runs from any folder you can write to, so you can keep it on the work PC itself.

1. Get `Video-compressor-win64.zip` onto the computer (download it, or copy it over from a flash drive).
2. Right-click the zip, choose **Properties**, tick **Unblock**, click OK. Unzip it anywhere, for example
   in Downloads.
3. Double-click **`Install.bat`** inside the unzipped folder.

The installer needs no admin rights and changes nothing in the registry. It:

- tries these folders in order and uses the first one Windows allows programs to run from:
  `%LOCALAPPDATA%\Video Compressor` (usually `C:\Users\<you>\AppData\Local\Video Compressor`), then
  `%USERPROFILE%\Video Compressor`, then `Documents\Video Compressor`;
- copies the app there and checks that ffmpeg and the app really start from that folder;
- puts a **Video Compressor** icon on your Desktop and a **Video Compressor** entry in the right-click
  **Send to** menu;
- writes an `Uninstall.bat` into the install folder.

Afterwards, start it from the Desktop icon, or select videos or folders in Explorer, right-click, choose
**Send to**, then **Video Compressor**, and they load straight into the window. Send to hands the file
names over on a command line, which Windows limits to roughly 8,000 characters. A few dozen files is
fine; for hundreds, drag the folder onto the window instead.

**Updating:** download the new zip and run its `Install.bat` again. Your settings and logs are kept; the
program files are replaced. Close the Video Compressor window first.

**Uninstalling:** run `Uninstall.bat` in the install folder. It asks first, removes the two shortcuts and
the folder, and never touches your compressed videos (those are in your own `Encoded` folders). It refuses
to delete any folder that was not put there by the installer.

**If the PC will not allow it:** some company policies only let programs run from approved places. The
installer then says exactly what Windows refused, removes the half-made copy, and leaves nothing behind.
You can keep using the flash drive, or ask IT to allow one of the folders above. To choose another
folder yourself, run
`powershell -ExecutionPolicy Bypass -File tools\Install.ps1 -Target "D:\Tools\Video Compressor"`.
The installer will not use a drive root, the Windows folder, your Desktop or Documents folder
themselves, or a folder that already holds other files.

If you would rather not install anything, the portable folder still works exactly as before: just run
`Compress-Videos.bat` from wherever the folder is.

## Daily use

1. Plug in the drive and double-click `Compress-Videos.bat`, or drop video files or a folder
   straight onto the `.bat` file.
2. The window lists each file with what it will do: output resolution, frame rate, quality or
   bitrate, estimated size and a **quality grade** (Good / OK / Poor). Change the limit, quality,
   codec or speed and the preview updates immediately.
3. Click **Start**. Compressed files go into an **`Encoded`** folder next to each original, with the
   same name (`Beach.mov` becomes `Encoded\Beach.mp4`). You can change the folder and the name, see
   below. Originals are never modified or overwritten.
4. Watch the two labelled progress bars at the bottom: **Current file** and **Whole queue**. Each
   shows its percentage, the time elapsed, and an estimate of the time left.

## How the quality setting works

Same idea as HandBrake's **RF** slider: lower numbers look better and make bigger files, higher
numbers make smaller files. 30 to 35 is typical; the default is 32.

For each video the tool:

1. **Encodes at your quality (RF 32).** If the result is under the limit, it keeps it, even if
   that is only 8 MB. A short clip ends up small and clean, exactly like HandBrake.
2. **If that is too big,** it throws that attempt away (it stops early, as soon as it is clear
   the file cannot fit) and re-encodes in two passes at the exact bitrate that fits under the
   limit. That is what guarantees the 40 MB cap, which HandBrake's quality slider cannot.

Tick **Use the full size limit (two-pass)** if you would rather always get the best quality that
fits in 40 MB, with every file landing close to the limit.

For H.264 the tool automatically uses RF minus 6, because x264's scale is shifted compared with
x265. You do not need to adjust anything when you switch codec.

### Resolution rule

The tool never creates anything below 720p. It lowers the **bitrate** first, and only steps from
2160p or 1440p down toward 1080p and 720p when the bitrate would otherwise be tiny. A source that
is already smaller than 720p keeps its own size (it is never upscaled).

The honest consequence: a long video at 40 MB at 720p gets a low bitrate and looks rough. The
quality grade says so (Poor), and the preview shows it before you start. For long recordings,
trim or split them first, or raise the limit.

### What to expect at 40 MB (1080p30 source, HEVC)

This is the worst case, the bitrate used when your quality setting does not fit and the tool has
to squeeze to the limit. Many files will come out smaller and better than this.

| Length  | Output     | Bitrate to fit | Grade |
|---------|------------|----------------|-------|
| 1 min   | 1920x1080  | ~5000 kbps     | Good  |
| 2 min   | 1920x1080  | ~2500 kbps     | Good  |
| 3 min   | 1920x1080  | ~1600 kbps     | Good  |
| 5 min   | 1280x720   | ~940 kbps      | Good  |
| 10 min  | 1280x720   | ~450 kbps      | Good  |
| 15 min  | 1280x720   | ~300 kbps      | OK    |
| 20 min  | 1280x720   | ~230 kbps      | Poor  |
| 30 min+ | 1280x720   | under 150 kbps | Poor  |

### Where the files go: folder and name templates

The **Output folder** and **File name** boxes are templates, like HandBrake's auto-naming. Click
**Variables...** to insert one where the cursor is. The grey **Example** line under the boxes shows
the real path for the selected file as you type.

| Variable | Becomes | Example |
|----------|---------|---------|
| `{source}` | original file name, without extension | `Beach` |
| `{sourcefolder}` | name of the folder the original is in | `Holiday` |
| `{date}` | date the batch started | `2026-10-02` |
| `{time}` | time the batch started | `17-45-09` |
| `{datetime}` | both | `2026-10-02_17-45-09` |
| `{codec}` | `hevc` or `h264` | `hevc` |
| `{quality}` | the Quality (RF) number | `32` |
| `{mode}` | `quality` or `fill` | `quality` |
| `{limit}` | the size limit | `40MB` |
| `{width}` `{height}` | size of the compressed video | `1280` `720` |

Examples:

| Output folder | File name | Result for `D:\Clips\Holiday\Beach.mov` |
|---------------|-----------|-----------------------------------------|
| `Encoded` (default) | `{source}` (default) | `D:\Clips\Holiday\Encoded\Beach.mp4` |
| *(empty)* | `{source}.compressed` | `D:\Clips\Holiday\Beach.compressed.mp4` |
| `D:\Compressed\{date}` | `{source}_{height}p` | `D:\Compressed\2026-10-02\Beach_720p.mp4` |
| `Encoded\{codec}` | `{sourcefolder} - {source}` | `D:\Clips\Holiday\Encoded\hevc\Holiday - Beach.mp4` |

Rules:
- A **relative** folder (like `Encoded`) is created next to *each* original, so a batch from several
  folders gets an `Encoded` in every one. A **full path** (like `D:\Compressed`) is used as is.
  Leave it empty to save next to the original.
- The extension is always `.mp4`.
- An existing file is **never overwritten**, and neither is the original: a number is added instead
  (`Beach (2).mp4`).
- Characters Windows does not allow in names are removed. A mistyped variable such as `{sorce}` is
  flagged in red under the boxes and stops the run with a message that lists the valid ones; it is
  never silently dropped.
- If the folder cannot be created (for example the original is on read-only media) that file fails
  with a message saying so. Choose a full path such as `C:\Videos\Encoded` in that case.
- `{date}` and `{time}` are taken when you click Start, so a whole batch shares the same value.

Your choices are remembered in `settings.json` (`outputFolder` and `fileName`). Settings files from
older versions are converted automatically: the old "next to the original" choice becomes the new
`Encoded` default, and an old custom folder or suffix is kept.

### Elapsed time and time left

Under each progress bar you see **Elapsed** and an estimate of the time left, for the current file and
for the whole queue. The estimate is based on how fast your computer is actually encoding, and it
corrects itself as it goes. It says *calculating...* for the first couple of seconds. In quality mode
it can move around: if a file turns out too big at your quality setting, the tool switches to the
two-pass fit and the estimate grows to match. Treat it as a guide, not a promise. The console shows the
same information, and a final "Finished N files in 12:30" line.

### Options in the window

| Option | Meaning |
|--------|---------|
| Max size (MB) | Hard limit. Counted as 1 MB = 1,000,000 bytes with a 3 % safety margin, so the file is under 40 MB however the receiving system counts. |
| Codec | **HEVC (H.265)**: 30 to 40 % better quality per MB. Plays in VLC, phones, Macs, Chrome, Edge and Windows 10/11 with the HEVC Video Extensions. **H.264**: plays on absolutely anything, lower quality per MB. |
| Speed | Fast / Balanced / Best quality = encoder presets fast / medium / slow. Slower presets squeeze a little more quality into the same bytes. |
| Max resolution | Auto, 1080p or 720p. Nothing lower is offered. |
| Quality (RF) | See above. Default 32. |
| Use the full size limit | Skips the quality attempt and always runs the two-pass encode. |
| Output folder, File name | Templates for where each file goes and what it is called. See above. |
| Also re-encode files already under the limit | Off by default: small files are skipped untouched. |

Settings you change in the window are remembered in `settings.json` when you click Start.

### Console mode

If the window cannot open (see Troubleshooting) the tool automatically runs in the console with
the defaults from `settings.json`: drop files onto the `.bat` and watch the progress text.
You can also run it by hand:

```
Compress-Videos.bat "D:\clips\a.mp4" "D:\clips\b.mov"
powershell -ExecutionPolicy Bypass -File src\Main.ps1 -NoGui -TargetMB 25 -Quality 34 "D:\clips\a.mp4"
powershell -ExecutionPolicy Bypass -File src\Main.ps1 -NoGui -Mode fill -Codec h264 "D:\clips\a.mp4"
powershell -ExecutionPolicy Bypass -File src\Main.ps1 -NoGui -OutputFolder "D:\Compressed\{date}" -NameTemplate "{source}_{height}p" "D:\clips\a.mp4"
```

## How it decides

1. Reads the file with `ffprobe` (length, size, resolution, frame rate, audio).
2. Budget = limit minus a 3 % margin for container overhead.
3. Audio: AAC 96 kbps stereo, stepping down to 64 / 48 / 32 kbps mono only when audio would
   eat more than 15 % of the budget. Mono sources stay mono.
4. Fallback video bitrate = whatever is left, divided by the length. Never higher than the
   source's bitrate, so small files are not inflated.
5. Frame rates above 30 fps are halved only if the bits per pixel would otherwise be very low
   (60 to 30, 50 to 25). Resolution steps down 2160 / 1440 / 1080 / 720 only below a low
   bits-per-pixel threshold (HEVC 0.02, H.264 0.04), and never below 720.
6. Encodes (`libx265` or `libx264`, `yuv420p`, `+faststart`, HEVC tagged `hvc1` so Apple devices
   play it). Scratch files go to the local `%TEMP%` folder, not the flash drive.
7. Verifies the size. A two-pass result that is still over is re-run at a proportionally lower
   bitrate (up to 2 retries).

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
- *"ffmpeg is missing and could not be downloaded."* The folder has no `bin\ffmpeg.exe` and this
  computer has no internet. Use the release zip, or run the tool once at home first.

**The video will not play on the work PC.** Windows' built-in player needs the free "HEVC Video
Extensions from Device Manufacturer" from the Microsoft Store, which you may not be able to
install. VLC, Chrome and Edge play it. If the recipient cannot play HEVC, choose **H.264**.

**It is slow.** A quality-mode file that fits is a single pass, so it is usually faster than the
old two-pass. A file that has to fall back costs the aborted quality attempt plus two passes.
Pick **Fast** for a quick result; the size target is unaffected.

**Output is still over the limit.** Rare, and reported in the Status column. Lower the limit by
a megabyte and run again.

**HDR / 10-bit phone videos** are converted to standard 8-bit colour without tone mapping, so
very bright scenes may look flatter than the original. Fine for sharing, mentioned for honesty.

## Development

- Scripts target Windows PowerShell 5.1 syntax so they run on stock Windows; they also run on
  PowerShell 7 on Linux/macOS for testing (with `ffmpeg` on PATH).
- `tests\Run-Tests.ps1` runs planner unit tests and end-to-end encodes against synthetic clips
  generated by `tests\Make-Fixtures.ps1` (no downloads). `-SkipEncode` runs only the unit tests.
- GitHub Actions runs the suite under Windows PowerShell 5.1 and PowerShell 7. Pushing a tag such
  as `v1.0.0` builds `Video-compressor-win64.zip` with ffmpeg included and attaches it to a
  GitHub Release.
- `tools\Build-Package.ps1` builds the same zip locally.

## Licences

The scripts in this repository are MIT licensed. `ffmpeg.exe` and `ffprobe.exe` are GPL builds
from gyan.dev or BtbN, which include the x264 and x265 encoders; see `bin\NOTICE.txt` for the
licence and source links, and `bin\FFMPEG-LICENSE.txt` for the licence text of the exact build.
