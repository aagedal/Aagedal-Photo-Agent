"""Private JSON bridge. Run with the app's isolated, relocatable Python, never system Python."""
import contextlib
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import signal
import ssl
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

PROTOCOL = 1
PACKAGES = ("gallery-dl", "yt-dlp")
child = None


def stop(signum, frame):
    # Include yt-dlp's FFmpeg and pip children in cancellation; inherited pipes
    # must not keep the Swift process boundary waiting after Python exits.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.killpg(os.getpgrp(), signal.SIGTERM)
    if child is not None:
        child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
    raise TimeoutError("Web download cancelled or timed out")


def post_url(value):
    parsed = urllib.parse.urlsplit(value.strip())
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port:
        raise ValueError("Paste an HTTPS Instagram or X post URL")
    host = (parsed.hostname or "").lower()
    if host in ("instagram.com", "www.instagram.com"):
        match = re.fullmatch(r"/(p|reel)/([A-Za-z0-9_-]+)/?", parsed.path)
        if match:
            return f"https://www.instagram.com/{match[1]}/{match[2]}/"
    elif host in ("x.com", "www.x.com", "twitter.com", "www.twitter.com"):
        match = re.fullmatch(r"/([A-Za-z0-9_]+)/status/(\d+)(?:/photo/\d+)?/?", parsed.path)
        if match:
            return f"https://x.com/{match[1]}/status/{match[2]}"
    raise ValueError("This version supports individual Instagram and X posts")


def versions():
    from gallery_dl import job
    from yt_dlp import YoutubeDL
    if not callable(job.DownloadJob) or not callable(YoutubeDL):
        raise ValueError("Incompatible downloader packages")
    return {name: importlib.metadata.version(name) for name in PACKAGES}


def fetch_json(url):
    # Standalone Python cannot assume a machine-specific CA certificate path.
    from pip._vendor import certifi
    with urllib.request.urlopen(url, timeout=30, context=ssl.create_default_context(cafile=certifi.where())) as response:
        return json.load(response)


def available():
    result = {}
    for name in PACKAGES:
        data = fetch_json(f"https://pypi.org/pypi/{name}/json")
        required = data["info"].get("requires_python")
        from pip._vendor.packaging.specifiers import SpecifierSet
        from pip._vendor.packaging.version import Version
        if required and Version(".".join(map(str, sys.version_info[:3]))) not in SpecifierSet(required):
            raise ValueError(f"{name} needs a newer Python runtime. Update Photo Agent first.")
        result[name] = data["info"]["version"]
    return result


def extract_wheel(wheel, destination):
    with zipfile.ZipFile(wheel) as archive:
        for entry in archive.infolist():
            path = Path(entry.filename)
            if path.is_absolute() or ".." in path.parts or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("Unsafe package archive")
            if path.suffix in (".so", ".dylib"):
                raise ValueError("Downloader updates must contain pure Python packages")
        archive.extractall(destination)


def update(destination, requested, locked_artifacts=None):
    global child
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Update destination already exists")
    for name in PACKAGES:
        if not re.fullmatch(r"[0-9][A-Za-z0-9.+_-]{0,60}", requested[name]):
            raise ValueError("Invalid package version")
    with tempfile.TemporaryDirectory() as temporary:
        # Resolve compatible, pure Python wheels only. No source builds or install hooks.
        command = [sys.executable, "-I", "-m", "pip", "--isolated", "download", "--disable-pip-version-check",
                   "--no-cache-dir", "--only-binary=:all:", "--platform", "any", "--dest", temporary,
                   "--index-url", "https://pypi.org/simple"]
        if locked_artifacts is not None:
            command += ["==".join(item["filename"].split("-")[:2]) for item in locked_artifacts]
        else:
            command += [f"{name}=={requested[name]}" for name in PACKAGES]
        child = subprocess.Popen(command, stdout=sys.stderr, stderr=sys.stderr)
        try:
            if child.wait(timeout=240):
                raise ValueError("Could not resolve compatible downloader packages")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            child = None
        wheels = sorted(Path(temporary).glob("*.whl"))
        if not wheels:
            raise ValueError("No downloader packages received")
        artifacts = []
        for wheel in wheels:
            name, version = wheel.name.split("-")[:2]
            release = fetch_json(f"https://pypi.org/pypi/{name}/{version}/json")
            matching = [item for item in release["urls"] if item["filename"] == wheel.name]
            digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
            if len(matching) != 1 or digest != matching[0]["digests"]["sha256"]:
                raise ValueError(f"Package checksum mismatch: {wheel.name}")
            artifacts.append({"filename": wheel.name, "sha256": digest})
        if locked_artifacts is not None and sorted(artifacts, key=lambda item: item["filename"]) != sorted(locked_artifacts, key=lambda item: item["filename"]):
            raise ValueError("Prepared packages do not match the committed baseline lock")
        destination.mkdir(parents=True)
        for wheel in wheels:
            extract_wheel(wheel, destination)
        (destination / "packages.json").write_text(json.dumps({"versions": requested, "artifacts": artifacts}, indent=2))
    return requested


