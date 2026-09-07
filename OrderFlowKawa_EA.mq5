//+------------------------------------------------------------------+
//|                                         OrderFlowKawa_EA.mq5     |
//|                                            Copyright 2026, KAWA  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, KAWA"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Inputs
input int    InpMaxHistoryDays = 30;     // Max Historical Days
input double InpProfileStep    = 1.0;    // Volume Profile Step (Points)
input double InpVA_Percent     = 70.0;   // Value Area Percentage

input string InpIVB_Start_Time    = "16:30"; // IVB Start (Broker Time, 09:30 EST)
input string InpIVB_End_Time      = "17:00"; // IVB End (Broker Time, 10:00 EST)
input string InpMidday_Start_Time = "19:00"; // Midday Void Start (Broker Time, 12:00 EST)
input string InpMidday_End_Time   = "20:30"; // Midday Void End (Broker Time, 13:30 EST)

input double InpLotSize        = 1.0;    // Trade Lot Size
input int    InpMagicNumber    = 2026;   // Magic Number
input int    InpMaxTradesPerDay = 3;      // Max Trades Per Day
input double InpSL_Buffer      = 10.0;   // SL Buffer Beyond Trap Extreme (points)
input bool   InpUseVWAPFilter  = false;  // Use VWAP Directional Governor
input bool   InpUseAbsorptionFilter = false; // Require Absorption for Entry

//--- Global Variables
int    last_calculated_day = -1;
double current_poc = 0.0;
double current_vah = 0.0;
double current_val = 0.0;

// State tracking
int    long_state = 0; // 0=IDLE, 1=TRAP, 2=RECLAIM
double long_extreme = 999999;
double long_lvn = 0;
int    short_state = 0;
double short_extreme = 0;
double short_lvn = 0;

double current_vwap_vol = 0.0;
double current_vwap_pv = 0.0;
double current_vwap = 0.0;
datetime current_day_start = 0;

long current_day_profile[200000];

// Time Parsing
int ivb_start_mins, ivb_end_mins, mid_start_mins, mid_end_mins;

// Session Tracking
double current_ivb_high = 0.0;
double current_ivb_low = 999999.0;
bool is_in_ivb = false;

// Trade Management
CTrade trade;
int trades_today = 0;
int last_trade_day = -1;

// Absorption tracking
bool absorption_detected = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   ArrayInitialize(current_day_profile, 0);
   
   // Parse time strings
   string sep[];
   StringSplit(InpIVB_Start_Time, ':', sep);
   if(ArraySize(sep) == 2) ivb_start_mins = (int)StringToInteger(sep[0]) * 60 + (int)StringToInteger(sep[1]);
   
   StringSplit(InpIVB_End_Time, ':', sep);
   if(ArraySize(sep) == 2) ivb_end_mins = (int)StringToInteger(sep[0]) * 60 + (int)StringToInteger(sep[1]);
   
   StringSplit(InpMidday_Start_Time, ':', sep);
   if(ArraySize(sep) == 2) mid_start_mins = (int)StringToInteger(sep[0]) * 60 + (int)StringToInteger(sep[1]);
   
   StringSplit(InpMidday_End_Time, ':', sep);
   if(ArraySize(sep) == 2) mid_end_mins = (int)StringToInteger(sep[0]) * 60 + (int)StringToInteger(sep[1]);
   
   CreateDashboard();
   
   Print("OrderFlowKawa EA v1.00 initialized. Magic: ", InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "OFK_");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Dashboard GUI Functions                                            |
//+------------------------------------------------------------------+
string dash_prefix = "OFK_DASH_";

