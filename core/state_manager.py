import json
import os
import logging
from filelock import FileLock, Timeout

STATE_FILE = "state.json"
LOCK_FILE = "state.json.lock"

logger = logging.getLogger(__name__)

def _get_default_state():
    return {
        "bias": "Paused",  # Bullish, Bearish, Neutral, Paused
        "engine_mode_v1": "ACTIVE",
        "engine_mode_v2": "PAUSED",
        "auto_bias": False,
        "atr_multiplier": 1.5,
        "poc": 0.0,
        "vah": 0.0,
        "val": 0.0,
        "positions": [],
        "last_update": 0.0,
        "use_ema_filter": True,
        "use_breakeven": True,
        "use_responsive": False
    }

def init_state():
    """Initializes the state file if it doesn't exist."""
    if not os.path.exists(STATE_FILE):
        write_state(_get_default_state())

def read_state():
    """Reads the current state with a file lock."""
    lock = FileLock(LOCK_FILE, timeout=2)
    try:
        with lock:
            if not os.path.exists(STATE_FILE):
                return _get_default_state()
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Timeout:
        logger.error("Timeout while trying to read state.")
        return _get_default_state()
    except Exception as e:
        logger.error(f"Error reading state: {e}")
        return _get_default_state()

def write_state(state):
    """Writes the current state with a file lock."""
    lock = FileLock(LOCK_FILE, timeout=2)
    try:
        with lock:
            with open(STATE_FILE, "w", encoding="utf-8") as f:
                json.dump(state, f, indent=4)
    except Timeout:
        logger.error("Timeout while trying to write state.")
    except Exception as e:
        logger.error(f"Error writing state: {e}")

def update_bias(new_bias):
    """Updates only the bias field."""
    state = read_state()
    state["bias"] = new_bias
    write_state(state)

def update_feature_toggle(feature_name, value):
    """Updates a boolean feature toggle."""
    state = read_state()
    state[feature_name] = value
    write_state(state)

def update_market_data(poc, vah, val, last_update):
    """Updates the AMT market data."""
    state = read_state()
    state["poc"] = poc
    state["vah"] = vah
    state["val"] = val
    state["last_update"] = last_update
    write_state(state)

def update_positions(positions):
    """Updates the open positions list."""
    state = read_state()
    state["positions"] = positions
    write_state(state)

def update_atr_multiplier(value):
    """Updates the ATR risk multiplier."""
    state = read_state()
    state["atr_multiplier"] = float(value)
    write_state(state)

def update_auto_bias(enabled):
    """Toggles Auto-Bias on or off."""
    state = read_state()
    state["auto_bias"] = bool(enabled)
    write_state(state)
