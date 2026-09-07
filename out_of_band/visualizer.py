import streamlit as st
import json
import os
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
from core import state_manager

st.set_page_config(page_title="OrderFlowKawa Vision", layout="wide")

# Hide the default Streamlit top-right menu, "Deploy" button, and running indicator
st.markdown("""
    <style>
        .stApp header {
            display: none !important;
        }
    </style>
""", unsafe_allow_html=True)

st.title("📈 OrderFlowKawa | Live AMT Market Topography")

with st.sidebar:
    st.header("📚 Quick-Start Tutorial")
    st.markdown("""
    **1. Telegram Control Menu**
    Send `/menu` to your Telegram bot to open the interactive dashboard:
    - 📊 **Status:** Get instant readout of POC, VAH, VAL, and open positions.
    - 📈 **Chart:** Request an image of current market structure.
    - ⚠️ **LIQUIDATE ALL:** The panic button. Instantly closes all open trades in MT5 and pauses execution.
    
    **2. The 4-Hour Bias Check**
    Every 4 hours, the bot will ping you asking for the macroeconomic Bias:
    - 🟢 **Bullish:** Only takes long setups off the VAL.
    - 🔴 **Bearish:** Only takes short setups off the VAH.
    - 🟡 **Neutral:** Trades mean-reversion, fading both VAH and VAL.
    - ⏸️ **Pause:** Sits out of the market entirely.
    
    *Note: This web dashboard automatically syncs with the Telegram bot in real-time.*
    """)

# Auto-refresh using Streamlit's rerun
placeholder = st.empty()

while True:
    with placeholder.container():
        state = state_manager.read_state()
        
        st.subheader(f"Current Bias: {state.get('bias', 'Unknown')}")
        
        col1, col2, col3 = st.columns(3)
        col1.metric("Point of Control (POC)", state.get('poc', 0.0))
        col2.metric("Value Area High (VAH)", state.get('vah', 0.0))
        col3.metric("Value Area Low (VAL)", state.get('val', 0.0))
        
        st.subheader("Open Positions")
        positions = state.get('positions', [])
        if positions:
            st.table(positions)
        else:
            st.write("No active positions.")
            
        last_update = state.get('last_update', 0.0)
        st.write(f"Last update timestamp: {last_update}")

    # Throttle visualizer updates to 1s
    time.sleep(1)
    st.rerun()
