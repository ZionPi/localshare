#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
import time
import urllib.request
import webbrowser


def discover(service: str, timeout: float) -> str:
    command = ["dns-sd", "-L", service, "_http._tcp", "local"]
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        raise RuntimeError("dns-sd not found. Install Bonjour / Apple Bonjour Print Services.")

    pattern = re.compile(r"can be reached at\s+(.+?)\.?\s*:\s*(\d+)")
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            line = process.stdout.readline() if process.stdout else ""
            if not line:
                time.sleep(0.05)
                continue
            match = pattern.search(line)
            if not match:
                continue
            host = match.group(1).rstrip(".")
            port = match.group(2)
            return f"http://{host}:{port}/"
    finally:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()

    raise RuntimeError(f"Timed out after {timeout:g}s waiting for {service}._http._tcp.local")


def touch(url: str, timeout: float) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "localshare-discover/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        response.read(1)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Discover LocalShare over Bonjour/mDNS and visit it once."
    )
    parser.add_argument("--service", default="localshare", help="DNS-SD service instance name")
    parser.add_argument("--timeout", type=float, default=10, help="Discovery/request timeout seconds")
    parser.add_argument("--open", action="store_true", help="Open the discovered URL in a browser")
    parser.add_argument("--no-touch", action="store_true", help="Only print the discovered URL")
    args = parser.parse_args()

    try:
        url = discover(args.service, args.timeout)
        print(url)
        if not args.no_touch:
            touch(url, args.timeout)
        if args.open:
            webbrowser.open(url)
    except Exception as error:
        print(f"localshare-discover: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
