import os
import time
import json
import requests

REPO = "arif-banai/MusicBot"
API_URL = f"https://api.github.com/repos/{REPO}/releases/latest"
WEBHOOK_URL = os.environ.get("DISCORD_RELEASE_WEBHOOK_URL")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "900"))
STATE_FILE = os.environ.get("STATE_FILE", "/data/last_release.json")


def load_last_seen():
    try:
        with open(STATE_FILE) as f:
            return json.load(f).get("tag")
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_last_seen(tag):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump({"tag": tag}, f)


def fetch_latest_release():
    resp = requests.get(
        API_URL, headers={"Accept": "application/vnd.github+json"}, timeout=15
    )
    resp.raise_for_status()
    return resp.json()


def post_release(release):
    if not WEBHOOK_URL:
        print(
            "[release-notifier] No DISCORD_RELEASE_WEBHOOK_URL set, "
            f"would have posted: {release.get('tag_name')}"
        )
        return
    body = release.get("body") or "(no release notes provided)"
    if len(body) > 3500:
        body = body[:3500] + "…"
    payload = {
        "embeds": [
            {
                "title": f"JMusicBot {release.get('tag_name')} released",
                "url": release.get("html_url"),
                "description": body,
                "color": 0x5865F2,
            }
        ]
    }
    resp = requests.post(WEBHOOK_URL, json=payload, timeout=10)
    resp.raise_for_status()


def main():
    last_seen = load_last_seen()
    first_run = last_seen is None
    print(f"[release-notifier] Starting. Last seen release: {last_seen}")

    while True:
        try:
            release = fetch_latest_release()
            tag = release.get("tag_name")
            if tag and tag != last_seen:
                if first_run:
                    # Don't blast a "new release" post for whatever was
                    # already current the first time this container runs --
                    # just record it as the baseline.
                    print(f"[release-notifier] Recording baseline release: {tag}")
                else:
                    print(f"[release-notifier] New release detected: {tag}")
                    post_release(release)
                save_last_seen(tag)
                last_seen = tag
                first_run = False
        except Exception as e:
            print(f"[release-notifier] Error checking releases: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
