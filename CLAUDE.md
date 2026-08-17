# JMusicBot Deploy — Instructions for Claude Code

## Goal
Deploy arif-banai/MusicBot (a fork of JMusicBot) as its own isolated Docker
pod on this Ubuntu machine, auto-starting on boot via systemd, and
auto-updating whenever the upstream repo publishes a new `latest` image via
Watchtower. Also runs a small sidecar that posts new upstream release notes
to a Discord channel.

This bot is unrelated to any other Docker stack on this machine (e.g. the
Twitch chat game, or the shared observability stack). Keep it fully
isolated: separate directory, separate container names, no shared networks
unless asked.

Dashboard/alerting for this container is handled separately by the shared
`observability` repo/stack (monitors this container by name alongside the
Twitch bot and host health) — not duplicated here. The release-notifier
below is a distinct thing: informational changelog posts to a channel, not
an alert, and posts via a plain webhook rather than the alerting bot.

## Files provided
- `docker-compose.yml` — jmusicbot, release-notifier, watchtower services
- `jmusicbot.service` — systemd unit to bring the stack up on boot
- `release-notifier/` — Dockerfile, notifier.py, requirements.txt
- `.github/workflows/build-and-push.yml` — builds/pushes the
  release-notifier image to GHCR on push to `main`
- `.env.example` — template for the release-notes webhook URL

## Steps

1. **Put these files in their own git repo** (e.g. `jmusicbot-deploy`) and
   push to GitHub. Ask the user for repo name/visibility if not obvious; a
   private repo is a reasonable default. This repo now has a real CI
   pipeline (unlike before) since it builds and publishes the
   release-notifier image — the jmusicbot image itself still comes straight
   from upstream (`ghcr.io/arif-banai/musicbot`), only the notifier is
   built here.

2. **After the first push, make the GHCR package public.** Same reasoning
   as the observability stack: Watchtower on this host pulls anonymously,
   no registry credentials configured. On GitHub: pushed repo > Packages >
   `jmusicbot-release-notifier` > Package settings > Change visibility >
   Public. Confirm the Actions run succeeded first (Actions tab) before
   flipping visibility.

3. **Check prerequisites.** Confirm Docker and the Docker Compose plugin are
   installed (`docker --version`, `docker compose version`). If missing,
   install Docker Engine via the official apt repo (not snap), then add the
   invoking user to the `docker` group if not already a member.

4. **Create the deploy directory on the Ubuntu machine.**
   ```
   mkdir -p $HOME/docker/jmusicbot
   ```
   No `sudo` needed, and deliberately under `$HOME` rather than `/opt`:
   this host runs Docker Desktop, which only bind-mounts paths explicitly
   shared with its VM (home directory is shared by default; `/opt` is
   not) — the existing Twitch bot deploy uses the same pattern. Copy
   `docker-compose.yml` and `.env.example` in (via `git clone` of the new
   repo, or by copying the files directly — either is fine). The
   `release-notifier/` source and workflow don't need to live on the host;
   they live in the repo, the host just needs the compose file that
   references the published image.

