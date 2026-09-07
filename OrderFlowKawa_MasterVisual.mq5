//+------------------------------------------------------------------+
//|                                   OrderFlowKawa_MasterVisual.mq5 |
//|                                            Copyright 2026, KAWA  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, KAWA"
#property link      "https://www.mql5.com"
#property version   "3.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

input int    InpMaxHistoryDays = 30;     // Max Historical Days
input double InpProfileStep    = 1.0;    // Volume Profile Step (Points)
input double InpVA_Percent     = 70.0;   // Value Area Percentage

input string InpIVB_Start_Time    = "16:30"; // IVB Start (Broker Time, 09:30 EST)
input string InpIVB_End_Time      = "17:00"; // IVB End (Broker Time, 10:00 EST)
input string InpMidday_Start_Time = "19:00"; // Midday Void Start (Broker Time, 12:00 EST)
input string InpMidday_End_Time   = "20:30"; // Midday Void End (Broker Time, 13:30 EST)

//--- plot POC
#property indicator_label1  "Prev POC"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- plot VAH
#property indicator_label2  "Prev VAH"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDeepSkyBlue
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

//--- plot VAL
#property indicator_label3  "Prev VAL"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDeepSkyBlue
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

//--- plot VWAP
#property indicator_label4  "Daily VWAP"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMediumOrchid
#property indicator_style4  STYLE_DASH
#property indicator_width4  2

//--- indicator buffers
double         POC_Buffer[];
double         VAH_Buffer[];
double         VAL_Buffer[];
double         VWAP_Buffer[];

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
datetime current_day_start = 0;

long current_day_profile[200000];

// Time Parsing
int ivb_start_mins, ivb_end_mins, mid_start_mins, mid_end_mins;

// Session Tracking
int last_ivb_day = -1;
int last_mid_day = -1;
double current_ivb_high = 0.0;
double current_ivb_low = 999999.0;
bool is_in_ivb = false;

// Debugging
int csv_handle = -1;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, POC_Buffer, INDICATOR_DATA);
   SetIndexBuffer(1, VAH_Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, VAL_Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, VWAP_Buffer, INDICATOR_DATA);
   
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);
   
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
   
   // Init CSV Debugger
   csv_handle = FileOpen("OFK_Debug_MNQU26.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(csv_handle != INVALID_HANDLE)
     {
      FileWrite(csv_handle, "Time", "Close", "VWAP", "POC", "VAH", "VAL", "Long_State", "Short_State", "LVN_Price", "Event_Log");
     }
   
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "OFK_VA_BOX_");
   ObjectsDeleteAll(0, "OFK_SEP_");
   ObjectsDeleteAll(0, "OFK_LBL_");
   ObjectsDeleteAll(0, "OFK_ARR_");
   ObjectsDeleteAll(0, "OFK_LVN_");
   ObjectsDeleteAll(0, "OFK_IVB_");
   ObjectsDeleteAll(0, "OFK_MID_");
   ObjectsDeleteAll(0, "OFK_ABS_");
   ObjectsDeleteAll(0, "OFK_DASH_");
   ChartRedraw();
   
   if(csv_handle != INVALID_HANDLE) FileClose(csv_handle);
  }

//+------------------------------------------------------------------+
//| Dashboard GUI Functions                                          |
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
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_YSIZE, 190);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_COLOR, clrBlack); // Border
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_BACK, false); // Keep on top
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, dash_prefix+"BG", OBJPROP_HIDDEN, true);

   CreateLabel(dash_prefix+"TITLE", 260, 30, "ORDERFLOW THESIS CHECKLIST", clrWhite, 11, true);
   CreateLabel(dash_prefix+"SESS", 250, 60, "[ ] Session Active", clrWhite, 10, true);
   CreateLabel(dash_prefix+"BIAS", 250, 80, "[ ] VWAP Bias", clrWhite, 10, true);
   CreateLabel(dash_prefix+"TRAP", 250, 100, "[ ] Trap Condition", clrWhite, 10, true);
   CreateLabel(dash_prefix+"RECL", 250, 120, "[ ] Reclaim Confirmed", clrWhite, 10, true);
   CreateLabel(dash_prefix+"ABS",  250, 140, "[ ] Absorption Detected", clrWhite, 10, true);
   CreateLabel(dash_prefix+"TRIG", 250, 160, "[ ] LVN Target", clrWhite, 10, true);
  }

