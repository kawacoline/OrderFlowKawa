import logging
import asyncio
import time
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, ContextTypes
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from core import state_manager
from core import trade_tracker
from core.events import notification_queue

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)

TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
admin_env = os.getenv("TELEGRAM_ADMIN_IDS", "")
ADMIN_IDS = [int(x.strip()) for x in admin_env.split(',') if x.strip().isdigit()]

from functools import wraps

def admin_only(func):
    @wraps(func)
    async def wrapped(update: Update, context: ContextTypes.DEFAULT_TYPE, *args, **kwargs):
        user_id = update.effective_user.id
        if user_id not in ADMIN_IDS:
            if update.message:
                await update.message.reply_text("⛔ Access Denied.")
            elif update.callback_query:
                await update.callback_query.answer("⛔ Access Denied", show_alert=True)
            return
        return await func(update, context, *args, **kwargs)
    return wrapped

def _fmt(price):
    try: return f"{float(price):,.2f}"
    except: return str(price)

@admin_only
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg = (
        "Welcome to *OrderFlowKawa*\n\n"
        "This bot trades the *Micro E-mini Nasdaq 100 (MNQ)* using the "
        "Cimi & Valentini *Triple-A Framework* (Absorption, Accumulation, Aggression).\n\n"
        "It maps the Volume Profile, tracks institutional footprints at the LVN, "
        "and strictly filters entries using Intraday VWAP and the 30-min IVB.\n\n"
        "Use the buttons below to learn the system or check live status."
    )
    keyboard = [
        [InlineKeyboardButton("🎓 Institutional Masterclass", callback_data='tutorial_p1')],
        [InlineKeyboardButton("📊 Status & Control", callback_data='show_status')]
    ]
    await context.bot.send_message(
        chat_id=update.effective_chat.id, text=msg,
        parse_mode='Markdown', reply_markup=InlineKeyboardMarkup(keyboard)
    )

TUTORIAL_PAGES = {
    'tutorial_p1': {
        'text': (
            "*Page 1/6 -- The Volume Profile & True Value*\n\n"
            "This bot analyzes tick-by-tick order flow on the CME (Chicago Mercantile Exchange). "
            "It maps a Volume Profile to find exactly where institutions are trading.\n\n"
            "*POC (Point of Control)*: The magnet. The fairest price of the day.\n"
            "*VAH (Value Area High)*: The ceiling of the 70% value zone.\n"
            "*VAL (Value Area Low)*: The floor of the 70% value zone.\n\n"
            "Most retail bots just buy when price touches the floor. We don't. We track the footprint."
        ),
        'nav': [[InlineKeyboardButton("Next >>", callback_data='tutorial_p2')]]
    },
    'tutorial_p2': {
        'text': (
            "*Page 2/6 -- The Institutional Trap*\n\n"
            "To execute a trade, the bot first waits for a *Failed Breakout* (The Trap).\n\n"
            "Price must push OUTSIDE the Value Area. As retail traders chase the breakout, "
            "our bot scans the Bid/Ask footprint for *Absorption*.\n\n"
            "Absorption happens when volume spikes but the price stops moving—institutions "
            "are silently placing massive passive limit orders to cap the move. This sets the trap."
        ),
        'nav': [[InlineKeyboardButton("<< Back", callback_data='tutorial_p1'), InlineKeyboardButton("Next >>", callback_data='tutorial_p3')]]
    },
    'tutorial_p3': {
        'text': (
            "*Page 3/6 -- The Snap-Back Model*\n\n"
            "Once the trap is set, the bot waits for the *Reclaim Leg*—an impulsive price move "
            "that snaps back inside the Value Area.\n\n"
            "The bot maps a micro-profile exclusively on this single leg to find the "
            "*LVN (Low-Volume Node)*. An LVN is a liquidity void left behind by aggressive institutional sweeping.\n\n"
            "We do not enter immediately. We wait for price to pull back and test this exact LVN."
        ),
        'nav': [[InlineKeyboardButton("<< Back", callback_data='tutorial_p2'), InlineKeyboardButton("Next >>", callback_data='tutorial_p4')]]
    },
    'tutorial_p4': {
        'text': (
            "*Page 4/6 -- The Triple-A Framework (Entry)*\n\n"
            "When price pulls back to the LVN, the bot checks for the final A: *Aggression*.\n\n"
            "It reads the Level 2 Bid/Ask footprint. If it detects a massive imbalance (e.g., 300% more buying than selling), "
            "the trade is instantly executed.\n\n"
            "*Take Profit*: Strictly the POC (Equilibrium).\n"
            "*Stop Loss*: Placed 1-2 ticks precisely below the institutional footprint imbalance. "
            "If the institutions fail to hold the level, we instantly abort for a microscopic loss."
        ),
        'nav': [[InlineKeyboardButton("<< Back", callback_data='tutorial_p3'), InlineKeyboardButton("Next >>", callback_data='tutorial_p5')]]
    },
    'tutorial_p5': {
        'text': (
            "*Page 5/6 -- VWAP and Time Governors*\n\n"
            "The bot uses strict filters to avoid chop and bad trades:\n\n"
            "*1. VWAP (Auto-Bias)*: VWAP dictates institutional direction. If price is above VWAP, "
            "the bot will only take LONG setups. If below, only SHORTS.\n\n"
            "*2. IVB (Initial Value Balance)*: The bot ignores the first 30 mins (09:30-10:00 EST) "
            "while institutions establish the day's boundaries.\n\n"
            "*3. Lunchtime Chop*: The bot pauses dynamically between 12:00-13:30 EST when "
            "institutional volume dries up."
        ),
        'nav': [[InlineKeyboardButton("<< Back", callback_data='tutorial_p4'), InlineKeyboardButton("Next >>", callback_data='tutorial_p6')]]
    },
    'tutorial_p6': {
        'text': (
            "*Page 6/6 -- Your Role*\n\n"
            "Because this engine uses VWAP for directional bias and footprints for entry, "
            "it is *100% Autonomous*.\n\n"
            "You do not need to set a bias. You only need to toggle the engine:\n"
            "▶️ *ACTIVE* -- Bot maps order flow and trades automatically.\n"
            "⏸️ *PAUSED* -- Bot halts all trading.\n\n"
            "Use `/status` to start or stop the bot, and `/risk` to customize the time filters."
        ),
        'nav': [[InlineKeyboardButton("<< Back", callback_data='tutorial_p5')]]
    }
}

