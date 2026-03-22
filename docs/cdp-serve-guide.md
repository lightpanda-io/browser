# CDP Serve Mode — Production Guide

This guide covers running Lightpanda's CDP server in production for AI agents, automation pipelines, and long-running services.

## Quick Reference

```bash
lightpanda serve \
  --host 127.0.0.1 \
  --port 9222 \
  --timeout 0 \
  --cdp_max_connections 64 \
  --http_max_concurrent 20 \
  --obey_robots \
  --log_level info \
  --log_format pretty
```

## Key Configuration Options

### `--timeout` (Inactivity Timeout)

| Value | Behavior |
|-------|----------|
| `10` (default) | Disconnects idle CDP clients after 10 seconds |
| `0` | No timeout — connections stay open indefinitely |
| `604800` | Maximum allowed (1 week) |

> **⚠️ Common Pitfall:** The default `--timeout 10` will disconnect CDP clients that pause between commands for more than 10 seconds. This frequently breaks automation scripts that wait for LLM responses or perform multi-step reasoning between page interactions.
>
> **Recommendation:** Use `--timeout 0` for AI agent workloads. Set a finite timeout only if you need automatic cleanup of abandoned connections.

### `--cdp_max_connections`

Maximum number of simultaneous CDP WebSocket connections. Default: `16`.

For high-throughput crawling (e.g., Research Runs with 50-100 parallel pages), increase this to match your parallelism target:

```bash
--cdp_max_connections 128
```

Each connection uses approximately 7 MB of memory, so 128 connections ≈ 900 MB — still far less than the 4+ GB Chrome would require for the same workload.

### `--cdp_max_pending_connections`

Maximum pending connections in the accept queue. Default: `128`. Increase if you experience connection refused errors during burst traffic.

### HTTP Tuning

| Flag | Default | Description |
|------|---------|-------------|
| `--http_max_concurrent` | `10` | Max concurrent outbound HTTP requests across all pages |
| `--http_max_host_open` | `4` | Max open connections per host:port |
| `--http_timeout` | `10000` | Per-request timeout in milliseconds (0 = no timeout) |
| `--http_connect_timeout` | `0` | TCP connect timeout in ms (0 = no timeout) |

For parallel crawling, increase `--http_max_concurrent` proportionally to your page count:

```bash
# 50 parallel pages, ~4 requests each = 200 concurrent
--http_max_concurrent 200 --http_max_host_open 8
```

## Health Checks

Lightpanda exposes an HTTP endpoint for health monitoring:

```bash
curl -s http://127.0.0.1:9222/json/version
```

Response:

```json
{
  "Browser": "Lightpanda/1.0",
  "Protocol-Version": "1.3",
  "webSocketDebuggerUrl": "ws://127.0.0.1:9222/"
}
```

### Health Check Script Example

```bash
#!/bin/bash
# healthcheck.sh — exits 0 if healthy, 1 if not
RESPONSE=$(curl -sf --max-time 3 http://127.0.0.1:9222/json/version)
if [ $? -ne 0 ]; then
  echo "UNHEALTHY: CDP server not responding"
  exit 1
fi
echo "HEALTHY: $(echo "$RESPONSE" | jq -r .Browser)"
exit 0
```

### Docker Health Check

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD curl -sf http://127.0.0.1:9222/json/version || exit 1
```

## Docker Deployment

### Basic

```bash
docker run -d \
  --name lightpanda \
  -p 9222:9222 \
  lightpanda/browser:nightly \
  serve --host 0.0.0.0 --port 9222 --timeout 0
```

### Remote CDP Connections

> **⚠️ Known Issue ([#1922](https://github.com/lightpanda-io/browser/issues/1922)):** When starting with `--host 0.0.0.0`, the `/json/version` endpoint returns `webSocketDebuggerUrl` as `ws://0.0.0.0:9222/`. Remote clients that use this URL will fail with `ECONNREFUSED`.
>
> **Workaround:** Override the WebSocket URL in your client:

```js
// Puppeteer — override browserWSEndpoint explicitly
const browser = await puppeteer.connect({
  browserWSEndpoint: `ws://${LIGHTPANDA_HOST}:9222/`,
});
```

```python
# Playwright (Python)
browser = await playwright.chromium.connect_over_cdp(
    f"ws://{LIGHTPANDA_HOST}:9222/"
)
```

### docker-compose

```yaml
services:
  lightpanda:
    image: lightpanda/browser:nightly
    command: serve --host 0.0.0.0 --port 9222 --timeout 0 --cdp_max_connections 64
    ports:
      - "9222:9222"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:9222/json/version"]
      interval: 10s
      timeout: 3s
      retries: 3
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 2G
```

## Process Management

### systemd

```ini
[Unit]
Description=Lightpanda CDP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/lightpanda serve \
  --host 127.0.0.1 \
  --port 9222 \
  --timeout 0 \
  --cdp_max_connections 64 \
  --obey_robots \
  --log_level warn
Restart=on-failure
RestartSec=3
StartLimitBurst=5
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
```

### macOS launchd

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.lightpanda.browser</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/lightpanda</string>
        <string>serve</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>9222</string>
        <string>--timeout</string>
        <string>0</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Client disconnects after ~10s | Default `--timeout 10` | Use `--timeout 0` |
| `ECONNREFUSED` from remote client | `webSocketDebuggerUrl` returns `0.0.0.0` | Override WebSocket URL in client ([#1922](https://github.com/lightpanda-io/browser/issues/1922)) |
| Connection refused during bursts | `--cdp_max_pending_connections` too low | Increase to 256+ |
| Pages fail to load (SPA) | Incomplete Web API coverage (Beta) | Fall back to Chrome headless for that page |
| High memory under load | Too many concurrent pages | Reduce `--cdp_max_connections` or add page pooling |
