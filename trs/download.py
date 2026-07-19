"""Download the audio track of a video URL (YouTube, etc.) to a file.

Uses yt-dlp + ffmpeg. The output file extension selects the codec
(.wav, .mp3, .m4a, .flac, .opus). Slice/clean it afterward with ffmpeg.

Example:
    uv run --project transcribe python transcribe/download.py \\
        "https://youtu.be/XXXXXXXXXXX" -o samples/raw.wav
"""

import argparse
from pathlib import Path

import yt_dlp


def download(url: str, output: Path, js_runtime: str = "node") -> Path:
    """Download url's best audio and transcode to output (codec from suffix)."""
    codec = (output.suffix.lstrip(".") or "wav").lower()
    opts = {
        "format": "bestaudio/best",
        # postprocessor rewrites the extension to `codec`, so give it the stem
        "outtmpl": str(output.with_suffix("")) + ".%(ext)s",
        "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": codec}],
        # yt-dlp only enables deno by default; node/bun must be opted in.
        # The API form is a dict {runtime: {config}}; {} = auto-find on PATH.
        "js_runtimes": {js_runtime: {}},
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    return output.with_suffix("." + codec)


def main():
    p = argparse.ArgumentParser(
        description="Download a video URL's audio to a file (yt-dlp + ffmpeg).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("url", help="video URL (YouTube, etc.)")
    p.add_argument("-o", "--output", type=Path, default=Path("audio.wav"),
                   help="output audio file; extension selects the codec")
    p.add_argument("--js-runtime", default="node",
                   help="JS runtime for YouTube extraction (node, bun, deno, quickjs)")
    args = p.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    final = download(args.url, args.output, args.js_runtime)
    print(f"wrote {final}")


if __name__ == "__main__":
    main()