def _get_status_content():
    state = state_manager.read_state()
    mode_v1 = state.get('engine_mode_v1', 'ACTIVE')
    mode_v2 = state.get('engine_mode_v2', 'PAUSED')
    poc = _fmt(state.get('poc', 0))
    vah = _fmt(state.get('vah', 0))
    val = _fmt(state.get('val', 0))
    
    msg = (
        f"📊 *Engine Status & Control*\n\n"
        f"**V1 (Full TP - 1 Lot) [Magic: 1337]**\n"
        f"Mode: *{mode_v1}*\n\n"
        f"**V2 (Scale-Out - 4 Lots) [Magic: 1338]**\n"
        f"Mode: *{mode_v2}*\n\n"
        f"*Developing Value Area:*\n"
        f"VAH: {vah}\n"
        f"POC: {poc}\n"
        f"VAL: {val}\n\n"
        f"_(Live VWAP and State Machine tracking is logged in the MT5 Engine console.)_"
    )
    keyboard = [
        [InlineKeyboardButton(f"V1: {'▶️ ACTIVE' if mode_v1=='ACTIVE' else '⏸️ PAUSED'}", callback_data='engineV1_toggle')],
        [InlineKeyboardButton(f"V2: {'▶️ ACTIVE' if mode_v2=='ACTIVE' else '⏸️ PAUSED'}", callback_data='engineV2_toggle')]
    ]
    return msg, keyboard

async def _send_status_menu(chat_id, context):
    msg, kb = _get_status_content()
    await context.bot.send_message(
        chat_id=chat_id, text=msg,
        parse_mode='Markdown', reply_markup=InlineKeyboardMarkup(kb)
    )

@admin_only
async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await _send_status_menu(update.effective_chat.id, context)

