import numpy as np
from collections import defaultdict
import datetime
import pytz
import json
import os
from filelock import FileLock

class VolumeProfile:
    def __init__(self, tick_size=0.25):
        self.tick_size = tick_size
        self.volume_at_price = defaultdict(float)
        self.total_volume = 0.0
        
        self.poc = 0.0
        self.vah = 0.0
        self.val = 0.0
        
        self.last_poc = 0.0
        self.last_vah = 0.0
        self.last_val = 0.0
        
        self.profile_file = "profile.json"
        self.lock_file = "profile.json.lock"
        
        # Determine current session boundaries
        self.current_session_start = None
        self.update_session_boundaries()

    def update_session_boundaries(self):
        """
        Updates the CME session boundaries.
        CME session starts at 6:00 PM EST and ends at 5:00 PM EST the next day.
        """
        est = pytz.timezone('US/Eastern')
        now_est = datetime.datetime.now(est)
        
        # If currently before 18:00, the session started yesterday at 18:00
        # If currently after or equal to 18:00, the session started today at 18:00
        if now_est.hour < 18:
            start_date = now_est - datetime.timedelta(days=1)
        else:
            start_date = now_est
            
        new_session_start = start_date.replace(hour=18, minute=0, second=0, microsecond=0)
        
        # If we entered a new session, lock in the old values and reset
        if self.current_session_start is not None and new_session_start > self.current_session_start:
            self.last_poc = self.poc
            self.last_vah = self.vah
            self.last_val = self.val
            self.volume_at_price.clear()
            self.total_volume = 0.0
            # Delete old profile file on session reset
            if os.path.exists(self.profile_file):
                try:
                    os.remove(self.profile_file)
                except Exception:
                    pass
            
        self.current_session_start = new_session_start

    def save_profile(self):
        if not self.volume_at_price:
            return
            
        state = {
            "session_start": self.current_session_start.timestamp() if self.current_session_start else 0,
            "total_volume": self.total_volume,
            "poc": self.poc,
            "vah": self.vah,
            "val": self.val,
            "last_poc": self.last_poc,
            "last_vah": self.last_vah,
            "last_val": self.last_val,
            "volume_at_price": {str(k): v for k, v in self.volume_at_price.items()}
        }
        
        lock = FileLock(self.lock_file, timeout=2)
        try:
            with lock:
                with open(self.profile_file, "w", encoding="utf-8") as f:
                    json.dump(state, f)
        except Exception:
            pass

    def load_profile(self):
        if not os.path.exists(self.profile_file):
            return
            
        lock = FileLock(self.lock_file, timeout=2)
        try:
            with lock:
                with open(self.profile_file, "r", encoding="utf-8") as f:
                    state = json.load(f)
                    
            saved_start = state.get("session_start", 0)
            current_start = self.current_session_start.timestamp() if self.current_session_start else 0
            
            # Discard if from an older session
            if current_start > saved_start:
                return
                
            self.total_volume = state.get("total_volume", 0.0)
            self.poc = state.get("poc", 0.0)
            self.vah = state.get("vah", 0.0)
            self.val = state.get("val", 0.0)
            self.last_poc = state.get("last_poc", 0.0)
            self.last_vah = state.get("last_vah", 0.0)
            self.last_val = state.get("last_val", 0.0)
            
            saved_vols = state.get("volume_at_price", {})
            self.volume_at_price.clear()
            for k, v in saved_vols.items():
                self.volume_at_price[float(k)] = float(v)
                
        except Exception:
            pass

    def add_tick(self, price, volume):
        self.update_session_boundaries()
        # Round price to nearest tick size
        rounded_price = round(price / self.tick_size) * self.tick_size
        self.volume_at_price[rounded_price] += volume
        self.total_volume += volume

    def calculate(self):
        if not self.volume_at_price:
            return

        # Convert to sorted numpy arrays
        prices = np.array(sorted(self.volume_at_price.keys()))
        volumes = np.array([self.volume_at_price[p] for p in prices])

        # Find POC
        poc_idx = np.argmax(volumes)
        self.poc = prices[poc_idx]

        # Calculate Value Area (70% of total volume)
        target_volume = self.total_volume * 0.70
        current_volume = volumes[poc_idx]
        
        upper_idx = poc_idx
        lower_idx = poc_idx
        
        while current_volume < target_volume:
            next_upper_vol = volumes[upper_idx + 1] if upper_idx + 1 < len(prices) else -1
            next_lower_vol = volumes[lower_idx - 1] if lower_idx - 1 >= 0 else -1
            
            if next_upper_vol == -1 and next_lower_vol == -1:
                break
                
            if next_upper_vol >= next_lower_vol:
                upper_idx += 1
                current_volume += volumes[upper_idx]
            else:
                lower_idx -= 1
                current_volume += volumes[lower_idx]

        self.vah = prices[upper_idx]
        self.val = prices[lower_idx]
        
        return self.poc, self.vah, self.val
