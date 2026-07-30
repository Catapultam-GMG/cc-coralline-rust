#!/usr/bin/env bash
# mkinput.sh > input.json  — reset times anchored to now so limits are plausible
set -eu
now=$(date +%s)
r5=$(date -u -d "@$(( now + 3600 ))" +%Y-%m-%dT%H:%M:%SZ)
r7=$(date -u -d "@$(( now + 3*86400 ))" +%Y-%m-%dT%H:%M:%SZ)
cat <<JSON
{
  "cwd": "/home/user/project",
  "workspace": { "current_dir": "/home/user/project" },
  "model": { "display_name": "Claude Opus 5" },
  "output_style": { "name": "default" },
  "effort": { "level": "high" },
  "context_window": {
    "used_percentage": 62.4,
    "total_input_tokens": 1234567,
    "total_output_tokens": 45678,
    "current_usage": { "cache_read_input_tokens": 98765, "cache_creation_input_tokens": 4321 }
  },
  "rate_limits": {
    "five_hour": { "used_percentage": 41.2, "resets_at": "$r5" },
    "seven_day": { "used_percentage": 78.9, "resets_at": "$r7" }
  },
  "cost": { "total_cost_usd": 1.2345, "total_lines_added": 321, "total_lines_removed": 87, "total_duration_ms": 5432100 }
}
JSON
