# 📊 OrderFlowKawa — Institutional Order Flow & Auction Market Theory Engine

[![Platform](https://img.shields.io/badge/Platform-MetaTrader%205-green.svg)](https://www.metatrader5.com)
[![MQL5](https://img.shields.io/badge/Language-MQL5%20%2F%20C%2B%2B-blue.svg)](https://www.mql5.com)
[![Python Version](https://img.shields.io/badge/Python-3.10%2B-blue.svg?logo=python)](https://python.org)
[![Telegram Control](https://img.shields.io/badge/Control-Telegram%20Bot-blue.svg?logo=telegram)](https://telegram.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**OrderFlowKawa** is a quantitative, institutional-grade automated trading system built for **MetaTrader 5 (MT5)**. Operating strictly within the mathematical principles of **Auction Market Theory (AMT)** and **Volume Profile Microstructure**, the system eliminates lagging retail indicators in favor of pure volumetric liquidity distribution, auction imbalance, and order flow absorption.

Designed for high-beta equity index futures and CFDs (NQ / USTEC / ES), the system combines a native, ultra-low-latency **MQL5 Expert Advisor** with a robust **Python asynchronous state machine** and **Telegram command & control loop**.

---

## 🏛️ Strategy: Auction Market Theory (AMT)

Financial markets are dual-auction mechanisms facilitating trade by discovering fair value. Price advertises opportunity, while volume measures market acceptance or rejection:

```
                  ┌───────────────────────────────┐
                  │    VALUE AREA HIGH (VAH)      │  ← Upper 70% Boundary
                  │───────────────────────────────│
                  │                               │
                  │   POINT OF CONTROL (POC)      │  ← Maximum Session Volume
                  │   (Statistical Magnet)        │
                  │                               │
                  │───────────────────────────────│
                  │    VALUE AREA LOW (VAL)       │  ← Lower 70% Boundary
                  └───────────────────────────────┘
```

### The Setup: Trap, Reclaim, and LVN Pullback (The 80% Rule)
1. **The Trap**: Price breaks aggressively outside the Value Area (above VAH or below VAL), trapping breakout retail liquidity.
2. **The Reclaim**: Price impulsively rejects the extreme and traverses back *inside* the Value Area.
3. **The LVN Pullback**: The mathematical engine calculates the 50% structural Low-Volume Node (LVN) liquidity void of the reclaim leg. Execution occurs upon retest with confirmed volume absorption.
4. **Target (TP)**: The session Point of Control (POC), offering high-probability mean-reversion with strict invalidation rules.
5. **Microstructure Stop Loss**: Dynamically anchored 1-2 ticks beyond the footprint absorption cluster rather than arbitrary pip distances.

---

## ⚡ Confluence Filters & Risk Governors

- **VWAP Directional Governor**: Enforces strict directional bias (Longs permitted only above Daily VWAP; Shorts only below).
- **Initial Value Balance (IVB)**: Establishes the Opening Range boundary (first 30 minutes). Breaks outside dictate session volatility regime.
- **Midday Volume Void**: Automatically calculates rolling 5-minute volume relative to the morning average and halts entries during low-liquidity institutional lulls.
- **CVD Divergence**: Cross-references Cumulative Volume Delta against price extremes to confirm aggressive participant exhaustion.
- **Dynamic Breakeven**: Automatically shifts protective stops to entry fill once 50% of the distance to POC target is captured.

---

## 🏗️ System Architecture

```
OrderFlowKawa System
├── MQL5 Native Layer
│   ├── OrderFlowKawa_EA.mq5            # Core autonomous EA with CTrade execution
│   └── OrderFlowKawa_MasterVisual.mq5   # Real-time chart visualizer & CSV telemetry
├── Python Core Architecture
│   ├── core/mt5_engine.py              # Native MT5 tick-stream ingestion
│   ├── core/amt_math.py                # Volume profile & Value Area calculations
│   ├── core/state_manager.py           # Finite-state machine & daily session resets
│   ├── execution/logic_loop.py         # Sub-second trade decision engine
│   └── control/tg_bot.py               # Asynchronous Telegram supervision & alerts
└── Visualization & Telemetry
    └── out_of_band/visualizer.py       # Streamlit operational dashboard
```

---

## 🛠️ Setup & Installation

### 1. Prerequisites
- **Windows 10/11 or Windows Server VPS**
- **MetaTrader 5 Desktop Terminal** (installed and connected to your broker)
- **Python 3.10+**

### 2. Installation
```bash
git clone https://github.com/kawacoline/OrderFlowKawa.git
cd OrderFlowKawa
setup.bat
```

### 3. Configuration
Copy the template configuration and specify your parameters:
```bash
copy .env.example .env
```

```ini
# MetaTrader 5
MT5_SYMBOL=USTEC
MT5_LOGIN=your_account_number
MT5_PASSWORD=your_password
MT5_SERVER=YourBroker-Server

# Telegram Supervision
TELEGRAM_BOT_TOKEN=your_bot_token
TELEGRAM_ADMIN_IDS=your_telegram_id
```

### 4. Running the Engine
- **MQL5 Execution**: Compile `OrderFlowKawa_EA.mq5` inside MetaEditor 5 and attach it to your M1 chart.
- **Python Telemetry Loop**: Run `start.bat` to launch the supervision bot and tick monitor.

---

## 📁 Repository Structure

```
├── OrderFlowKawa_EA.mq5            # Native MQL5 Expert Advisor
├── OrderFlowKawa_MasterVisual.mq5  # MQL5 Volume Profile visual indicator
├── main.py                         # Python entrypoint and worker orchestrator
├── core/                           # Mathematical and execution modules
├── control/                        # Telegram management interface
├── execution/                      # Logic loops and order management
├── out_of_band/                    # Monitoring dashboards
├── strategy_visualization.html     # Interactive AMT structural visualizer
├── requirements.txt                # Python environment requirements
└── setup.bat / start.bat           # Automation batch scripts
```

---

## 👨‍💻 Author

**Hazael**  
*Full Stack Software Engineer & Algorithmic Trading Specialist*  
- **GitHub**: [@kawacoline](https://github.com/kawacoline)  
- **Email**: kawacoline@gmail.com  
- **Portfolio**: [hazael.dev](https://github.com/kawacoline)

---

## ⚖️ Disclaimer

*OrderFlowKawa is for educational, research, and algorithmic evaluation purposes. Trading futures, CFDs, and leveraged assets involves substantial risk of financial loss.*
