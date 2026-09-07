import MetaTrader5 as mt5
import logging
import time
import datetime
import os
import pandas as pd

logger = logging.getLogger(__name__)

class MT5Engine:
    def __init__(self, symbol="NQ", terminal_path=None):
        self.symbol = symbol
        self.terminal_path = terminal_path

    def initialize(self):
        """Initialize the MT5 connection with optional login credentials."""
        init_kwargs = {}
        if self.terminal_path:
            init_kwargs["path"] = self.terminal_path
        
        # Support authenticated login via environment variables
        login = os.getenv("MT5_LOGIN")
        password = os.getenv("MT5_PASSWORD")
        server = os.getenv("MT5_SERVER")
        
        if login:
            init_kwargs["login"] = int(login)
        if password:
            init_kwargs["password"] = password
        if server:
            init_kwargs["server"] = server
            
        if not mt5.initialize(**init_kwargs):
            logger.error("MT5 initialize() failed, error code = %s", mt5.last_error())
            return False
        
        term = mt5.terminal_info()
        logger.info(f"Connected to broker: {term.company}")
        
        # For futures brokers, the symbol name includes the contract month
        # e.g., "NQ" might be listed as "NQU5", "NQZ5", etc.
        # Try the exact symbol first, then search for active contracts
        resolved = self._resolve_symbol(self.symbol)
        if resolved is None:
            logger.error(f"Could not resolve any tradable symbol for '{self.symbol}'")
            return False
        
        self.symbol = resolved
        logger.info(f"Successfully initialized MT5 and selected {self.symbol}")
        return True

    def _resolve_symbol(self, base_symbol):
        """Try to find and select the correct symbol in MarketWatch.
        
        For futures, the symbol might be 'NQ', 'NQU5', 'NQ-SEP25', etc.
        For CFDs, it might be '.USTECHCash', 'USTEC', etc.
        """
        # 1. Try exact match first
        if mt5.symbol_select(base_symbol, True):
            info = mt5.symbol_info(base_symbol)
            if info is not None:
                logger.info(f"Exact match found: {base_symbol}")
                return base_symbol
        
        # 2. Search all symbols that contain the base name
        all_symbols = mt5.symbols_get()
        if all_symbols is None:
            logger.error("Failed to retrieve symbol list from broker.")
            return None
        
        candidates = []
        for sym in all_symbols:
            if base_symbol.upper() in sym.name.upper():
                candidates.append(sym)
        
        if not candidates:
            logger.error(f"No symbols found containing '{base_symbol}'")
            # Log a sample of available symbols for debugging
            sample = [s.name for s in (all_symbols[:20] if all_symbols else [])]
            logger.info(f"Sample available symbols: {sample}")
            return None
        
        # 3. Log all candidates so we can see what's available
        logger.info(f"Found {len(candidates)} symbol(s) matching '{base_symbol}':")
        for c in candidates:
            logger.info(f"  -> {c.name} (spread={c.spread}, trade_mode={c.trade_mode})")
        
        # 4. Pick the first tradeable one (trade_mode != SYMBOL_TRADE_MODE_DISABLED)
        for c in candidates:
            if c.trade_mode != 0:  # 0 = SYMBOL_TRADE_MODE_DISABLED
                if mt5.symbol_select(c.name, True):
                    logger.info(f"Selected active contract: {c.name}")
                    return c.name
        
        # 5. Fallback: just pick the first candidate
        first = candidates[0].name
        mt5.symbol_select(first, True)
        logger.warning(f"No active tradable contract found, falling back to: {first}")
        return first

    def shutdown(self):
        mt5.shutdown()

    def check_and_reconnect(self):
        """Check MT5 connection and reconnect if necessary."""
        term_info = mt5.terminal_info()
        if term_info is None or not term_info.connected:
            logger.warning("MT5 terminal disconnected. Attempting to reconnect...")
            return self.initialize()
        return True

    def get_atr(self, period=14, timeframe=mt5.TIMEFRAME_M5):
        """Calculate the Average True Range (ATR)."""
        try:
            rates = mt5.copy_rates_from_pos(self.symbol, timeframe, 0, period + 1)
            if rates is None or len(rates) < period + 1:
                logger.error("Failed to fetch rates for ATR calculation")
                return None
            
            tr_list = []
            for i in range(1, len(rates)):
                high = rates[i]['high']
                low = rates[i]['low']
                prev_close = rates[i-1]['close']
                tr = max(high - low, abs(high - prev_close), abs(low - prev_close))
                tr_list.append(tr)
                
            return sum(tr_list) / len(tr_list)
        except Exception as e:
            logger.error(f"Error calculating ATR: {e}")
            return None

    def get_latest_ticks(self, count=100):
        """Fetch the latest tick data."""
        try:
            current_tick = mt5.symbol_info_tick(self.symbol)
            if current_tick is None:
                logger.error("Failed to fetch current tick for timestamp reference")
                return []
                
            ticks = mt5.copy_ticks_from(self.symbol, current_tick.time, count, mt5.COPY_TICKS_ALL)
            if ticks is None:
                logger.error("MT5 copy_ticks_from failed, error code = %s", mt5.last_error())
                return []
            return ticks
        except Exception as e:
            logger.error(f"Error fetching ticks: {e}")
            return []

    def get_current_price(self):
        """Get the current bid/ask price."""
        try:
            tick = mt5.symbol_info_tick(self.symbol)
            if tick is None:
                return None
            return tick
        except Exception as e:
            logger.error(f"Error getting current price: {e}")
            return None

    def get_open_positions(self):
        """Get all open positions for the current symbol."""
        try:
            positions = mt5.positions_get(symbol=self.symbol)
            if positions is None:
                return []
            return positions
        except Exception as e:
            logger.error(f"Error fetching positions: {e}")
            return []

    def order_send(self, order_type, volume, price=None, sl=None, tp=None, magic=1337, comment="OrderFlowKawa"):
        """Send a market order with strict error handling."""
        symbol_info = mt5.symbol_info(self.symbol)
        if symbol_info is None:
            logger.error(f"{self.symbol} not found.")
            return None
            
        point = symbol_info.point
        
        # Determine correct filling mode for the broker
        # Futures typically use IOC or FOK
        filling_type = mt5.ORDER_FILLING_IOC
        if symbol_info.filling_mode & mt5.ORDER_FILLING_FOK:
            filling_type = mt5.ORDER_FILLING_FOK
        elif symbol_info.filling_mode & mt5.ORDER_FILLING_IOC:
            filling_type = mt5.ORDER_FILLING_IOC
        elif symbol_info.filling_mode & mt5.ORDER_FILLING_RETURN:
            filling_type = mt5.ORDER_FILLING_RETURN
        
        # Build the request
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": self.symbol,
            "volume": float(volume),
            "type": mt5.ORDER_TYPE_BUY if order_type == "BUY" else mt5.ORDER_TYPE_SELL,
            "price": mt5.symbol_info_tick(self.symbol).ask if order_type == "BUY" else mt5.symbol_info_tick(self.symbol).bid,
            "deviation": 20,
            "magic": magic,
            "comment": comment,
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": filling_type,
        }
        
        tick_size = symbol_info.trade_tick_size
        if tick_size > 0:
            if sl:
                sl = round(float(sl) / tick_size) * tick_size
            if tp:
                tp = round(float(tp) / tick_size) * tick_size

        if sl:
            request["sl"] = float(sl)
        if tp:
            request["tp"] = float(tp)
            
        logger.info(f"Sending order: {request}")
            
        try:
            result = mt5.order_send(request)
            if result.retcode != mt5.TRADE_RETCODE_DONE:
                logger.error(f"Order failed, retcode={result.retcode}: {result.comment}")
                return None
            logger.info(f"Order sent successfully! Ticket: {result.order}")
            return result
        except Exception as e:
            logger.error(f"Exception during order_send: {e}")
            return None

    def close_all_positions(self):
        """Panic button liquidation."""
        positions = self.get_open_positions()
        for pos in positions:
            order_type = "SELL" if pos.type == mt5.ORDER_TYPE_BUY else "BUY"
            self.order_send(order_type, pos.volume)
        logger.info("All positions closed.")

    def close_partial_position(self, ticket, volume_to_close):
        """Close a specific volume of an existing position."""
        positions = mt5.positions_get(ticket=ticket)
        if not positions:
            logger.error(f"Cannot close partial: Position {ticket} not found.")
            return False
            
        pos = positions[0]
        if volume_to_close >= pos.volume:
            logger.warning("Requested partial volume is >= total volume. Closing entirely.")
            volume_to_close = pos.volume
            
        order_type = "SELL" if pos.type == mt5.ORDER_TYPE_BUY else "BUY"
        
        symbol_info = mt5.symbol_info(self.symbol)
        filling_type = mt5.ORDER_FILLING_IOC
        if symbol_info.filling_mode & mt5.ORDER_FILLING_FOK: filling_type = mt5.ORDER_FILLING_FOK
        elif symbol_info.filling_mode & mt5.ORDER_FILLING_IOC: filling_type = mt5.ORDER_FILLING_IOC
        elif symbol_info.filling_mode & mt5.ORDER_FILLING_RETURN: filling_type = mt5.ORDER_FILLING_RETURN
            
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": self.symbol,
            "volume": float(volume_to_close),
            "type": mt5.ORDER_TYPE_BUY if order_type == "BUY" else mt5.ORDER_TYPE_SELL,
            "position": ticket,
            "price": mt5.symbol_info_tick(self.symbol).ask if order_type == "BUY" else mt5.symbol_info_tick(self.symbol).bid,
            "deviation": 20,
            "magic": pos.magic,
            "comment": "Partial Close",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": filling_type,
        }
        
        logger.info(f"Sending partial close for ticket {ticket}: {request}")
        result = mt5.order_send(request)
        if result.retcode != mt5.TRADE_RETCODE_DONE:
            logger.error(f"Partial close failed: {result.comment}")
            return False
        return True

    def get_position_pnl(self, ticket):
        """Checks if a position is closed, and returns (is_closed, pnl, close_reason)."""
        try:
            if not self.check_and_reconnect(): return False, 0.0, "Unknown"
            
            # Check open positions
            positions = mt5.positions_get(ticket=ticket)
            if positions is not None and len(positions) > 0:
                # Still open
                return False, 0.0, "Open"
                
            # If not in open, check history
            history = mt5.history_deals_get(position=ticket)
            if history is None or len(history) == 0:
                return False, 0.0, "Unknown"
                
            # Calculate PnL from history deals
            total_profit = sum(deal.profit for deal in history)
            
            # Determine close reason from the closing deal (last deal)
            closing_deal = history[-1]
            comment = getattr(closing_deal, 'comment', '').lower()
            
            if 'sl' in comment:
                reason = "Stop Loss"
            elif 'tp' in comment:
                reason = "Take Profit"
            else:
                reason = "Manual Close"
            
            return True, total_profit, reason
            
        except Exception as e:
            logger.error(f"Error checking position PnL for {ticket}: {e}")
            return False, 0.0, "Error"

    def get_opening_range_high_low(self):
        """Fetches the High and Low of today's 9:30 AM - 10:30 AM EST range.
        Returns a tuple (high, low). Returns (None, None) if the data is incomplete or unavailable.
        """
        import pytz
        import datetime
        try:
            est = pytz.timezone("US/Eastern")
            now = datetime.datetime.now(est)
            
            # Construct 9:30 AM and 10:30 AM bounds for TODAY
            start_time = est.localize(datetime.datetime(now.year, now.month, now.day, 9, 30, 0))
            end_time = est.localize(datetime.datetime(now.year, now.month, now.day, 10, 30, 0))
            
            # If the current time is before 10:30 AM, the opening range is not fully formed yet.
            if now < end_time:
                return None, None
                
            rates = mt5.copy_rates_range(self.symbol, mt5.TIMEFRAME_M5, start_time, end_time)
            if rates is None or len(rates) == 0:
                return None, None
                
            high = float(max(rate['high'] for rate in rates))
            low = float(min(rate['low'] for rate in rates))
            return high, low
        except Exception as e:
            logger.error(f"Error fetching ORB high/low: {e}")
            return None, None

    def get_ema_200(self):
        """Fetches the 200 EMA on the 5-minute timeframe."""
        try:
            rates = mt5.copy_rates_from_pos(self.symbol, mt5.TIMEFRAME_M5, 0, 500)
            if rates is None or len(rates) < 200:
                return None
                
            closes = [r['close'] for r in rates]
            
            # Calculate EMA 200
            ema = closes[0]
            multiplier = 2 / (200 + 1)
            for close in closes[1:]:
                ema = (close - ema) * multiplier + ema
                
            return ema
        except Exception as e:
            logger.error(f"Error calculating EMA 200: {e}")
            return None

    def modify_sl(self, ticket, new_sl):
        """Modifies the Stop Loss of an open position."""
        try:
            if not self.check_and_reconnect():
                return False
                
            position = mt5.positions_get(ticket=ticket)
            if position is None or len(position) == 0:
                return False
                
            pos = position[0]
            
            # If the current SL is already what we want (or better), do nothing
            if abs(pos.sl - new_sl) < self.get_tick_size():
                return True
                
            request = {
                "action": mt5.TRADE_ACTION_SLTP,
                "position": pos.ticket,
                "symbol": pos.symbol,
                "sl": float(new_sl),
                "tp": float(pos.tp),
            }
            
            result = mt5.order_send(request)
            if result.retcode != mt5.TRADE_RETCODE_DONE:
                logger.warning(f"Failed to modify SL for {ticket}: {result.comment}")
                return False
            return True
        except Exception as e:
            logger.error(f"Exception modifying SL for {ticket}: {e}")
            return False

    def get_vwap(self, rth_only=False):
        """
        Calculates the intraday Volume-Weighted Average Price (VWAP).
        If rth_only is True, calculates from the 09:30 EST open.
        Otherwise, calculates from the session start (00:00 MT5 server time).
        """
        try:
            if not self.check_and_reconnect(): return None
            
            # Getting rates for today only
            today = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
            rates = mt5.copy_rates_from(self.symbol, mt5.TIMEFRAME_M1, datetime.datetime.now(), 1440)
            if rates is None or len(rates) == 0:
                return None
                
            df = pd.DataFrame(rates)
            df['time'] = pd.to_datetime(df['time'], unit='s')
            df = df[df['time'] >= today]
            
            if len(df) == 0:
                return None
                
            # Typical Price = (High + Low + Close) / 3
            df['typical_price'] = (df['high'] + df['low'] + df['close']) / 3
            df['pv'] = df['typical_price'] * df['tick_volume']
            
            vwap = df['pv'].sum() / df['tick_volume'].sum()
            return vwap
        except Exception as e:
            logger.error(f"Error calculating VWAP: {e}")
            return None

    def get_ivb(self):
        """
        Calculates the Initial Value Balance (IVB) High and Low.
        Assumes the RTH open is between 09:30 and 10:00 MT5 server time.
        Note: If the MT5 server is in a different timezone, this needs an offset.
        """
        try:
            if not self.check_and_reconnect(): return None, None
            
            today = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
            rates = mt5.copy_rates_from(self.symbol, mt5.TIMEFRAME_M1, datetime.datetime.now(), 1440)
            if rates is None or len(rates) == 0:
                return None, None
                
            df = pd.DataFrame(rates)
            df['time'] = pd.to_datetime(df['time'], unit='s')
            
            # Filter for 09:30:00 to 10:00:00
            # Note: We use server time hours here. User may need to adjust if server is not EST.
            df = df[(df['time'] >= today.replace(hour=9, minute=30)) & (df['time'] <= today.replace(hour=10, minute=0))]
            
            if len(df) == 0:
                return None, None
                
            return df['high'].max(), df['low'].min()
        except Exception as e:
            logger.error(f"Error calculating IVB: {e}")
            return None, None

    def get_footprint_data(self, lookback_ticks=1000):
        """
        Retrieves the latest tick data to analyze bid/ask volume delta (Triple-A Framework).
        Returns a DataFrame with tick-by-tick volumes and trade direction flags.
        """
        try:
            if not self.check_and_reconnect(): return None
            ticks = mt5.copy_ticks_from(self.symbol, datetime.datetime.now(), lookback_ticks, mt5.COPY_TICKS_ALL)
            if ticks is None or len(ticks) == 0:
                return None
                
            df = pd.DataFrame(ticks)
            df['time'] = pd.to_datetime(df['time'], unit='s')
            
            # TICK_FLAG_BUY = 32, TICK_FLAG_SELL = 64 (usually)
            # This allows us to map Ask vs Bid volume.
            def get_direction(flag):
                if flag & 32: return 'ASK' # Aggressive Buy
                if flag & 64: return 'BID' # Aggressive Sell
                return 'UNKNOWN'
                
            df['aggressor'] = df['flags'].apply(get_direction)
            return df
        except Exception as e:
            logger.error(f"Error getting footprint data: {e}")
            return None

    def calculate_lvn(self, start_price, end_price, ticks_df=None):
        """
        THESIS RULE: The LVN is the 50% structural pullback of the Reclaim Leg.
        When price traps and reclaims, it moves so fast it leaves a liquidity void.
        The institutions that originated the move will defend the 50% retracement.
        
        This replaces the broken profile.idxmin() logic which chased the absolute
        bottom/top of drops instead of waiting for a proper pullback.
        """
        return (start_price + end_price) / 2.0