void UpdateDashboard(string s_sess, color c_sess, string s_bias, color c_bias, string s_trap, color c_trap, string s_recl, color c_recl, string s_abs, color c_abs, string s_trig, color c_trig)
  {
   ObjectSetString(0, dash_prefix+"SESS", OBJPROP_TEXT, s_sess); ObjectSetInteger(0, dash_prefix+"SESS", OBJPROP_COLOR, c_sess);
   ObjectSetString(0, dash_prefix+"BIAS", OBJPROP_TEXT, s_bias); ObjectSetInteger(0, dash_prefix+"BIAS", OBJPROP_COLOR, c_bias);
   ObjectSetString(0, dash_prefix+"TRAP", OBJPROP_TEXT, s_trap); ObjectSetInteger(0, dash_prefix+"TRAP", OBJPROP_COLOR, c_trap);
   ObjectSetString(0, dash_prefix+"RECL", OBJPROP_TEXT, s_recl); ObjectSetInteger(0, dash_prefix+"RECL", OBJPROP_COLOR, c_recl);
   ObjectSetString(0, dash_prefix+"ABS", OBJPROP_TEXT, s_abs);   ObjectSetInteger(0, dash_prefix+"ABS", OBJPROP_COLOR, c_abs);
   ObjectSetString(0, dash_prefix+"TRIG", OBJPROP_TEXT, s_trig); ObjectSetInteger(0, dash_prefix+"TRIG", OBJPROP_COLOR, c_trig);
  }