5. **Edit `docker-compose.yml`:** replace
   `ghcr.io/REPLACE_WITH_GITHUB_OWNER/jmusicbot-release-notifier:latest`
   with the real GitHub owner the repo was pushed under (must be
   lowercase — GHCR rejects mixed-case image names even if the actual
   GitHub username isn't lowercase; the build workflow lowercases it too).

6. **Do NOT deploy a Watchtower service for this stack.** Confirmed by
   direct experience on this host: `nickfedor/watchtower` actively hunts
   down and **removes** any other Watchtower container it finds, even ones
   with unique names and `--label-enable` scoping — it deleted the Twitch
   bot's Watchtower within seconds of a second instance starting.
   `docker-compose.yml` deliberately has no `watchtower` service for this
   reason. Instead: confirm a Watchtower is already running somewhere on
   this host (`docker ps --filter name=watchtower`), that it uses
   `--label-enable`, and that the `jmusicbot` and `release-notifier`
   services above carry `com.centurylinklabs.watchtower.enable=true` — that
   existing instance will pick them up on its next poll regardless of which
   compose project started them. If no Watchtower exists at all, redeploy
   the Twitch bot repo's `watchtower` service rather than adding one here.

7. **Get a release-notes webhook URL from the user.** This is a plain
   Discord webhook (not the alerting bot) into whatever channel they want
   changelog posts to show up in — could be the same "updates" channel as
   other projects, or its own. Discord: target channel > Edit Channel >
   Integrations > Webhooks > New Webhook > Copy Webhook URL. Copy
   `.env.example` to `.env` in `$HOME/docker/jmusicbot` and set
   `DISCORD_RELEASE_WEBHOOK_URL`. Don't guess or fabricate it.

8. **First run — generate the default jmusicbot config.**
   ```
   cd $HOME/docker/jmusicbot
   docker compose up -d jmusicbot
   ```
   This should create `$HOME/docker/jmusicbot/config.txt` on first
   launch. Confirm it exists.

9. **Get the Discord bot token from the user.** Do not invent or guess a
   token. Prompt the user to paste their Discord bot token, then write it
   into the `token` field of `$HOME/docker/jmusicbot/config.txt`.
   Also remind them
   that "Message Content Intent" must be enabled for the bot in the Discord
   Developer Portal (Bot > Privileged Gateway Intents) — this is a
   Discord-side setting, not something this script can do.

10. **Bring up the full stack.**
    ```
    docker compose up -d
    ```

11. **Verify.**
    - `docker ps` — `jmusicbot` and `jmusicbot-release-notifier` should both
      be `Up`. There should be exactly one Watchtower container on the
      whole host (not one per stack — see step 6).
    - `docker logs jmusicbot --tail 50` — check for a clean startup (bot
      logged in to Discord, no token/auth errors).
    - `docker logs jmusicbot-release-notifier --tail 20` — should show it
      recording a baseline release on first run (it deliberately doesn't
      post the currently-installed version as a "new release" the first
      time it starts, only ones detected after that).
    - Check the host's single Watchtower's logs on its next poll cycle —
      it should mention `jmusicbot` and `jmusicbot-release-notifier` as
      scanned/watched targets, with no "removed excess Watchtower
      containers" messages.

12. **Install the systemd unit as a user unit, not a system unit.**
    `sudo` isn't usable non-interactively on this host (no TTY available to
    this session), so this uses `systemctl --user` instead of
    `/etc/systemd/system`, which needs no root at all:
    ```
    mkdir -p ~/.config/systemd/user
    cp jmusicbot.service ~/.config/systemd/user/jmusicbot.service
    systemctl --user daemon-reload
    systemctl --user enable --now jmusicbot.service
    loginctl enable-linger $USER
    ```
    `enable-linger` (also no root needed for a user enabling it for
    themselves) makes the unit keep running after logout/without an active
    session — without it, user units stop when the last session ends.
    Note: the containers' own `restart: unless-stopped` policy handles
    crash recovery; the systemd unit exists so the compose stack comes up
    cleanly on boot and so `systemctl --user status jmusicbot` /
    `journalctl --user -u jmusicbot` give a clean operational view.

13. **Final check.**
    ```
    systemctl --user status jmusicbot
    ```
    Should show `active (exited)` with `RemainAfterExit=yes` — that's
    expected for a oneshot compose-up unit, not a failure.

14. **Point the observability stack at this container**, if not already
    done: the `observability` repo's `WATCH_CONTAINERS` env var should
    include `jmusicbot` by name. If that stack is already deployed, no
    action needed here — just confirm it's covered rather than assuming.

## Notes / constraints
- **Deviation from the original design**: this host runs Docker Desktop
  (LinuxKit VM), which only bind-mounts host paths explicitly shared with
  it — home directory is shared by default, `/opt` is not, and `sudo`
  isn't usable non-interactively here either. So the deploy dir is
  `$HOME/docker/jmusicbot`, not `/opt/jmusicbot`, matching the
  existing Twitch bot deploy's pattern.
- `config.txt` and any Playlists live in the bind-mounted
  `$HOME/docker/jmusicbot` directory on the host, NOT inside the
  container image — Watchtower pulling a new image never touches this data.
- The release-notifier's state (which release it last saw) lives at
  `$HOME/docker/jmusicbot/release-notifier-data/last_release.json`
  on the host, bind-mounted so it survives image updates the same way
  config.txt does.
- Don't pin the jmusicbot image tag to a specific version; leave it as
  `:latest` so Watchtower has something to update to. If the user later
  asks to freeze a version, swap `latest` for a specific release tag and
  note that Watchtower will then leave it alone.
- The release-notifier polls GitHub's public releases API every 15 minutes
  by default (`POLL_INTERVAL_SECONDS`) — no GitHub auth needed for a public
  repo at this frequency, well under the unauthenticated rate limit.
- If anything fails, report back the exact command and error rather than
  silently retrying with sudo/workarounds.