def configure(request):
    from gallery_dl import config
    # Do not load user configs: they can contain hooks, postprocessors or different destinations.
    config.clear()
    config.set(("extractor",), "timeout", 30)
    config.set(("extractor",), "retries", 2)
    config.set(("extractor", "instagram"), "previews", False)
    config.set(("extractor", "instagram"), "order-files", "asc")
    config.set(("downloader", "ytdl"), "module", "yt_dlp")
    ffmpeg = request.get("ffmpeg")
    if ffmpeg:
        config.set(("downloader", "ytdl"), "raw-options", {"ffmpeg_location": ffmpeg, "quiet": True})
    if request.get("cookies"):
        config.set(("extractor",), "cookies", request["cookies"])


def media_record(url, metadata, fallback):
    user = metadata.get("user") or {}
    if not isinstance(user, dict):
        user = {}
    number = int(metadata.get("num") or fallback)
    post_id = str(metadata.get("post_id") or metadata.get("tweet_id") or metadata.get("id") or "")
    media_id = str(metadata.get("media_id") or metadata.get("id") or post_id)
    extension = str(metadata.get("extension") or "")
    video = extension in ("mp4", "webm", "mov", "mkv") or url.startswith("ytdl:")
    date = metadata.get("post_date") or metadata.get("date")
    return {"id": f"{post_id}:{media_id}:{number}", "position": number,
            "kind": "video" if video else "image", "downloadURL": url,
            "width": int(metadata.get("width") or 0), "height": int(metadata.get("height") or 0),
            "username": str(metadata.get("username") or user.get("name") or ""),
            "displayName": str(metadata.get("fullname") or user.get("nick") or ""),
            "description": str(metadata.get("description") or metadata.get("content") or ""),
            "publishedAt": date.isoformat() if hasattr(date, "isoformat") else str(date or ""),
            "postID": post_id, "extension": extension}


def inspect(request):
    from gallery_dl import job

    class Collector(job.Job):
        def __init__(self, url):
            super().__init__(url)
            self.items = []

        def handle_url(self, url, metadata):
            if len(self.items) >= 100:
                raise ValueError("Post contains too many media items")
            self.items.append(media_record(url, metadata, len(self.items) + 1))

        def handle_queue(self, url, metadata):
            raise ValueError("Linked posts are not imported automatically")

    collector = Collector(post_url(request["url"]))
    if collector.run() or not collector.items:
        raise ValueError("Could not read this post. It may require a cookies file, or a downloader update.")
    return {"url": post_url(request["url"]), "items": collector.items, "versions": versions()}


def download(request):
    from gallery_dl import config, job
    expected = {item["id"]: item for item in request["items"]}
    if not expected or len(expected) > 100:
        raise ValueError("Select media to download")
    destination = Path(request["destination"])
    if not destination.is_dir() or any(destination.iterdir()):
        raise ValueError("Download requires an empty staging directory")
    config.set(("extractor",), "base-directory", str(destination))
    config.set(("extractor",), "directory", [])
    config.set(("extractor",), "filename", "{num:03}.{extension}")
    config.set(("output",), "mode", "null")

    class SelectedDownload(job.DownloadJob):
        def __init__(self, url):
            super().__init__(url)
            self.files = []

        def handle_url(self, url, metadata):
            record = media_record(url, metadata, len(self.files) + 1)
            if record["id"] not in expected:
                return
            super().handle_url(url, metadata)
            path = Path(self.pathfmt.realpath).resolve()
            if path.parent != destination.resolve() or not path.is_file() or path.is_symlink():
                raise ValueError("Media download failed")
            self.files.append({"item": record, "filename": path.name})

        def handle_queue(self, url, metadata):
            raise ValueError("Linked posts are not imported automatically")

    downloader = SelectedDownload(post_url(request["url"]))
    if downloader.run() or {entry["item"]["id"] for entry in downloader.files} != set(expected):
        raise ValueError("Some selected media could not be downloaded. Inspect the post again and retry.")
    return {"files": downloader.files, "versions": versions()}


def main():
    os.setpgrp()
    request = json.loads(Path(sys.argv[1]).read_text())
    packages = Path(request["packages"])
    sys.path.insert(0, str(packages))
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGALRM, stop)
    signal.alarm(1800 if request["action"] == "download" else (30 if request["action"] == "versions" else 300))
    with contextlib.redirect_stdout(sys.stderr):
        action = request["action"]
        if action == "versions":
            result = versions()
        elif action == "available":
            result = available()
        elif action == "update":
            result = update(request["destination"], request["versions"], request.get("lockedArtifacts"))
        else:
            configure(request)
            result = inspect(request) if action == "inspect" else download(request)
    print(json.dumps({"protocol": PROTOCOL, "result": result}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not relay downloader logs, signed media URLs or credentials to the UI.
        print(json.dumps({"protocol": PROTOCOL, "error": str(error)[:500]}))
        sys.exit(1)
