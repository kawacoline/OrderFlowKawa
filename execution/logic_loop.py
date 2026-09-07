import asyncio
import logging
import datetime
import os
import sys
import MetaTrader5 as mt5

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from core import state_manager
from core import trade_tracker
from core.mt5_engine import MT5Engine
from core.amt_math import VolumeProfile
from core.events import notification_queue

logger = logging.getLogger(__name__)

def check_absorption(footprint_df):
    if footprint_df is None or len(footprint_df) < 50:
        return False
    recent_vol = footprint_df['volume'].tail(10).sum()
    avg_vol = footprint_df['volume'].mean() * 10
    return recent_vol > (avg_vol * 1.5)

def check_aggression(footprint_df, price_level, direction="LONG"):
    if footprint_df is None or len(footprint_df) == 0:
        return False
    level_ticks = footprint_df[(footprint_df['last'] >= price_level - 5) & (footprint_df['last'] <= price_level + 5)].tail(50)
    if len(level_ticks) == 0:
        return False
    ask_vol = level_ticks[level_ticks['aggressor'] == 'ASK']['volume'].sum()
    bid_vol = level_ticks[level_ticks['aggressor'] == 'BID']['volume'].sum()
    
    if direction == "LONG":
        if bid_vol == 0: return ask_vol > 0
        return (ask_vol / bid_vol) >= 3.0
    else:
        if ask_vol == 0: return bid_vol > 0
        return (bid_vol / ask_vol) >= 3.0

