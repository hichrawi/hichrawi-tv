HICHRAWI-TV — Recovery-only deployment

Purpose:
- Keep the existing IPTV source and existing logo.
- Restart FFmpeg automatically if it exits.
- Restart HLS server if it is not running.
- Do not delete all HLS segments on every FFmpeg retry.
- Do not change Firebase, source URL, or logo.

Important:
- This package intentionally does NOT implement IPTV source switching yet.
- A Railway deployment/redeploy can itself cause a short interruption; this package
  cannot eliminate that platform-level restart.
- Keep FIREBASE_SERVICE_ACCOUNT unchanged in Railway.
- Never upload the service-account JSON to GitHub.
