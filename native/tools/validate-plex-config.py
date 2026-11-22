"""Validate a Plex endpoint and produce a private, local configuration file."""
import argparse
import getpass
import os
from pathlib import Path
import plistlib
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import warnings
import xml.etree.ElementTree as ET


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def read_xml(opener, origin, endpoint, token=None):
    headers = {"Accept": "application/xml", "X-Plex-Client-Identifier": "RevivePlex-AppleTV3"}
    if token:
        headers["X-Plex-Token"] = token
    request = urllib.request.Request(origin + endpoint, headers=headers)
    with opener.open(request, timeout=8) as response:
        body = response.read(1024 * 1024 + 1)
    if len(body) > 1024 * 1024 or b"\0" in body or b"<!DOCTYPE" in body.upper():
        raise ValueError("Unexpected XML")
    root = ET.fromstring(body)
    if root.tag != "MediaContainer":
        raise ValueError("Unexpected XML")
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("https_origin")
    parser.add_argument("--gui", action="store_true", help="Use a hidden macOS input dialog.")
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.https_origin)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or
            parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        parser.error("Supply the verified HTTPS server origin only.")
    origin = args.https_origin.rstrip("/")
    directory = Path.home() / "Library/Application Support/RevivePlex"
    output = directory / "org.revivetv.plex.local.plist"
    if output.exists():
        parser.error("A local configuration already exists.")
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    stage = "Server identity"
    try:
        read_xml(opener, origin, "/identity")
        stage = "Hidden token input"
        if args.gui:
            command = [
                "/usr/bin/osascript",
                "-e", 'text returned of (display dialog "Plex erişim anahtarı" '
                'default answer "" with hidden answer with title "RevivePlex" '
                'buttons {"İptal", "Doğrula"} default button "Doğrula" cancel button "İptal")',
            ]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            if result.returncode:
                parser.exit(1, "Hidden token input cancelled or unavailable. No configuration was saved.\n")
            token = result.stdout.strip()
        else:
            if not os.isatty(0):
                parser.error("Use an interactive local Terminal.")
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                token = getpass.getpass("Plex access token (hidden): ").strip()
        if not token or any(ord(char) < 33 or ord(char) > 126 for char in token):
            raise ValueError("Invalid credential")
        stage = "Authenticated library"
        read_xml(opener, origin, "/library/sections", token)
    except urllib.error.HTTPError as error:
        parser.exit(1, f"{stage}: Plex returned HTTP {error.code}. No configuration was saved.\n")
    except urllib.error.URLError as error:
        if isinstance(error.reason, ssl.SSLCertVerificationError):
            detail = "TLS certificate verification failed"
        elif isinstance(error.reason, ssl.SSLError):
            detail = "TLS negotiation failed"
        else:
            detail = "network connection failed"
        parser.exit(1, f"{stage}: {detail}. No configuration was saved.\n")
    except (EOFError, getpass.GetPassWarning):
        parser.exit(1, f"{stage}: secure input unavailable. No configuration was saved.\n")
    except (OSError, ValueError, ET.ParseError) as error:
        parser.exit(1, f"{stage}: {type(error).__name__}. No configuration was saved.\n")
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as file:
        plistlib.dump({"origin": origin, "token": token}, file)
    print("Authenticated library request verified. Private configuration saved locally.")


if __name__ == "__main__":
    main()
