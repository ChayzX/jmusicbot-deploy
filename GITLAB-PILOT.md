# GitLab pilot — JMusicBot

JMusicBot is the trial run for "should everything move from GitHub to
GitLab?". This repo is the smallest self-contained deploy path that still
exercises everything worth judging: patch → test → multi-arch image →
guarded k3s rollout → verify → automatic rollback.

**Nothing changes in production until you press ▶ on the `deploy` job.**
Until cutover, the GitHub workflows stay live and remain the real path:

| Piece | Today (GitHub) | Pilot (GitLab) |
|---|---|---|
| Patched bot image | `k8s-homelab/.github/workflows/jmusicbot-deploy.yml` → `ghcr.io/chayzx/jmusicbot` | `.gitlab-ci.yml` → `registry.gitlab.com/<you>/jmusicbot-deploy/jmusicbot` |
| Release-notifier image | `.github/workflows/build-and-push.yml` → `ghcr.io/chayzx/jmusicbot-release-notifier` | `.gitlab-ci.yml` → `registry.gitlab.com/<you>/jmusicbot-deploy/release-notifier` (now multi-arch) |
| Patches | `k8s-homelab/scripts/patches/` | `patches/` + `patches/series` (copied; keep in sync until cutover) |
| Deploy gate | merge to `main` | ▶ manual job; `AUTO_DEPLOY=true` restores merge-to-deploy |

## How the GitHub workflow maps to the GitLab one

| GitHub Actions | GitLab CI (this file) |
|---|---|
| `workflow_dispatch.inputs.upstream_ref` | `variables: UPSTREAM_REF: {description: …}` → field on **Run pipeline** |
| `on.push.paths` | `rules: changes:` (shared via the `.bot-paths` anchor) |
| `$GITHUB_OUTPUT` / `needs.x.outputs.y` | `artifacts: reports: dotenv:` → plain env vars in downstream jobs |
| `concurrency: jmusicbot-production` | `resource_group: jmusicbot-production` |
| `if: always() && needs.verify.result == 'failure'` | `when: on_failure` + an `APPLIED` guard |
| Secret `KUBE_CONFIG_JMUSICBOT` (base64) | **File**-type variable `KUBECONFIG_JMUSICBOT` (raw kubeconfig) |
| `cache-from: type=gha` | `--cache-from type=registry,ref=…:buildcache` |
| 5 copies of the cloudflared + kubeconfig block | one `.kube` template + `extends:` |
| Stage summary markdown | Environments page (Operate → Environments → production) |

## One-time setup (≈20 min, all in the GitLab UI)

1. **Create the project.** gitlab.com → New project → *Import project* →
   *Repository by URL* → `https://github.com/ChayzX/jmusicbot-deploy.git`
   (public repo, so no credentials needed). Name it `jmusicbot-deploy`, visibility
   **Public**. Public matters: it makes the container registry pullable
   anonymously, the same way the public GHCR packages work today, so
   k3s needs no `imagePullSecrets`.
2. **CI/CD variables** (Settings → CI/CD → Variables). Tick *Protected* on
   all three (only `main` pipelines can read them, which is also the only
   place the deploy jobs run):
   | Key | Type | Value |
   |---|---|---|
   | `CF_ACCESS_CLIENT_ID` | Variable, masked | same as the GitHub secret |
   | `CF_ACCESS_CLIENT_SECRET` | Variable, masked | same as the GitHub secret |
   | `KUBECONFIG_JMUSICBOT` | **File** | the *decoded* kubeconfig (`base64 -d` of the GitHub `KUBE_CONFIG_JMUSICBOT` value) |
3. **Protect `main`** (Settings → Repository → Protected branches) — it
   usually is by default on import.
4. *(Optional, keeps GitHub in sync)* Settings → Repository → Mirroring →
   **push** mirror to `https://github.com/ChayzX/jmusicbot-deploy.git` with a
   fine-grained GitHub PAT (contents: write on that repo only). After that,
   GitLab is the source of truth for this repo and GitHub is a read-only copy.
   Push only to GitLab, or the mirror will diverge.

## Running the pilot

1. **Build only:** Build → Pipelines → **Run pipeline** on `main`. Expect
   `prepare-bot` → `build-bot` + `build-notifier` green, then `deploy`
   waiting on ▶. Check Deploy → Container Registry for both images, and the
   job log of `build-bot` for both `linux/amd64` and `linux/arm64`.
2. **Deploy (this does touch production):** press ▶ on `deploy`. `verify`
   and, if needed, `rollback` follow automatically. The pod will now run
   the GitLab-registry image; the next GitHub-driven deploy would switch it
   back to GHCR, which is harmless (same patches, same tag scheme).
3. **MR experience:** open an MR that edits `patches/series` (e.g. reorder
   two lines). `prepare-bot` runs on the MR and should fail on the patch
   that no longer applies. This is the "catch it before merge" behavior that
   the GitHub workflow doesn't have.

## Things to judge while you try it

- Pipeline UI: DAG/`needs` graph, manual gates, environment history,
  one-click rollback from Operate → Environments.
- Minutes: GitLab Free includes far fewer hosted-runner minutes than
  GitHub Free. `build-bot` cross-compiles arm64 under QEMU (Maven runs
  inside the arm64 build stage), which is the expensive part. Note its
  duration after the first run. Ways to make it cheaper, if you keep GitLab:
  register the `homelab-ci` box as a GitLab Runner (free minutes), or
  split the build per-arch onto GitLab's hosted arm64 runners and stitch
  the manifest with `docker buildx imagetools create` (no QEMU).
- Working with Claude: Claude Code on the web and PR watching are GitHub-only.
  If you give a session a `GITLAB_TOKEN` in its environment settings, it can
  still `git push` to GitLab, but it can't open or watch MRs for you.

## Cutover (only if you decide to keep it)

1. Set CI/CD variable `AUTO_DEPLOY=true` → merges to `main` deploy again,
   no ▶ needed.
2. In `chayzx/k8s-homelab`: delete `.github/workflows/jmusicbot-deploy.yml`
   and `scripts/patches/` (moved here), point
   `jmusicbot/40-deployment-jmusicbot.yaml` and
   `jmusicbot/50-deployment-release-notifier.yaml` at the
   `registry.gitlab.com/...` images, and update `SERVICE_SUPPORT.md`,
   `scripts/README.md`, and the two tests that reference the workflow
   (`tests/jmusicbot-home-owner-guard-test.sh`,
   `tests/non-minecraft-workflow-concurrency-test.sh`).
3. Delete `.github/workflows/build-and-push.yml` here.

## Backing out

Delete the GitLab project. Nothing on the GitHub side was removed, so
the next `k8s-homelab` merge (or a manual *Run workflow* on
`jmusicbot-deploy.yml`) puts the pod back on the GHCR image.
