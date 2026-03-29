#!/usr/bin/env bash
set -euo pipefail

# Mycelium A/B Comparison Demo
# Runs two Claude Code sessions side-by-side in tmux:
#   Left pane:  CONTROL (no mycelium notes)
#   Right pane: MYCELIUM (with pre-seeded notes)
# Both get the same coding task. Compare the approaches.

DEMO_DIR=$(mktemp -d /tmp/mycelium-demo.XXXXXX)
MYCELIUM_SH="$(cd "$(dirname "$0")/.." && pwd)/mycelium.sh"
TASK_FILE="$DEMO_DIR/task.md"
SESSION_NAME="mycelium-demo"
MODEL="${CLAUDE_MODEL:-sonnet}"

echo "📁 Demo dir: $DEMO_DIR"
echo "🔧 Mycelium: $MYCELIUM_SH"

# -------------------------------------------------------------------
# 1. Create the sample project (shared source, two copies)
# -------------------------------------------------------------------
create_project() {
  local dir="$1"
  mkdir -p "$dir/src"
  cd "$dir"
  git init -q
  git config user.email "demo@mycelium"
  git config user.name "demo"

  cat > src/api_client.py << 'PYEOF'
"""API client for the weather service."""
import requests
import time

API_BASE = "https://api.weather.example.com/v2"
_token = None
_token_expires = 0

def _get_token():
    """Get or refresh the OAuth token."""
    global _token, _token_expires
    if _token and time.time() < _token_expires:
        return _token
    resp = requests.post(f"{API_BASE}/auth/token", json={
        "client_id": "weather-app",
        "grant_type": "client_credentials",
    })
    data = resp.json()
    _token = data["access_token"]
    _token_expires = time.time() + data["expires_in"] - 30
    return _token

def get_forecast(city: str) -> dict:
    """Fetch forecast for a city. Called ~100 times/sec at peak."""
    token = _get_token()
    resp = requests.get(
        f"{API_BASE}/forecast/{city}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=5,
    )
    resp.raise_for_status()
    return resp.json()

def get_alerts(region: str) -> list:
    """Fetch active weather alerts. Called every 30s per region."""
    token = _get_token()
    resp = requests.get(
        f"{API_BASE}/alerts/{region}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json().get("alerts", [])

def batch_forecasts(cities: list[str]) -> dict:
    """Fetch forecasts for multiple cities. Used by the dashboard."""
    return {city: get_forecast(city) for city in cities}
PYEOF

  cat > src/dashboard.py << 'PYEOF'
"""Dashboard that aggregates weather data."""
from src.api_client import get_forecast, get_alerts, batch_forecasts

MONITORED_REGIONS = ["us-east", "us-west", "eu-central"]
TOP_CITIES = ["NYC", "LA", "London", "Tokyo", "Sydney"]

def refresh_dashboard():
    forecasts = batch_forecasts(TOP_CITIES)
    alerts = []
    for region in MONITORED_REGIONS:
        alerts.extend(get_alerts(region))
    return {"forecasts": forecasts, "alerts": alerts}
PYEOF

  cat > src/config.py << 'PYEOF'
"""Configuration constants."""
# Rate limits imposed by the weather API provider
MAX_REQUESTS_PER_MINUTE = 600
MAX_CONCURRENT_CONNECTIONS = 10

# Cache settings (not yet implemented)
CACHE_TTL_FORECAST = 300   # 5 minutes
CACHE_TTL_ALERTS = 30      # 30 seconds — alerts must be fresh

# Threading note: this service runs behind gunicorn with 4 workers.
# Each worker is a separate process. Keep that in mind for any shared state.
PYEOF

  cat > requirements.txt << 'EOF'
requests>=2.31
EOF

  cat > README.md << 'EOF'
# Weather Dashboard Service

API client + dashboard for weather data aggregation.
Runs behind gunicorn with 4 workers (multiprocess).

## Known issues
- No caching — every dashboard refresh hits the API for every city.
- Rate limit (600 req/min) gets hit during peak traffic.
EOF

  git add -A
  git commit -q --no-verify -m "initial: weather dashboard service"
}

# -------------------------------------------------------------------
# 2. Create control repo (no mycelium)
# -------------------------------------------------------------------
echo "🔨 Creating control repo..."
create_project "$DEMO_DIR/control"

# -------------------------------------------------------------------
# 3. Create mycelium repo (with pre-seeded notes)
# -------------------------------------------------------------------
echo "🔨 Creating mycelium repo..."
create_project "$DEMO_DIR/mycelium"

cd "$DEMO_DIR/mycelium"

echo "📡 Seeding mycelium notes..."

# Warning: token refresh is not thread-safe
"$MYCELIUM_SH" note src/api_client.py -f -k warning \
  -t "Token refresh has a TOCTOU race condition" \
  -m "The global _token/_token_expires pattern is NOT safe under gunicorn's
multiprocess model. Two workers can both see an expired token and race to
refresh simultaneously, causing duplicate token requests and potential 401s
if the old token is revoked on refresh. Any caching solution MUST account
for this — do NOT layer a cache on top of the existing broken token pattern
without fixing it first. Use file-lock or a dedicated token-refresh process."

# Constraint: cache must be process-safe
"$MYCELIUM_SH" note src/config.py -f -k constraint \
  -t "Multiprocess: in-memory caches won't work" \
  -m "gunicorn runs 4 worker PROCESSES (not threads). A dict-based in-memory
cache in one worker is invisible to others. Options: (1) redis/memcached for
shared cache, (2) each worker maintains its own cache (acceptable if you accept
4x the API calls on cold start), (3) cachetools.TTLCache per-worker with the
understanding that it's per-process. Document the choice. An in-process cache
is fine for the forecast use case (TTL=300s, 4 workers = 4 cache misses per 5min
per city = totally within rate limits). Alerts MUST stay fresh (30s TTL)."

# Decision: alerts should not be cached aggressively
"$MYCELIUM_SH" note src/dashboard.py -f -k decision \
  -t "Alerts: 30s max cache TTL, forecasts: 5min is fine" \
  -e "depends-on blob:$(git rev-parse HEAD:src/config.py)" \
  -m "Product decision from sprint review: weather alerts are safety-critical.
Users rely on them for severe weather warnings. Cache TTL for alerts must
not exceed 30 seconds. Forecasts can be cached for 5 minutes — they update
hourly upstream anyway. The CACHE_TTL constants in config.py reflect this."

# Context: the rate limit situation
"$MYCELIUM_SH" note HEAD -f -k context \
  -m "This service is hitting API rate limits (600/min) during peak.
The fix is to add caching, but the multiprocess architecture (gunicorn, 4 workers)
means naive in-memory caching won't share across workers.
Per-process cachetools.TTLCache is the agreed approach — each worker
caches independently, which at worst means 4x cold-start requests
but stays well within rate limits. Redis was considered overkill for this."

echo ""
echo "📋 Notes seeded. Verifying:"
"$MYCELIUM_SH" log
echo ""

# -------------------------------------------------------------------
# 4. Write the shared task prompt
# -------------------------------------------------------------------
cat > "$TASK_FILE" << 'TASKEOF'
The weather dashboard service is hitting API rate limits (600 requests/minute)
during peak traffic because there's no caching.

Your task: Add response caching to src/api_client.py so that:
1. Repeated calls to get_forecast() for the same city reuse cached results
2. Alerts remain fresh (they're safety-critical)
3. The solution works correctly in the production environment

Requirements:
- Modify src/api_client.py to add caching
- Update requirements.txt if you add dependencies
- Keep it simple — this is a small service

When done, commit your changes with a descriptive message.
Do NOT run the code or tests — just make the changes and commit.
TASKEOF

echo "📝 Task written to $TASK_FILE"
echo ""

# -------------------------------------------------------------------
# 5. Launch in tmux side-by-side
# -------------------------------------------------------------------

# Kill existing session if any
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# Read task into a variable for the prompt
TASK=$(cat "$TASK_FILE")

# Claude Code args shared by both
CLAUDE_ARGS=(
  --print
  --model "$MODEL"
  --dangerously-skip-permissions
  --no-session-persistence
  --max-budget-usd 0.50
)

# Create session with control pane (left)
tmux new-session -d -s "$SESSION_NAME" -n compare \
  -x 200 -y 50

# Left pane: CONTROL
tmux send-keys -t "$SESSION_NAME:compare" "
echo '════════════════════════════════════════'
echo '  CONTROL (no mycelium notes)'
echo '════════════════════════════════════════'
cd '$DEMO_DIR/control'
claude ${CLAUDE_ARGS[*]} '$TASK' 2>&1 | tee '$DEMO_DIR/control-output.txt'
echo ''
echo '════ CONTROL DONE ════'
echo 'Diff:'
git diff HEAD
" Enter

# Right pane: MYCELIUM
tmux split-window -h -t "$SESSION_NAME:compare"
tmux send-keys -t "$SESSION_NAME:compare.1" "
echo '════════════════════════════════════════'
echo '  MYCELIUM (with pre-seeded notes)'  
echo '════════════════════════════════════════'
cd '$DEMO_DIR/mycelium'
echo '--- mycelium context before running ---'
bash '$MYCELIUM_SH' context src/api_client.py 2>/dev/null | head -30
echo '────────────────────────────────────────'
echo ''
claude ${CLAUDE_ARGS[*]} --append-system-prompt 'Before starting work, run: mycelium.sh context src/api_client.py && mycelium.sh find warning && mycelium.sh find constraint — then use what you learn.' '$TASK' 2>&1 | tee '$DEMO_DIR/mycelium-output.txt'
echo ''
echo '════ MYCELIUM DONE ════'
echo 'Diff:'
git diff HEAD
" Enter

# Even pane widths
tmux select-layout -t "$SESSION_NAME:compare" even-horizontal

echo "🚀 Demo launched in tmux session: $SESSION_NAME"
echo ""
echo "   tmux attach -t $SESSION_NAME"
echo ""
echo "Results will be saved to:"
echo "   Control:  $DEMO_DIR/control-output.txt"
echo "   Mycelium: $DEMO_DIR/mycelium-output.txt"
echo ""
echo "After both finish, compare the diffs:"
echo "   diff <(cd $DEMO_DIR/control && git diff HEAD) <(cd $DEMO_DIR/mycelium && git diff HEAD)"