//+------------------------------------------------------------------+
//| Helper functions for drawing State Machine Objects               |
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
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
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

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2) return(0);
   
   int limit = prev_calculated - 1;
   if(limit < 0) limit = 0;
   
   datetime current_time_last = time[rates_total - 1];
   datetime start_history_time = current_time_last - (InpMaxHistoryDays * 24 * 60 * 60);
   
   if (prev_calculated == 0)
     {
      long_state = 0;
      short_state = 0;
      long_extreme = 999999;
      short_extreme = 0;
      long_lvn = 0;
      short_lvn = 0;
      
      ObjectsDeleteAll(0, "OFK_LBL_");
      ObjectsDeleteAll(0, "OFK_ARR_");
      ObjectsDeleteAll(0, "OFK_LVN_");
      ObjectsDeleteAll(0, "OFK_IVB_");
      ObjectsDeleteAll(0, "OFK_MID_");
      ObjectsDeleteAll(0, "OFK_ABS_");
      
      for(int i = 0; i < rates_total; i++)
        {
         if(time[i] >= start_history_time)
           {
            limit = i;
            break;
           }
        }
     }
     
   for(int i = limit; i < rates_total; i++)
     {
      datetime t = time[i];
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int day_of_year = dt.day_of_year;
      int current_mins = dt.hour * 60 + dt.min;
      
      // New Day Detected
      if(day_of_year != last_calculated_day)
        {
         if(last_calculated_day != -1)
           {
            DrawDayBox(current_day_start, t, current_vah, current_val, last_calculated_day);
            
            // Calculate Yesterday's Volume Profile
            long max_v = -1;
            int poc_idx = 0;
            long total_vol = 0;
            for(int b = 0; b < 200000; b++) {
                if(current_day_profile[b] > max_v) {
                    max_v = current_day_profile[b];
                    poc_idx = b;
                }
                total_vol += current_day_profile[b];
            }
            
            // Expand for VAH/VAL
            if (total_vol > 0)
              {
               long target_va = (long)(total_vol * (InpVA_Percent / 100.0));
               long current_va = current_day_profile[poc_idx];
               int up_idx = poc_idx;
               int dn_idx = poc_idx;
               
               while(current_va < target_va && (up_idx < 199999 || dn_idx > 0)) {
                   long v_up = (up_idx < 199999) ? current_day_profile[up_idx+1] : -1;
                   long v_dn = (dn_idx > 0) ? current_day_profile[dn_idx-1] : -1;
                   
                   if(v_up >= v_dn && v_up != -1) {
                       up_idx++;
                       current_va += v_up;
                   } else if(v_dn > v_up && v_dn != -1) {
                       dn_idx--;
                       current_va += v_dn;
                   } else {
                       break; 
                   }
               }
               
               current_poc = poc_idx * InpProfileStep;
               current_vah = up_idx * InpProfileStep;
               current_val = dn_idx * InpProfileStep;
              }
           }
           
         last_calculated_day = day_of_year;
         current_day_start = t;
         
         current_vwap_vol = 0;
         current_vwap_pv = 0;
         ArrayInitialize(current_day_profile, 0);
         
         // Reset daily session vars
         current_ivb_high = 0.0;
         current_ivb_low = 999999.0;
         is_in_ivb = false;
         
         long_state = 0;
         short_state = 0;
         
         if(current_poc > 0)
           {
            DrawDayBox(t, t + PeriodSeconds(), current_vah, current_val, day_of_year);
           }
        }
        
      // 1. VWAP Calculation
      double typ_price = (high[i] + low[i] + close[i]) / 3.0;
      current_vwap_vol += (double)tick_volume[i];
      current_vwap_pv += (double)tick_volume[i] * typ_price;
      
      if(current_vwap_vol > 0) VWAP_Buffer[i] = current_vwap_pv / current_vwap_vol;
      else VWAP_Buffer[i] = 0.0;
        
      // 2. Add Volume to Profile
      int idx_high = (int)MathFloor(high[i] / InpProfileStep);
      int idx_low = (int)MathFloor(low[i] / InpProfileStep);
      if(idx_high >= 200000) idx_high = 199999;
      if(idx_low < 0) idx_low = 0;
      
      int span = idx_high - idx_low + 1;
      long vol_per_bin = tick_volume[i] / span;
      long remainder = tick_volume[i] % span;
      
      for(int b = idx_low; b <= idx_high; b++) {
          current_day_profile[b] += vol_per_bin;
      }
      current_day_profile[idx_low + (span/2)] += remainder;
      
      POC_Buffer[i] = current_poc;
      VAH_Buffer[i] = current_vah;
      VAL_Buffer[i] = current_val;
      
      // Update Live Box
      if(i == rates_total - 1 && current_poc > 0)
        {
         DrawDayBox(current_day_start, t + PeriodSeconds(), current_vah, current_val, last_calculated_day);
        }
        
      // 3. Time Windows (IVB & Midday)
      if(current_mins >= ivb_start_mins && current_mins < ivb_end_mins)
        {
         is_in_ivb = true;
         if(high[i] > current_ivb_high) current_ivb_high = high[i];
         if(low[i] < current_ivb_low) current_ivb_low = low[i];
        }
      else if(is_in_ivb && current_mins >= ivb_end_mins)
        {
         is_in_ivb = false;
        }
        
      if(current_ivb_high > 0 && current_mins >= ivb_end_mins)
        {
         datetime ivb_end_t = current_day_start + (ivb_end_mins * 60);
         DrawIVBBox("OFK_IVB_"+IntegerToString(day_of_year), current_day_start + (ivb_start_mins*60), ivb_end_t, current_ivb_high, current_ivb_low);
        }
        
      if(current_mins >= mid_start_mins && current_mins < mid_end_mins)
        {
         datetime mid_end_t = current_day_start + (mid_end_mins * 60);
         DrawMiddayBox("OFK_MID_"+IntegerToString(day_of_year), current_day_start + (mid_start_mins*60), mid_end_t);
        }
        
      // 4. Volumetric Absorption Detection
      bool is_absorbing = false;
      double sum_vol = 0;
      int vol_count = 0;
      for(int k=0; k<50; k++) {
         if(i-k >= 0) {
            sum_vol += (double)tick_volume[i-k];
            vol_count++;
         }
      }
      double avg_vol = vol_count > 0 ? (sum_vol / vol_count) : 0;
      
      double sum_tr = 0;
      int tr_count = 0;
      for(int k=0; k<14; k++) {
         if(i-k > 0) {
            double h = high[i-k];
            double l = low[i-k];
            double pc = close[i-k-1];
            double tr = MathMax(h-l, MathMax(MathAbs(h-pc), MathAbs(l-pc)));
            sum_tr += tr;
            tr_count++;
         }
      }
      double atr = tr_count > 0 ? (sum_tr / tr_count) : 0;
      
      double candle_range = high[i] - low[i];
      if(avg_vol > 0 && atr > 0)
        {
         if((double)tick_volume[i] > (avg_vol * 2.0) && candle_range < (atr * 0.3))
           {
            is_absorbing = true;
            DrawArrowObj("OFK_ABS_"+IntegerToString(i), t, low[i] - 15, 119, clrMagenta); // 119 is a diamond
           }
        }
        
      // 5. Strategy State Machine Logic
      string event_log = "";
      if(current_poc > 0)
        {
         if(low[i] <= current_poc && high[i] >= current_poc)
           {
            if(long_state > 0 || short_state > 0) event_log = "Touched POC - Resetting State";
            long_state = 0;
            short_state = 0;
           }
           
         // LONG SETUP
         if(long_state == 0)
           {
            if(close[i] < current_val)
              {
               long_state = 1;
               long_extreme = low[i];
               event_log = "LONG TRAP Triggered";
               DrawArrowObj("OFK_ARR_LTRAP_"+IntegerToString(i), t, low[i] - 10, 241, clrGreen);
               DrawTextObj("OFK_LBL_LTRAP_"+IntegerToString(i), t, low[i] - 25, " TRAP", clrGreen);
              }
           }
         else if(long_state == 1)
           {
            if(low[i] < long_extreme) long_extreme = low[i];
            if(close[i] > current_val)
              {
               long_state = 2;
               long_lvn = long_extreme + ((close[i] - long_extreme) / 2.0);
               event_log = "LONG RECLAIM Confirmed";
               DrawArrowObj("OFK_ARR_LREC_"+IntegerToString(i), t, high[i] + 10, 242, clrGreen);
               DrawTextObj("OFK_LBL_LREC_"+IntegerToString(i), t, high[i] + 25, " RECLAIM", clrGreen);
               DrawLVNObj("OFK_LVN_L_"+IntegerToString(i), t, t+(3600*4), long_lvn, clrGreen);
              }
           }
         else if(long_state == 2)
           {
            if(high[i] >= current_poc)
              {
               long_state = 0;
              }
            else if(low[i] <= long_lvn + 5)
              {
               color trigger_clr = clrGreen;
               string label_txt = " BUY";
               if(VWAP_Buffer[i] > 0 && low[i] < VWAP_Buffer[i])
                 {
                  trigger_clr = clrDimGray;
                  label_txt = " BUY [BLOCKED BY VWAP]";
                  event_log = "BUY Triggered but BLOCKED by VWAP filter";
                 }
               else
                 {
                  event_log = "BUY Executed at LVN";
                 }
               
               DrawArrowObj("OFK_ARR_L_"+IntegerToString(i), t, low[i] - 5, 233, trigger_clr); 
               DrawTextObj("OFK_LBL_LTRIG_"+IntegerToString(i), t, low[i] - 15, label_txt, trigger_clr);
               long_state = 0;
              }
           }
           
         // SHORT SETUP
         if(short_state == 0)
           {
            if(close[i] > current_vah)
              {
               short_state = 1;
               short_extreme = high[i];
               event_log = "SHORT TRAP Triggered";
               DrawArrowObj("OFK_ARR_STRAP_"+IntegerToString(i), t, high[i] + 10, 242, clrCrimson);
               DrawTextObj("OFK_LBL_STRAP_"+IntegerToString(i), t, high[i] + 25, " TRAP", clrCrimson);
              }
           }
         else if(short_state == 1)
           {
            if(high[i] > short_extreme) short_extreme = high[i];
            if(close[i] < current_vah)
              {
               short_state = 2;
               short_lvn = short_extreme - ((short_extreme - close[i]) / 2.0);
               event_log = "SHORT RECLAIM Confirmed";
               DrawArrowObj("OFK_ARR_SREC_"+IntegerToString(i), t, low[i] - 10, 241, clrCrimson);
               DrawTextObj("OFK_LBL_SREC_"+IntegerToString(i), t, low[i] - 25, " RECLAIM", clrCrimson);
               DrawLVNObj("OFK_LVN_S_"+IntegerToString(i), t, t+(3600*4), short_lvn, clrCrimson);
              }
           }
         else if(short_state == 2)
           {
            if(low[i] <= current_poc)
              {
               short_state = 0;
              }
            else if(high[i] >= short_lvn - 5)
              {
               color trigger_clr = clrCrimson;
               string label_txt = " SELL";
               if(VWAP_Buffer[i] > 0 && high[i] > VWAP_Buffer[i])
                 {
                  trigger_clr = clrDimGray;
                  label_txt = " SELL [BLOCKED BY VWAP]";
                  event_log = "SELL Triggered but BLOCKED by VWAP filter";
                 }
               else
                 {
                  event_log = "SELL Executed at LVN";
                 }
               
               DrawArrowObj("OFK_ARR_S_"+IntegerToString(i), t, high[i] + 5, 234, trigger_clr); 
               DrawTextObj("OFK_LBL_STRIG_"+IntegerToString(i), t, high[i] + 15, label_txt, trigger_clr);
               short_state = 0;
              }
           }
           
         // Dump CSV Debug Row
         if(csv_handle != INVALID_HANDLE)
           {
            double log_lvn = (long_state > 0) ? long_lvn : short_lvn;
            FileWrite(csv_handle, TimeToString(t, TIME_DATE|TIME_MINUTES), DoubleToString(close[i], 2), DoubleToString(VWAP_Buffer[i], 2), DoubleToString(current_poc, 2), DoubleToString(current_vah, 2), DoubleToString(current_val, 2), IntegerToString(long_state), IntegerToString(short_state), DoubleToString(log_lvn, 2), event_log);
           }
        }
        
      // 6. Update Live Cartel Box (Dashboard)
      if(i == rates_total - 1)
        {
         string s_sess = "[X] RTH Session Active"; color c_sess = clrLimeGreen;
         if(is_in_ivb) { s_sess = "[ ] IVB Formation (Blocked)"; c_sess = clrDarkOrange; }
         else if(current_mins >= mid_start_mins && current_mins < mid_end_mins) { s_sess = "[ ] Midday Void (Blocked)"; c_sess = clrCrimson; }
         
         string s_bias = (typ_price > VWAP_Buffer[i]) ? "[X] VWAP Bias: BULLISH" : "[X] VWAP Bias: BEARISH";
         color c_bias = (typ_price > VWAP_Buffer[i]) ? clrLimeGreen : clrCrimson;
         
         string s_trap = "[ ] Trap Condition"; color c_trap = clrLightGray;
         string s_recl = "[ ] Reclaim Confirmed"; color c_recl = clrLightGray;
         string s_trig = "[ ] LVN Target"; color c_trig = clrLightGray;
         
         if(long_state > 0) { s_trap = "[X] TRAP: Below VAL"; c_trap = clrLimeGreen; }
         else if (short_state > 0) { s_trap = "[X] TRAP: Above VAH"; c_trap = clrCrimson; }
         
         if(long_state > 1) { s_recl = "[X] RECLAIM: Confirmed"; c_recl = clrLimeGreen; s_trig = "[ ] LVN Target: " + DoubleToString(long_lvn, 2); c_trig = clrGold; }
         else if (short_state > 1) { s_recl = "[X] RECLAIM: Confirmed"; c_recl = clrCrimson; s_trig = "[ ] LVN Target: " + DoubleToString(short_lvn, 2); c_trig = clrGold; }
         
         string s_abs = is_absorbing ? "[X] Absorption Detected!" : "[ ] Absorption Flow";
         color c_abs = is_absorbing ? clrMagenta : clrLightGray;
         
         UpdateDashboard(s_sess, c_sess, s_bias, c_bias, s_trap, c_trap, s_recl, c_recl, s_abs, c_abs, s_trig, c_trig);
         
         // 7. Update Explicit Line Names on the live bar
         DrawTextObj("OFK_LBL_POC_NAME", t, current_poc, " POC", clrGold, 11, true);
         DrawTextObj("OFK_LBL_VAH_NAME", t, current_vah, " VAH", clrDeepSkyBlue, 11, true);
         DrawTextObj("OFK_LBL_VAL_NAME", t, current_val, " VAL", clrDeepSkyBlue, 11, true);
         DrawTextObj("OFK_LBL_VWAP_NAME", t, VWAP_Buffer[i], " VWAP", clrMediumOrchid, 11, true);
        }
     }
     
   return(rates_total);
  }
//+------------------------------------------------------------------+