async def _send_risk_menu(chat_id, context):
    state = state_manager.read_state()
    ivb = state.get('use_ivb_suspend', True)
    midday = state.get('use_midday_pause', True)
    breakeven = state.get('use_breakeven', True)
    
    msg = (
        "🛡️ *Risk & Filter Management*\n\n"
        "Customize the algorithmic filters below:"
    )
    keyboard = [
        [InlineKeyboardButton(f"IVB Trend Suspend: {'✅ ON' if ivb else '❌ OFF'}", callback_data='toggle_ivb')],
        [InlineKeyboardButton(f"Midday Volumetric Pause: {'✅ ON' if midday else '❌ OFF'}", callback_data='toggle_midday')],
        [InlineKeyboardButton(f"50% Breakeven SL: {'✅ ON' if breakeven else '❌ OFF'}", callback_data='toggle_breakeven')]
    ]
    await context.bot.send_message(
        chat_id=chat_id, text=msg,
        parse_mode='Markdown', reply_markup=InlineKeyboardMarkup(keyboard)
    )

@admin_only
async def risk_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await _send_risk_menu(update.effective_chat.id, context)

@admin_only
async def effectiveness_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    trades = trade_tracker.get_all_trades()
    if not trades:
        await context.bot.send_message(
            chat_id=update.effective_chat.id,
            text="📉 *Effectiveness Report*\n\nNo trades have been executed yet.",
            parse_mode='Markdown'
        )
        return

    def _calc_stats(trade_list):
        w = sum(1 for t in trade_list if t.get('status') == "Win")
        l = sum(1 for t in trade_list if t.get('status') == "Loss")
        o = sum(1 for t in trade_list if t.get('status') == "Ongoing")
        pnl = sum(t.get('pnl', 0.0) for t in trade_list)
        c = w + l
        wr = (w / c * 100) if c > 0 else 0
        return w, l, o, pnl, wr

    trades_v1 = [t for t in trades if t.get('strategy', 'V1') == 'V1']
    trades_v2 = [t for t in trades if t.get('strategy', 'V1') == 'V2']

    v1_w, v1_l, v1_o, v1_pnl, v1_wr = _calc_stats(trades_v1)
    v2_w, v2_l, v2_o, v2_pnl, v2_wr = _calc_stats(trades_v2)

    msg = (
        f"📈 *Effectiveness Report*\n\n"
        f"**Strategy V1 (Full TP)**\n"
        f"Total PnL: *${v1_pnl:,.2f}*\n"
        f"Win Rate: *{v1_wr:.1f}%* ({v1_w}W / {v1_l}L)\n"
        f"Ongoing: *{v1_o}*\n\n"
        f"**Strategy V2 (Scale-Out)**\n"
        f"Total PnL: *${v2_pnl:,.2f}*\n"
        f"Win Rate: *{v2_wr:.1f}%* ({v2_w}W / {v2_l}L)\n"
        f"Ongoing: *{v2_o}*\n\n"
        f"*Recent Trade History:*\n"
    )

    recent = trades[-15:]
    for t in recent:
        status = t.get('status')
        emoji = "🟢" if status == "Win" else "🔴" if status == "Loss" else "🟡"
        pnl_str = f" (${t.get('pnl', 0.0):,.2f})" if status != "Ongoing" else ""
        close_reason = f" [{t.get('close_reason')}]" if t.get('close_reason') and t.get('close_reason') != "Unknown" else ""
        strat = t.get('strategy', 'V1')
        msg += f"{emoji} {t['action']} [{strat}] | {t.get('reason', 'Unknown')}{close_reason}{pnl_str}\n"

    await context.bot.send_message(
        chat_id=update.effective_chat.id,
        text=msg,
        parse_mode='Markdown',
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton("🔄 Reset Report", callback_data='reset_effectiveness')
        ]])
    )

