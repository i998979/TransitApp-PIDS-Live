# TransitApp PIDS Live

Experimental GitHub Actions -> Chromium -> FFmpeg -> YouTube RTMPS pipeline.

Target: https://transitapp-6c6.pages.dev/pids

## Important limitations

This is a best-effort experiment, **not guaranteed 24/7 hosting**. GitHub-hosted jobs have a maximum runtime, scheduled jobs can be delayed or dropped, and GitHub Actions is not a persistent server. Each session is intentionally limited to 5h 45m, leaving a gap before the next scheduled run. YouTube may treat reconnects as separate sessions or fail to reconnect.

Do not use this repository as a guaranteed continuous broadcasting service.

## Setup

1. Use a **public** repository named `i998979/TransitApp-PIDS-Live`.
2. Ensure the workflow and script files are on its default branch.
3. In GitHub: Settings -> Secrets and variables -> Actions -> New repository secret:
   - `YOUTUBE_STREAM_KEY`: your YouTube Live stream key.
4. Open Actions and enable workflows.
5. Run **PIDS YouTube Live** manually once using Run workflow.

Keep the stream key private. Never put it in source files, workflow YAML, logs, or commit history.

## Caching

The workflow uses `actions/cache@v4` to cache:
- Playwright's Chromium browser download (`~/.cache/ms-playwright`)
- The Playwright Node package (`~/.local/pids-live`)

The cache key includes the Ubuntu runner and Playwright version. The first run downloads Chromium; later runs should restore it instead of downloading the browser again. GitHub may evict caches due to its retention and storage policies, so a later run may occasionally need to download it again.

FFmpeg and Xvfb are checked on the runner and installed only if missing. Playwright's required OS libraries are checked/installed on each fresh runner because the runner filesystem itself is not persistent.

## Configuration

Edit environment variables in `.github/workflows/live.yml`:
- `TARGET_URL`: browser URL
- `VIDEO_WIDTH`, `VIDEO_HEIGHT`, `FPS`: capture settings
- `SESSION_MINUTES`: maximum session duration (default 345 = 5h45m)
- `PLAYWRIGHT_VERSION`: browser automation package/browser version; changing it intentionally creates a new cache.

The workflow is scheduled at 00:00, 06:00, 12:00 and 18:00 UTC. GitHub may delay scheduled runs. Change the cron expression if desired.

## Troubleshooting

- `Invalid stream key`: recreate/check the YouTube stream key secret.
- Browser launch fails: inspect the Playwright/Chromium installation logs; changing the Playwright version triggers a fresh browser cache.
- Black screen: verify the target page loads without authentication or browser interaction.
- Stream disconnects between sessions: YouTube reconnect behavior is not guaranteed.
- Workflow not starting: check Actions permissions, workflow enablement, and GitHub scheduled-workflow restrictions.
