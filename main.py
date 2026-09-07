import asyncio
import logging
import sys
import os

from dotenv import load_dotenv
load_dotenv()

from control.tg_bot import run_bot
from control.news_monitor import monitor_news
from execution.logic_loop import execution_loop

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

async def main():
    logger.info("Starting OrderFlowKawa System...")
    
    # Run all three main components concurrently
    await asyncio.gather(
        run_bot(),
        monitor_news(),
        execution_loop()
    )

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("System shutting down...")
