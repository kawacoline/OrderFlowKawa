import asyncio
import logging
import requests
from bs4 import BeautifulSoup
import datetime
import pytz
import os
import sys

# Add parent to path so we can import core
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
from core import state_manager
from control import tg_bot

logger = logging.getLogger(__name__)

async def fetch_high_impact_usd_events():
    """Scrapes ForexFactory for high impact USD events today."""
    url = "https://www.forexfactory.com/"
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"
    }
    
    events = []
    try:
        # Note: ForexFactory scraping can be tricky due to anti-bot measures.
        # For a robust production system, consider a dedicated API or a more resilient scraper.
        # Here we provide a functional skeleton.
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code != 200:
            logger.error(f"Failed to fetch ForexFactory. Status: {response.status_code}")
            return events
            
        soup = BeautifulSoup(response.content, 'html.parser')
        
        # This is a simplified extraction logic
        # You'd typically find the table rows and check for the 'high' impact span
        rows = soup.find_all('tr', class_='calendar__row')
        for row in rows:
            impact_cell = row.find('td', class_='calendar__impact')
            currency_cell = row.find('td', class_='calendar__currency')
            time_cell = row.find('td', class_='calendar__time')
            
            if impact_cell and currency_cell and time_cell:
                impact = impact_cell.find('span')
                if impact and 'high' in impact.get('class', []):
                    currency = currency_cell.text.strip()
                    if currency == 'USD':
                        time_str = time_cell.text.strip()
                        events.append(time_str)
                        
    except Exception as e:
        logger.error(f"Error scraping news: {e}")
        
    return events

async def monitor_news():
    """Polls for news and triggers interrupts during events."""
    logger.info("Starting News Monitor...")
    est = pytz.timezone('US/Eastern')
    
    while True:
        try:
            now = datetime.datetime.now(est)
            
            # For simplicity, we assume events happen at the top/bottom of hours
            # In a real scenario, we'd sync the fetched event times.
            # We'll just check if it's within 1 minute of a major release time like 8:30 AM EST or 2:00 PM EST
            
            critical_times = [(8, 30), (10, 0), (14, 0)]  # Common high impact times
            
            is_critical = any(now.hour == h and now.minute == m for h, m in critical_times)
            
            if is_critical:
                logger.warning("🚨 HIGH IMPACT NEWS EVENT DETECTED. Pausing Execution.")
                state = state_manager.read_state()
                if state['bias'] != "Paused":
                    state_manager.update_bias("Paused")
                    state_manager.update_auto_bias(False)
                    
                    if hasattr(tg_bot, 'ADMIN_IDS') and tg_bot.ADMIN_IDS:
                        from telegram import Bot, InlineKeyboardButton, InlineKeyboardMarkup
                        bot = Bot(tg_bot.TOKEN)
                        
                        keyboard = [
                            [InlineKeyboardButton("Resume Current Bias", callback_data='bias_neutral')],
                            [InlineKeyboardButton("Flip Bias", callback_data='bias_bearish')],
                            [InlineKeyboardButton("Close All Positions & Halt", callback_data='liquidate')]
                        ]
                        reply_markup = InlineKeyboardMarkup(keyboard)
                        
                        for admin_id in tg_bot.ADMIN_IDS:
                            try:
                                await bot.send_message(
                                    chat_id=admin_id,
                                    text="🚨 ABRUPT VOLATILITY SHIFT DETECTED. Execution Paused. How do you want to proceed?",
                                    reply_markup=reply_markup
                                )
                            except Exception as e:
                                logger.error(f"Failed to send pause alert to {admin_id}: {e}")
                
                # Sleep for 2 minutes to avoid rapid triggering
                await asyncio.sleep(120)
                
            await asyncio.sleep(30)
            
        except Exception as e:
            logger.error(f"News monitor error: {e}")
            await asyncio.sleep(60)

if __name__ == "__main__":
    asyncio.run(monitor_news())
