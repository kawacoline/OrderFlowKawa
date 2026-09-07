import asyncio

# Global queue for cross-component notifications
# Items should be formatted strings ready for Telegram broadcasting
notification_queue = asyncio.Queue()