void CreateLabel(string name, int x, int y, string text, color clr, int size=10, bool bold=false)
  {
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void CreateDashboard()
  {
   ObjectCreate(0, dash_prefix+"BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_XDISTANCE, 270);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_XSIZE, 260);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_YSIZE, 210);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_HIDDEN, true);

   CreateLabel(dash_prefix+"TITLE", 260, 30, "KAWA EA - LIVE EXECUTION", clrGold, 11, true);
   CreateLabel(dash_prefix+"SESS", 250, 60, "[ ] Session Active", clrWhite, 10, true);
   CreateLabel(dash_prefix+"BIAS", 250, 80, "[ ] VWAP Bias", clrWhite, 10, true);
   CreateLabel(dash_prefix+"TRAP", 250, 100, "[ ] Trap Condition", clrWhite, 10, true);
   CreateLabel(dash_prefix+"RECL", 250, 120, "[ ] Reclaim Confirmed", clrWhite, 10, true);
   CreateLabel(dash_prefix+"ABS",  250, 140, "[ ] Absorption Detected", clrWhite, 10, true);
   CreateLabel(dash_prefix+"TRIG", 250, 160, "[ ] LVN Target", clrWhite, 10, true);
   CreateLabel(dash_prefix+"TRADES", 250, 185, "Trades Today: 0/" + IntegerToString(InpMaxTradesPerDay), clrWhite, 10, true);
  }

void UpdateDashboard(string s_sess, color c_sess, string s_bias, color c_bias, string s_trap, color c_trap, 
                     string s_recl, color c_recl, string s_abs, color c_abs, string s_trig, color c_trig)
  {
   ObjectSetString(0, dash_prefix+"SESS", OBJPROP_TEXT, s_sess); ObjectSetInteger(0, dash_prefix+"SESS", OBJPROP_COLOR, c_sess);
   ObjectSetString(0, dash_prefix+"BIAS", OBJPROP_TEXT, s_bias); ObjectSetInteger(0, dash_prefix+"BIAS", OBJPROP_COLOR, c_bias);
   ObjectSetString(0, dash_prefix+"TRAP", OBJPROP_TEXT, s_trap); ObjectSetInteger(0, dash_prefix+"TRAP", OBJPROP_COLOR, c_trap);
   ObjectSetString(0, dash_prefix+"RECL", OBJPROP_TEXT, s_recl); ObjectSetInteger(0, dash_prefix+"RECL", OBJPROP_COLOR, c_recl);
   ObjectSetString(0, dash_prefix+"ABS", OBJPROP_TEXT, s_abs);   ObjectSetInteger(0, dash_prefix+"ABS", OBJPROP_COLOR, c_abs);
   ObjectSetString(0, dash_prefix+"TRIG", OBJPROP_TEXT, s_trig); ObjectSetInteger(0, dash_prefix+"TRIG", OBJPROP_COLOR, c_trig);
   ObjectSetString(0, dash_prefix+"TRADES", OBJPROP_TEXT, "Trades Today: " + IntegerToString(trades_today) + "/" + IntegerToString(InpMaxTradesPerDay));
   ObjectSetInteger(0, dash_prefix+"TRADES", OBJPROP_COLOR, trades_today >= InpMaxTradesPerDay ? clrCrimson : clrWhite);
  }

//+------------------------------------------------------------------+
//| Helper: Draw visual objects on the chart                           |
//+------------------------------------------------------------------+
void DrawTextObj(string name, datetime t, double price, string text, color clr, int size=11, bool bold=true)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
      ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
     }
  }

void DrawArrowObj(string name, datetime t, double price, int arrow_code, color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrow_code);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

void DrawLVNObj(string name, datetime t1, datetime t2, double price, color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

void DrawDayBox(datetime t_start, datetime t_end, double vah, double val, int day_num)
  {
   string name = "OFK_VA_BOX_" + IntegerToString(day_num);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t_start, vah, t_end, val);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t_end); 
     }
     
   string sep_name = "OFK_SEP_" + IntegerToString(day_num);
   if(ObjectFind(0, sep_name) < 0)
     {
      ObjectCreate(0, sep_name, OBJ_VLINE, 0, t_start, 0);
      ObjectSetInteger(0, sep_name, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, sep_name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, sep_name, OBJPROP_BACK, true);
      ObjectSetInteger(0, sep_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, sep_name, OBJPROP_HIDDEN, true);
     }
  }

void DrawIVBBox(string name, datetime t_start, datetime t_end, double ivb_high, double ivb_low)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t_start, ivb_high, t_end, ivb_low);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDarkOrange);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t_end);
     }
  }

void DrawMiddayBox(string name, datetime t_start, datetime t_end)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t_start, 100000, t_end, 0);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

void DrawHLine(string name, double price, color clr, int style=STYLE_SOLID, int width=2)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
     }
  }