@admin_only
async def liquidate_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg = (
        "🚨 *PANIC BUTTON*\n\n"
        "Are you sure you want to market-close all open positions "
        "and pause the bot?"
    )
    keyboard = [
        [InlineKeyboardButton("YES -- LIQUIDATE NOW", callback_data='liquidate_execute')],
        [InlineKeyboardButton("Cancel", callback_data='liquidate_cancel')]
    ]
    await context.bot.send_message(
        chat_id=update.effective_chat.id, text=msg,
        parse_mode='Markdown', reply_markup=InlineKeyboardMarkup(keyboard)
    )

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    data = query.data
    chat_id = query.message.chat_id

    try:
        await query.answer()
    except:
        pass

    try:
        if data in TUTORIAL_PAGES:
            page = TUTORIAL_PAGES[data]
            await query.edit_message_text(
                text=page['text'],
                parse_mode='Markdown',
                reply_markup=InlineKeyboardMarkup(page['nav'])
            )
            
        elif data == 'show_status':
            await _send_status_menu(chat_id, context)
            
        elif data.startswith('engineV'):
            strategy = data.split('_')[0] # 'engineV1' or 'engineV2'
            state = state_manager.read_state()
            state_key = f"engine_mode_{strategy.lower()[-2:]}"
            current_mode = state.get(state_key, "PAUSED")
            state[state_key] = "PAUSED" if current_mode == "ACTIVE" else "ACTIVE"
            state_manager.write_state(state)
            msg, kb = _get_status_content()
            await query.edit_message_text(text=msg, parse_mode='Markdown', reply_markup=InlineKeyboardMarkup(kb))
            
        elif data == 'toggle_ivb':
            state = state_manager.read_state()
            state['use_ivb_suspend'] = not state.get('use_ivb_suspend', True)
            state_manager.write_state(state)
            await _send_risk_menu(chat_id, context)
            
        elif data == 'toggle_midday':
            state = state_manager.read_state()
            state['use_midday_pause'] = not state.get('use_midday_pause', True)
            state_manager.write_state(state)
            await _send_risk_menu(chat_id, context)
            
        elif data == 'toggle_breakeven':
            state = state_manager.read_state()
            state['use_breakeven'] = not state.get('use_breakeven', True)
            state_manager.write_state(state)
            await _send_risk_menu(chat_id, context)
            
        elif data == 'status':
            await status_command(update, context)
            
        elif data == 'liquidate_execute':
            state = state_manager.read_state()
            state['engine_mode'] = "PAUSED"
            state['liquidate_flag'] = True
            state_manager.write_state(state)
            await context.bot.send_message(chat_id=chat_id, text="🚨 *LIQUIDATION TRIGGERED*\nPositions closing. Bot Paused.", parse_mode='Markdown')
            
        elif data == 'liquidate_cancel':
            await context.bot.send_message(chat_id=chat_id, text="Cancelled. Operations normal.")
            
        elif data == 'reset_effectiveness':
            keyboard = [
                [InlineKeyboardButton("⚠️ YES, DELETE ALL HISTORY", callback_data='confirm_reset_eff')],
                [InlineKeyboardButton("Cancel", callback_data='cancel_reset_eff')]
            ]
            await context.bot.send_message(chat_id=chat_id, text="Are you sure you want to erase trade history?", reply_markup=InlineKeyboardMarkup(keyboard))
            
        elif data == 'confirm_reset_eff':
            trade_tracker.clear_trades()
            await context.bot.send_message(chat_id=chat_id, text="✅ Trade history reset.")
            
        elif data == 'cancel_reset_eff':
            await context.bot.send_message(chat_id=chat_id, text="Reset cancelled.")

    except Exception as e:
        logger.error(f"Error in button handler: {e}")

async def notification_listener(app):
    """Listens for cross-component events and broadcasts them to admins."""
    while True:
        msg = await notification_queue.get()
        for admin_id in ADMIN_IDS:
            try:
                await app.bot.send_message(
                    chat_id=admin_id,
                    text=msg,
                    parse_mode='Markdown'
                )
            except Exception as e:
                logger.error(f"Failed to send notification to {admin_id}: {e}")
        notification_queue.task_done()

async def run_bot():
    state_manager.init_state()
    app = ApplicationBuilder().token(TOKEN).build()

    await app.bot.set_my_commands([
        BotCommand("start", "Welcome & quick overview"),
        BotCommand("status", "Check system status & engine control"),
        BotCommand("risk", "Toggle IVB & Midday filters"),
        BotCommand("effectiveness", "View trade results & Triple-A metrics"),
        BotCommand("liquidate", "PANIC: Close all positions & pause")
    ])

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("status", status_command))
    app.add_handler(CommandHandler("risk", risk_command))
    app.add_handler(CommandHandler("effectiveness", effectiveness_command))
    app.add_handler(CommandHandler("liquidate", liquidate_command))
    app.add_handler(CallbackQueryHandler(button_handler))

    asyncio.create_task(notification_listener(app))

    logger.info("Telegram Bot started. Polling...")
    await app.initialize()
    await app.start()
    await app.updater.start_polling()

if __name__ == '__main__':
    asyncio.run(run_bot())
