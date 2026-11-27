# TransitApp PIDS Live

Experimental GitHub Actions -> Chromium -> FFmpeg -> YouTube RTMPS pipeline.

Target: https://transitapp-6c6.pages.dev/pids

## Important limitations

This is a best-effort experiment, **not guaranteed 24/7 hosting**. GitHub-hosted jobs have a maximum runtime, scheduled jobs can be delayed or dropped, and GitHub Actions is not a persistent server. Each session is intentionally limited to 5h 45m, leaving a gap before the next scheduled run. YouTube may treat reconnects as separate sessions or fail to reconnect.

Do not use this repository as a guaranteed continuous broadcasting service.

## Setup

1. Create a **public** repository named `i998979/TransitApp-PIDS-Live`.
2. Upload/push all files in this folder to its default branch.
3. In GitHub: Settings -> Secrets and variables -> Actions -> New repository secret:
   - `YOUTUBE_STREAM_KEY`: your YouTube Live stream key.
4. Open Actions and enable workflows.
5. Run **PIDS YouTube Live** manually once using Run workflow.

Keep the stream key private. Never put it in source files, workflow YAML, logs, or commit history.

## Configuration

Edit environment variables in `.github/workflows/live.yml`:
- `TARGET_URL`: browser URL
- `VIDEO_WIDTH`, `VIDEO_HEIGHT`, `FPS`: capture settings
- `SESSION_MINUTES`: maximum session duration (default 345 = 5h45m)

The workflow is scheduled at 00:00, 06:00, 12:00 and 18:00 UTC. GitHub may delay scheduled runs. Change the cron expression if desired.

## Troubleshooting

- `Invalid stream key`: recreate/check the YouTube stream key secret.
- Black screen: verify the target page loads without authentication or browser interaction.
- Stream disconnects between sessions: YouTube reconnect behavior is not guaranteed.
- Workflow not starting: check Actions permissions, workflow enablement, and GitHub scheduled-workflow restrictions.