//+------------------------------------------------------------------+
//| Check if we have open positions with our magic number              |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Manage breakeven: move SL to entry at 50% of TP distance          |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp    = PositionGetDouble(POSITION_TP);
      double sl    = PositionGetDouble(POSITION_SL);
      double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
      long pos_type = PositionGetInteger(POSITION_TYPE);
      
      if(tp == 0.0) continue;
      
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      
      if(pos_type == POSITION_TYPE_BUY)
        {
         double halfway = entry + ((tp - entry) * 0.5);
         if(current_price >= halfway && sl < entry)
           {
            double new_sl = MathRound(entry / tick_size) * tick_size;
            trade.PositionModify(ticket, new_sl, tp);
            Print("KAWA EA: Moved SL to breakeven for BUY #", ticket);
           }
        }
      else if(pos_type == POSITION_TYPE_SELL)
        {
         double halfway = entry - ((entry - tp) * 0.5);
         if(current_price <= halfway && (sl > entry || sl == 0))
           {
            double new_sl = MathRound(entry / tick_size) * tick_size;
            trade.PositionModify(ticket, new_sl, tp);
            Print("KAWA EA: Moved SL to breakeven for SELL #", ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Get M1 bar data for calculations
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M1, 0, InpMaxHistoryDays * 24 * 60, rates);
   if(copied < 2) return;
   
   // Reverse to chronological order for processing
   ArraySetAsSeries(rates, false);
   
   //--- Process bars to build Volume Profile, VWAP, and State Machine
   // We rebuild on every tick of a new bar for accuracy
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, PERIOD_M1, 0);
   
   if(current_bar_time == last_bar_time)
     {
      // Same bar - just manage existing positions
      ManageBreakeven();
      return;
     }
   last_bar_time = current_bar_time;
   
   //--- Full recalculation on new bar
   int calc_day = -1;
   double calc_vwap_vol = 0;
   double calc_vwap_pv = 0;
   datetime calc_day_start = 0;
   long calc_profile[200000];
   ArrayInitialize(calc_profile, 0);
   
   double calc_poc = 0, calc_vah = 0, calc_val = 0;
   
   int calc_long_state = 0, calc_short_state = 0;
   double calc_long_extreme = 999999, calc_short_extreme = 0;
   double calc_long_lvn = 0, calc_short_lvn = 0;
   
   double calc_ivb_high = 0, calc_ivb_low = 999999;
   bool calc_in_ivb = false;
   
   bool calc_absorption = false;
   
   bool should_buy = false;
   bool should_sell = false;
   double trade_sl = 0, trade_tp = 0;
   string trade_reason = "";
   bool vwap_filtered = false;
   
   for(int i = 0; i < copied; i++)
     {
      datetime t = rates[i].time;
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int day_of_year = dt.day_of_year;
      int current_mins = dt.hour * 60 + dt.min;
      
      // --- New Day Detection ---
      if(day_of_year != calc_day)
        {
         if(calc_day != -1)
           {
            DrawDayBox(calc_day_start, t, calc_vah, calc_val, calc_day);
            
            // Calculate Yesterday's Volume Profile
            long max_v = -1;
            int poc_idx = 0;
            long total_vol = 0;
            for(int b = 0; b < 200000; b++)
              {
               if(calc_profile[b] > max_v)
                 {
                  max_v = calc_profile[b];
                  poc_idx = b;
                 }
               total_vol += calc_profile[b];
              }
            
            if(total_vol > 0)
              {
               long target_va = (long)(total_vol * (InpVA_Percent / 100.0));
               long current_va = calc_profile[poc_idx];
               int up_idx = poc_idx;
               int dn_idx = poc_idx;
               
               while(current_va < target_va && (up_idx < 199999 || dn_idx > 0))
                 {
                  long v_up = (up_idx < 199999) ? calc_profile[up_idx+1] : -1;
                  long v_dn = (dn_idx > 0) ? calc_profile[dn_idx-1] : -1;
                  
                  if(v_up >= v_dn && v_up != -1) { up_idx++; current_va += v_up; }
                  else if(v_dn > v_up && v_dn != -1) { dn_idx--; current_va += v_dn; }
                  else break;
                 }
               
               calc_poc = poc_idx * InpProfileStep;
               calc_vah = up_idx * InpProfileStep;
               calc_val = dn_idx * InpProfileStep;
              }
           }
         
         calc_day = day_of_year;
         calc_day_start = t;
         calc_vwap_vol = 0;
         calc_vwap_pv = 0;
         ArrayInitialize(calc_profile, 0);
         calc_ivb_high = 0;
         calc_ivb_low = 999999;
         calc_in_ivb = false;
         
         // THESIS RULE: Reset state machine on new day
         calc_long_state = 0;
         calc_short_state = 0;
         calc_long_extreme = 999999;
         calc_short_extreme = 0;
         calc_absorption = false;
         
         // Reset daily trade counter
         if(day_of_year != last_trade_day)
           {
            trades_today = 0;
            last_trade_day = day_of_year;
           }
        }
      
      // --- VWAP Calculation ---
      double typ_price = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      calc_vwap_vol += (double)rates[i].tick_volume;
      calc_vwap_pv += (double)rates[i].tick_volume * typ_price;
      
      double bar_vwap = 0;
      if(calc_vwap_vol > 0) bar_vwap = calc_vwap_pv / calc_vwap_vol;
      
      // --- Volume Profile Accumulation ---
      int idx_high = (int)MathFloor(rates[i].high / InpProfileStep);
      int idx_low = (int)MathFloor(rates[i].low / InpProfileStep);
      if(idx_high >= 200000) idx_high = 199999;
      if(idx_low < 0) idx_low = 0;
      
      int span = idx_high - idx_low + 1;
      long vol_per_bin = rates[i].tick_volume / span;
      long remainder = rates[i].tick_volume % span;
      
      for(int b = idx_low; b <= idx_high; b++)
         calc_profile[b] += vol_per_bin;
      calc_profile[idx_low + (span/2)] += remainder;
      
      // --- IVB Tracking ---
      if(current_mins >= ivb_start_mins && current_mins < ivb_end_mins)
        {
         calc_in_ivb = true;
         if(rates[i].high > calc_ivb_high) calc_ivb_high = rates[i].high;
         if(rates[i].low < calc_ivb_low) calc_ivb_low = rates[i].low;
        }
       else if(calc_in_ivb && current_mins >= ivb_end_mins)
         {
          calc_in_ivb = false;
         }
       
       // --- Draw IVB Box ---
       if(calc_ivb_high > 0 && current_mins >= ivb_end_mins)
         {
          DrawIVBBox("OFK_IVB_"+IntegerToString(day_of_year), calc_day_start + (ivb_start_mins*60), t + PeriodSeconds(PERIOD_M1), calc_ivb_high, calc_ivb_low);
         }
       
       // --- Draw Midday Box ---
       if(current_mins >= mid_start_mins && current_mins < mid_end_mins)
         {
          DrawMiddayBox("OFK_MID_"+IntegerToString(day_of_year), calc_day_start + (mid_start_mins*60), t + PeriodSeconds(PERIOD_M1));
         }
       
       // --- Absorption Detection ---
       double sum_vol = 0;
       int vol_count = 0;
       for(int k = 0; k < 50; k++)
         {
          if(i - k >= 0)
            {
             sum_vol += (double)rates[i-k].tick_volume;
             vol_count++;
            }
         }
       double avg_vol = vol_count > 0 ? (sum_vol / vol_count) : 0;
       
       double sum_tr = 0;
       int tr_count = 0;
       for(int k = 0; k < 14; k++)
         {
          if(i - k > 0)
            {
             double h = rates[i-k].high;
             double l = rates[i-k].low;
             double pc = rates[i-k-1].close;
             double tr = MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
             sum_tr += tr;
             tr_count++;
            }
         }
       double atr = tr_count > 0 ? (sum_tr / tr_count) : 0;
       
       double candle_range = rates[i].high - rates[i].low;
       bool is_absorbing = false;
       if(avg_vol > 0 && atr > 0)
         {
          if((double)rates[i].tick_volume > (avg_vol * 2.0) && candle_range < (atr * 0.3))
            {
             is_absorbing = true;
             calc_absorption = true;
             DrawArrowObj("OFK_ABS_"+IntegerToString(i), t, rates[i].low - 15, 119, clrMagenta);
            }
         }
      
      // --- State Machine (Thesis: Trap -> Reclaim -> LVN Pullback) ---
      if(calc_poc > 0)
        {
         // Reset if price returns to POC
         if(rates[i].close >= calc_poc)
           {
            calc_long_state = 0;
           }
         if(rates[i].close <= calc_poc)
           {
            calc_short_state = 0;
           }
         
         // ===== LONG SETUP =====
         if(calc_long_state == 0)
           {
            if(rates[i].close < calc_val)
              {
               calc_long_state = 1;  // TRAP detected
               calc_long_extreme = rates[i].close;
               DrawArrowObj("OFK_ARR_LTRAP_"+IntegerToString(i), t, rates[i].close - 10, 241, clrGreen);
               DrawTextObj("OFK_LBL_LTRAP_"+IntegerToString(i), t, rates[i].close - 25, " TRAP", clrGreen);
              }
           }
         else if(calc_long_state == 1)
           {
            if(rates[i].close < calc_long_extreme) calc_long_extreme = rates[i].close;
            if(rates[i].close > calc_val)
              {
               calc_long_state = 2;  // RECLAIM confirmed
               // THESIS: 50% structural pullback for LVN
               calc_long_lvn = calc_long_extreme + ((rates[i].close - calc_long_extreme) / 2.0);
               DrawArrowObj("OFK_ARR_LREC_"+IntegerToString(i), t, rates[i].close + 10, 242, clrGreen);
               DrawTextObj("OFK_LBL_LREC_"+IntegerToString(i), t, rates[i].close + 25, " RECLAIM", clrGreen);
               DrawLVNObj("OFK_LVN_L_"+IntegerToString(i), t, t+(3600*4), calc_long_lvn, clrGreen);
              }
           }
         else if(calc_long_state == 2)
           {
            if(rates[i].close <= calc_long_lvn + 5)
              {
               // THESIS: VWAP Governor - only buy if price > VWAP
               bool vwap_ok = !InpUseVWAPFilter || (bar_vwap > 0 && rates[i].close > bar_vwap);
               bool abs_ok = !InpUseAbsorptionFilter || calc_absorption;
               
               color trigger_clr = clrGreen;
               if(!vwap_ok) trigger_clr = clrDimGray;
               
               DrawArrowObj("OFK_ARR_L_"+IntegerToString(i), t, rates[i].close - 5, 233, trigger_clr);
               DrawTextObj("OFK_LBL_LTRIG_"+IntegerToString(i), t, rates[i].close - 15, " BUY", trigger_clr);
               
               if(i == copied - 1 && vwap_ok && abs_ok)
                 {
                  should_buy = true;
                  trade_sl = calc_long_extreme - InpSL_Buffer; // SL beyond trap extreme
                  trade_tp = calc_poc;                          // TP = POC per thesis
                  trade_reason = "Reclaim LVN Pullback LONG";
                 }
               
               calc_long_state = 0;
              }
           }
         
         // ===== SHORT SETUP =====
         if(calc_short_state == 0)
           {
            if(rates[i].close > calc_vah)
              {
               calc_short_state = 1;  // TRAP detected
               calc_short_extreme = rates[i].close;
               DrawArrowObj("OFK_ARR_STRAP_"+IntegerToString(i), t, rates[i].close + 10, 242, clrCrimson);
               DrawTextObj("OFK_LBL_STRAP_"+IntegerToString(i), t, rates[i].close + 25, " TRAP", clrCrimson);
              }
           }
         else if(calc_short_state == 1)
           {
            if(rates[i].close > calc_short_extreme) calc_short_extreme = rates[i].close;
            if(rates[i].close < calc_vah)
              {
               calc_short_state = 2;  // RECLAIM confirmed
               // THESIS: 50% structural pullback for LVN
               calc_short_lvn = calc_short_extreme - ((calc_short_extreme - rates[i].close) / 2.0);
               DrawArrowObj("OFK_ARR_SREC_"+IntegerToString(i), t, rates[i].close - 10, 241, clrCrimson);
               DrawTextObj("OFK_LBL_SREC_"+IntegerToString(i), t, rates[i].close - 25, " RECLAIM", clrCrimson);
               DrawLVNObj("OFK_LVN_S_"+IntegerToString(i), t, t+(3600*4), calc_short_lvn, clrCrimson);
              }
           }
         else if(calc_short_state == 2)
           {
            if(rates[i].close >= calc_short_lvn - 5)
              {
               // THESIS: VWAP Governor - only sell if price < VWAP
               bool vwap_ok = !InpUseVWAPFilter || (bar_vwap > 0 && rates[i].close < bar_vwap);
               bool abs_ok = !InpUseAbsorptionFilter || calc_absorption;
               
               color trigger_clr = clrCrimson;
               if(!vwap_ok) trigger_clr = clrDimGray;
               
               DrawArrowObj("OFK_ARR_S_"+IntegerToString(i), t, rates[i].close + 5, 234, trigger_clr);
               DrawTextObj("OFK_LBL_STRIG_"+IntegerToString(i), t, rates[i].close + 15, " SELL", trigger_clr);
               
               if(i == copied - 1 && vwap_ok && abs_ok)
                 {
                  should_sell = true;
                  trade_sl = calc_short_extreme + InpSL_Buffer; // SL beyond trap extreme
                  trade_tp = calc_poc;                          // TP = POC per thesis
                  trade_reason = "Reclaim LVN Pullback SHORT";
                 }
               
               calc_short_state = 0;
              }
           }
        }
      
      // Store final state for dashboard
      if(i == copied - 1)
        {
         current_poc = calc_poc;
         current_vah = calc_vah;
         current_val = calc_val;
         current_vwap = bar_vwap;
         long_state = calc_long_state;
         short_state = calc_short_state;
         long_lvn = calc_long_lvn;
         short_lvn = calc_short_lvn;
         absorption_detected = is_absorbing;
         
         // Draw live box
         if(calc_poc > 0)
            DrawDayBox(calc_day_start, t + PeriodSeconds(PERIOD_M1), calc_vah, calc_val, calc_day);
         
         // Draw continuous horizontal lines (EA equivalent of indicator buffers)
         DrawHLine("OFK_LINE_POC", calc_poc, clrGold, STYLE_SOLID, 2);
         DrawHLine("OFK_LINE_VAH", calc_vah, clrDeepSkyBlue, STYLE_SOLID, 1);
         DrawHLine("OFK_LINE_VAL", calc_val, clrDeepSkyBlue, STYLE_SOLID, 1);
         DrawHLine("OFK_LINE_VWAP", bar_vwap, clrMediumOrchid, STYLE_DASH, 2);
         
         // Draw line labels
         DrawTextObj("OFK_LBL_POC_NAME", t, calc_poc, " POC", clrGold, 11, true);
         DrawTextObj("OFK_LBL_VAH_NAME", t, calc_vah, " VAH", clrDeepSkyBlue, 11, true);
         DrawTextObj("OFK_LBL_VAL_NAME", t, calc_val, " VAL", clrDeepSkyBlue, 11, true);
         DrawTextObj("OFK_LBL_VWAP_NAME", t, bar_vwap, " VWAP", clrMediumOrchid, 11, true);
         
         // --- Update Dashboard ---
         int current_mins_now = dt.hour * 60 + dt.min;
         
         string s_sess = "[X] RTH Session Active"; color c_sess = clrLimeGreen;
         if(calc_in_ivb) { s_sess = "[ ] IVB Formation (Blocked)"; c_sess = clrDarkOrange; }
         else if(current_mins_now >= mid_start_mins && current_mins_now < mid_end_mins) { s_sess = "[ ] Midday Void (Blocked)"; c_sess = clrCrimson; }
         
         string s_bias = (typ_price > bar_vwap) ? "[X] VWAP Bias: BULLISH" : "[X] VWAP Bias: BEARISH";
         color c_bias = (typ_price > bar_vwap) ? clrLimeGreen : clrCrimson;
         
         string s_trap = "[ ] Trap Condition"; color c_trap = clrLightGray;
         string s_recl = "[ ] Reclaim Confirmed"; color c_recl = clrLightGray;
         string s_trig = "[ ] LVN Target"; color c_trig = clrLightGray;
         
         if(calc_long_state > 0) { s_trap = "[X] TRAP: Below VAL"; c_trap = clrLimeGreen; }
         else if(calc_short_state > 0) { s_trap = "[X] TRAP: Above VAH"; c_trap = clrCrimson; }
         
         if(calc_long_state > 1) { s_recl = "[X] RECLAIM: Confirmed"; c_recl = clrLimeGreen; s_trig = "[ ] LVN Target: " + DoubleToString(calc_long_lvn, 2); c_trig = clrGold; }
         else if(calc_short_state > 1) { s_recl = "[X] RECLAIM: Confirmed"; c_recl = clrCrimson; s_trig = "[ ] LVN Target: " + DoubleToString(calc_short_lvn, 2); c_trig = clrGold; }
         
         string s_abs = calc_absorption ? "[X] Absorption Detected!" : "[ ] Absorption Flow";
         color c_abs = calc_absorption ? clrMagenta : clrLightGray;
         
         UpdateDashboard(s_sess, c_sess, s_bias, c_bias, s_trap, c_trap, s_recl, c_recl, s_abs, c_abs, s_trig, c_trig);
        }
     }
   
   //--- EXECUTION LOGIC (only fires on live bar)
   MqlDateTime now_dt;
   TimeCurrent();
   TimeToStruct(TimeCurrent(), now_dt);
   int now_mins = now_dt.hour * 60 + now_dt.min;
   
   // THESIS: Time filters - no trading during IVB or Midday
   bool time_ok = (now_mins > ivb_end_mins) && !(now_mins >= mid_start_mins && now_mins < mid_end_mins);
   
   // Max trades per day guard
   bool trades_ok = trades_today < InpMaxTradesPerDay;
   
   // No existing position guard
   bool no_position = CountOpenPositions() == 0;
   
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(should_buy)
     {
      if(!time_ok) Print("KAWA EA: BUY Blocked by Time Filter. Current Mins: ", now_mins, " | IVB End: ", ivb_end_mins);
      else if(!trades_ok) Print("KAWA EA: BUY Blocked by Max Trades Per Day (", trades_today, ")");
      else if(!no_position) Print("KAWA EA: BUY Blocked. Position already open.");
      else
        {
         double sl_rounded = MathRound(trade_sl / tick_size) * tick_size;
         double tp_rounded = MathRound(trade_tp / tick_size) * tick_size;
         if(trade.Buy(InpLotSize, _Symbol, 0, sl_rounded, tp_rounded, trade_reason))
           {
            trades_today++;
            Print("KAWA EA: BUY executed! Reason: ", trade_reason, " SL: ", sl_rounded, " TP: ", tp_rounded);
            Alert("KAWA EA: BUY @ ", SymbolInfoDouble(_Symbol, SYMBOL_ASK), " | ", trade_reason);
           }
         else
           {
            Print("KAWA EA: BUY FAILED. Error: ", GetLastError());
           }
        }
     }
   
   if(should_sell)
     {
      if(!time_ok) Print("KAWA EA: SELL Blocked by Time Filter. Current Mins: ", now_mins, " | IVB End: ", ivb_end_mins);
      else if(!trades_ok) Print("KAWA EA: SELL Blocked by Max Trades Per Day (", trades_today, ")");
      else if(!no_position) Print("KAWA EA: SELL Blocked. Position already open.");
      else
        {
         double sl_rounded = MathRound(trade_sl / tick_size) * tick_size;
         double tp_rounded = MathRound(trade_tp / tick_size) * tick_size;
         if(trade.Sell(InpLotSize, _Symbol, 0, sl_rounded, tp_rounded, trade_reason))
           {
            trades_today++;
            Print("KAWA EA: SELL executed! Reason: ", trade_reason, " SL: ", sl_rounded, " TP: ", tp_rounded);
            Alert("KAWA EA: SELL @ ", SymbolInfoDouble(_Symbol, SYMBOL_BID), " | ", trade_reason);
           }
         else
           {
            Print("KAWA EA: SELL FAILED! Error: ", GetLastError());
           }
        }
     }
   
   // Always manage breakeven on existing positions
   ManageBreakeven();
   
   ChartRedraw();
  }
//+------------------------------------------------------------------+
