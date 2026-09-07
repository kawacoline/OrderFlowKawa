import json
import os
import logging
import datetime
from filelock import FileLock, Timeout

TRADE_FILE = "trades.json"
LOCK_FILE = "trades.json.lock"

logger = logging.getLogger(__name__)

def _get_default_state():
    return {
        "trades": []
    }

def init_tracker():
    if not os.path.exists(TRADE_FILE):
        write_tracker(_get_default_state())

def read_tracker():
    lock = FileLock(LOCK_FILE, timeout=2)
    try:
        with lock:
            if not os.path.exists(TRADE_FILE):
                return _get_default_state()
            with open(TRADE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Timeout:
        logger.error("Timeout reading trades.json.")
        return _get_default_state()
    except Exception as e:
        logger.error(f"Error reading trades.json: {e}")
        return _get_default_state()

def write_tracker(data):
    lock = FileLock(LOCK_FILE, timeout=2)
    try:
        with lock:
            with open(TRADE_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=4)
    except Timeout:
        logger.error("Timeout writing trades.json.")
    except Exception as e:
        logger.error(f"Error writing trades.json: {e}")

def clear_trades():
    """Clears all trades from the history."""
    write_tracker(_get_default_state())

def add_trade(ticket, action, price, sl, tp, reason, strategy="V1"):
    """Record a new trade when it's opened."""
    data = read_tracker()
    trade = {
        "ticket": ticket,
        "action": action,
        "price": price,
        "sl": sl,
        "tp": tp,
        "reason": reason,
        "strategy": strategy,
        "status": "Ongoing",
        "pnl": 0.0,
        "close_reason": "Unknown",
        "timestamp": datetime.datetime.now().isoformat()
    }
    data["trades"].append(trade)
    write_tracker(data)

def update_trade(ticket, status, pnl, close_reason="Unknown"):
    """Update a trade after it's closed."""
    data = read_tracker()
    for trade in data["trades"]:
        if str(trade.get("ticket")) == str(ticket):
            trade["status"] = status
            trade["pnl"] = pnl
            trade["close_reason"] = close_reason
            break
    write_tracker(data)

def get_all_trades():
    data = read_tracker()
    return data.get("trades", [])

def get_ongoing_trades():
    trades = get_all_trades()
    return [t for t in trades if t.get("status") == "Ongoing"]