async def execution_loop():
    logger.info("Initializing AMT Execution Engine (Triple-A Framework)...")
    
    terminal_path = os.getenv("MT5_TERMINAL_PATH")
    target_symbol = os.getenv("MT5_SYMBOL", "USTEC")
    
    engine = MT5Engine(symbol=target_symbol, terminal_path=terminal_path)
    if not engine.initialize():
        logger.error("Failed to initialize MT5 Engine.")
        
    vp = VolumeProfile()
    vp.load_profile()
    trade_tracker.init_tracker()
    
    last_tick_time_msc = 0
    
    long_state = "IDLE"
    long_extreme = float('inf')
    long_reclaim_high = 0.0
    long_lvn = 0.0
    
    short_state = "IDLE"
    short_extreme = 0.0
    short_reclaim_low = float('inf')
    short_lvn = 0.0
    
    last_trade_time = 0.0
    
    # Setup MQL5 Visualizer Bridge
    try:
        common_path = mt5.terminal_info().commondata_path
        visual_csv_path = os.path.join(common_path, "Files", "OrderFlowKawa_Visuals.csv")
        os.makedirs(os.path.dirname(visual_csv_path), exist_ok=True)
    except:
        visual_csv_path = None
    
    while True:
        try:
            state = state_manager.read_state()
            mode_v1 = state.get("engine_mode_v1", "ACTIVE")
            mode_v2 = state.get("engine_mode_v2", "PAUSED")
            
            engine.check_and_reconnect()
            
            # --- ONGOING TRADES NOTIFICATION ---
            ongoing = trade_tracker.get_ongoing_trades()
            for t in ongoing:
                ticket = t.get('ticket')
                is_closed, pnl, close_reason = engine.get_position_pnl(ticket)
                if is_closed:
                    status = "Win" if pnl > 0 else "Loss"
                    trade_tracker.update_trade(ticket, status, pnl, close_reason)
                    
                    emoji = "🟢" if status == "Win" else "🔴"
                    strat = t.get('strategy', 'V1')
                    msg = (
                        f"🔔 *TRADE CLOSED [{strat}]* 🔔\n"
                        f"Action: `{t.get('action', 'Unknown')}`\n"
                        f"Close Reason: `{close_reason}`\n"
                        f"Final PnL: *{emoji} ${pnl:,.2f}*\n\n"
                        f"_(Ticket: {ticket})_"
                    )
                    notification_queue.put_nowait(msg)
            
            if state.get('liquidate_flag', False):
                engine.close_all_positions()
                state['liquidate_flag'] = False
                state_manager.write_state(state)
                
            ticks = engine.get_latest_ticks(count=500)
            current_tick = engine.get_current_price()
            
            new_ticks_processed = False
            for tick in ticks:
                try:
                    tick_time_msc = int(tick['time_msc']) if 'time_msc' in tick.dtype.names else int(tick['time']) * 1000
                    tick_last = float(tick['last']) if 'last' in tick.dtype.names else 0.0
                    tick_vol = float(tick['volume']) if 'volume' in tick.dtype.names else 0.0
                except (AttributeError, TypeError):
                    tick_time_msc = getattr(tick, 'time_msc', getattr(tick, 'time', 0) * 1000)
                    tick_last = getattr(tick, 'last', 0.0)
                    tick_vol = getattr(tick, 'volume', 0.0)
                    
                if tick_time_msc > last_tick_time_msc:
                    vp.add_tick(tick_last, tick_vol)
                    last_tick_time_msc = tick_time_msc
                    new_ticks_processed = True
            
            if new_ticks_processed:
                vp.calculate()
                vp.save_profile()
                state_manager.update_market_data(
                    poc=vp.poc,
                    vah=vp.vah,
                    val=vp.val,
                    last_update=datetime.datetime.now().timestamp()
                )
                
            positions = engine.get_open_positions()
            pos_v1 = [p for p in positions if getattr(p, 'magic', 0) == 1337]
            pos_v2 = [p for p in positions if getattr(p, 'magic', 0) == 1338]
            
            pos_list = [{'ticket': getattr(p, 'ticket', 0), 'type': getattr(p, 'type', 0), 'volume': getattr(p, 'volume', 0), 'price': getattr(p, 'price_open', 0)} for p in positions]
            state_manager.update_positions(pos_list)
            
            vwap = engine.get_vwap()
            ivb_high, ivb_low = engine.get_ivb()
            
            if vwap and current_tick:
                auto_bias = "Bullish" if current_tick.last > vwap else "Bearish"
            else:
                auto_bias = "Neutral"

            if current_tick:
                sys.stdout.write(f"\r[LIVE] Price: {current_tick.last:,.2f} | POC: {vp.poc:,.2f} | VWAP: {(vwap or 0):,.2f} | Bias: {auto_bias:<7} | V1: {len(pos_v1)} | V2: {len(pos_v2)}    ")
                sys.stdout.flush()

            now = datetime.datetime.now()
            
            # THESIS FIX: Reset state machine at midnight to prevent
            # ghost LVN targets from the previous day carrying over
            if now.hour == 0 and now.minute == 0:
                if long_state != "IDLE" or short_state != "IDLE":
                    logger.info("MIDNIGHT RESET: Clearing all state machine memory")
                    long_state = "IDLE"
                    long_extreme = float('inf')
                    long_reclaim_high = 0.0
                    long_lvn = 0.0
                    short_state = "IDLE"
                    short_extreme = 0.0
                    short_reclaim_low = float('inf')
                    short_lvn = 0.0
            
            is_ivb_formation = (now.hour == 9 and now.minute >= 30)
            use_midday_pause = state.get("use_midday_pause", True)
            is_midday = use_midday_pause and ((now.hour == 12) or (now.hour == 13 and now.minute < 30))
            time_zone_active = not (is_ivb_formation or is_midday)
            
            if vp.poc == 0.0 or vp.last_poc == 0.0 or not current_tick:
                await asyncio.sleep(0.25)
                continue
                
            current_price = current_tick.last
            
            if current_price >= vp.last_poc: long_state = "IDLE"
            if current_price <= vp.last_poc: short_state = "IDLE"
                
            def execute_trade_and_notify(order_type, volume, sl=None, tp=None, reason="Unknown", magic=1337, strategy="V1"):
                success = engine.order_send(order_type, volume, sl=sl, tp=tp, magic=magic, comment=f"S-{strategy}")
                if success:
                    ticket = getattr(success, 'order', 0)
                    trade_tracker.add_trade(ticket, order_type, current_price, sl, tp, reason, strategy)
                    vwap_str = f"{vwap:,.2f}" if vwap else "N/A"
                    msg = (
                        f"🚨 *TRADE EXECUTED [{strategy}]* 🚨\n"
                        f"Action: `{order_type}` ({volume} Lots)\n"
                        f"Reason: _{reason}_\n"
                        f"Price: `{current_price:,.2f}`\n"
                        f"SL: `{sl:,.2f}` | TP: `{tp:,.2f}`\n\n"
                        f"📊 *Market Context:*\n"
                        f"Bias: `{auto_bias}` (🤖 Auto-VWAP)\n"
                        f"VWAP: `{vwap_str}`\n"
                        f"Previous VA:\n"
                        f"  POC: `{vp.last_poc:,.2f}`\n"
                    )
                    notification_queue.put_nowait(msg)
                return success
            
            # --- TRADE MANAGEMENT (V1: Breakeven) ---
            if len(pos_v1) > 0:
                for pos in pos_v1:
                    entry = pos.price_open
                    tp = pos.tp
                    sl = pos.sl
                    if tp > 0.0 and sl != entry:
                        if pos.type == 0: # BUY
                            if current_price >= entry + ((tp - entry) * 0.5) and sl < entry:
                                engine.modify_sl(pos.ticket, entry)
                        elif pos.type == 1: # SELL
                            if current_price <= entry - ((entry - tp) * 0.5) and (sl > entry or sl == 0):
                                engine.modify_sl(pos.ticket, entry)

            # --- TRADE MANAGEMENT (V2: Partial Scale-Out) ---
            if len(pos_v2) > 0:
                for pos in pos_v2:
                    entry = pos.price_open
                    tp = pos.tp
                    sl = pos.sl
                    # If volume is >= 4.0, we haven't scaled out yet
                    if tp > 0.0 and pos.volume >= 4.0:
                        if pos.type == 0: # BUY
                            if current_price >= entry + ((tp - entry) * 0.5):
                                # Scale out 75% (3.0 lots) and move SL to entry
                                engine.close_partial_position(pos.ticket, 3.0)
                                if sl < entry: engine.modify_sl(pos.ticket, entry)
                        elif pos.type == 1: # SELL
                            if current_price <= entry - ((entry - tp) * 0.5):
                                # Scale out 75% (3.0 lots) and move SL to entry
                                engine.close_partial_position(pos.ticket, 3.0)
                                if sl > entry or sl == 0: engine.modify_sl(pos.ticket, entry)
            
            # --- ENTRY SETUP (SNAP-BACK MACHINE) ---
            now_ts = datetime.datetime.now().timestamp()
            if time_zone_active and (now_ts - last_trade_time > 1.0):
                footprint = engine.get_footprint_data()
                
                # LONG SETUP
                if auto_bias in ["Bullish", "Neutral"]:
                    if long_state == "IDLE":
                        if current_price < vp.last_val:
                            long_state = "TRAP"
                            long_extreme = current_price
                    elif long_state == "TRAP":
                        if current_price < long_extreme: long_extreme = current_price
                        if current_price > vp.last_val:
                            long_reclaim_high = current_price
                            long_lvn = engine.calculate_lvn(long_extreme, long_reclaim_high, footprint)
                            long_state = "RECLAIM"
                    elif long_state == "RECLAIM":
                        if current_price >= vp.last_poc:
                            long_state = "IDLE"
                        elif current_price <= long_lvn + 5:
                            if check_aggression(footprint, long_lvn, "LONG"):
                                sl = long_lvn - 10
                                tp = vp.last_poc
                                reason = f"Reclaim LVN Pullback [VWAP]"
                                trade_fired = False
                                if mode_v1 == "ACTIVE" and len(pos_v1) == 0:
                                    if execute_trade_and_notify("BUY", 1.0, sl=sl, tp=tp, reason=reason, magic=1337, strategy="V1"): trade_fired = True
                                if mode_v2 == "ACTIVE" and len(pos_v2) == 0:
                                    if execute_trade_and_notify("BUY", 4.0, sl=sl, tp=tp, reason=reason, magic=1338, strategy="V2"): trade_fired = True
                                if trade_fired: last_trade_time = datetime.datetime.now().timestamp()
                                long_state = "IDLE"
                                
                # SHORT SETUP
                if auto_bias in ["Bearish", "Neutral"]:
                    if short_state == "IDLE":
                        if current_price > vp.last_vah:
                            short_state = "TRAP"
                            short_extreme = current_price
                    elif short_state == "TRAP":
                        if current_price > short_extreme: short_extreme = current_price
                        if current_price < vp.last_vah:
                            short_reclaim_low = current_price
                            short_lvn = engine.calculate_lvn(short_extreme, short_reclaim_low, footprint)
                            short_state = "RECLAIM"
                    elif short_state == "RECLAIM":
                        if current_price <= vp.last_poc:
                            short_state = "IDLE"
                        elif current_price >= short_lvn - 5:
                            if check_aggression(footprint, short_lvn, "SHORT"):
                                sl = short_lvn + 10
                                tp = vp.last_poc
                                reason = f"Reclaim LVN Pullback [VWAP]"
                                trade_fired = False
                                if mode_v1 == "ACTIVE" and len(pos_v1) == 0:
                                    if execute_trade_and_notify("SELL", 1.0, sl=sl, tp=tp, reason=reason, magic=1337, strategy="V1"): trade_fired = True
                                if mode_v2 == "ACTIVE" and len(pos_v2) == 0:
                                    if execute_trade_and_notify("SELL", 4.0, sl=sl, tp=tp, reason=reason, magic=1338, strategy="V2"): trade_fired = True
                                if trade_fired: last_trade_time = datetime.datetime.now().timestamp()
                                short_state = "IDLE"

            # --- EXPORT STATE FOR MQL5 VISUALIZER ---
            if visual_csv_path and vp.last_poc > 0:
                try:
                    # Format: VWAP, POC, VAH, VAL, LONG_STATE, SHORT_STATE, LONG_LVN, SHORT_LVN
                    csv_data = f"{(vwap or 0.0):.2f},{vp.last_poc:.2f},{vp.last_vah:.2f},{vp.last_val:.2f},{long_state},{short_state},{long_lvn:.2f},{short_lvn:.2f}\n"
                    with open(visual_csv_path, "w") as f:
                        f.write(csv_data)
                except Exception as e:
                    logger.debug(f"Failed to write visual CSV: {e}")

        except Exception as e:
            logger.error(f"Error in execution loop: {e}", exc_info=True)
            
        await asyncio.sleep(0.25)

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(execution_loop())
