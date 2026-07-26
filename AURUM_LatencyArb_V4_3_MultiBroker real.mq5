//+------------------------------------------------------------------+
//|                        AURUM_LatencyArb_V4_3_MultiBroker.mq5     |
//|                                                 AURUM TECH / Por |
//|                                                                  |
//|  Multi-broker A consensus latency arbitrage EA.                  |
//|                                                                  |
//|  Architecture:                                                   |
//|    A1 = Watcher on broker 1 (e.g. Tickmill)                      |
//|         → writes aurum_a1_hb.csv                                 |
//|    A2 = Watcher on broker 2 (e.g. Pepperstone)                   |
//|         → writes aurum_a2_hb.csv                                 |
//|    A3 = Watcher on broker 3 (e.g. IC Markets)                    |
//|         → writes aurum_a3_hb.csv                                 |
//|    B  = Executor on broker 4 (e.g. GOC Prime)                    |
//|         → reads all 3 heartbeats                                 |
//|         → calculates delta_i = A_i.mid - B.mid for each A        |
//|         → checks consensus BEFORE opening any order              |
//|                                                                  |
//|  Consensus rules (all must pass to fire signal):                 |
//|    1. Sign consensus — all deltas same direction                 |
//|    2. Count consensus — >= InpRequireConsensus deltas over       |
//|       InpConsensusThreshold                                      |
//|    3. Sanity check — max spread between deltas < InpMaxAgreeSpread|
//|    4. All A heartbeats fresh (< InpMaxHeartbeatAgeMs)            |
//|    5. Median delta magnitude >= InpConsensusThreshold            |
//|                                                                  |
//|  Signal reasoning is done at B (executor) side — no signal.csv.  |
//|  A brokers just publish price via heartbeat files.               |
//|                                                                  |
//|  Inherits V4.2 features:                                         |
//|    - Delayed TP (arm after breakeven)                            |
//|    - Spread guard (skip if spread > MaxSpread)                   |
//|    - Actual fill price for SL/TP (ResultPrice)                   |
//|    - Optional ADX filter (per broker feed)                       |
//|    - Optional Volume filter                                      |
//|                                                                  |
//|  Uses [Common]\Files\ — all 4 MT5 terminals must run on same VPS |
//+------------------------------------------------------------------+
#property copyright "AURUM TECH"
#property version   "1.30"
#property strict
#property description "Latency arb V4.3 - Multi-broker A consensus (Tickmill+Pepperstone+IC Markets → GOC)"
#property description "Requires MT5 in HEDGING mode for B. All 4 terminals on same VPS (LD4)."

#include <Trade\Trade.mqh>

//=================== TELEGRAM (inlined) ============================
input group "=== Telegram Alerts ==="
input bool   TG_Enabled     = false;   // Enable Telegram notifications
input string TG_Token       = "";      // Bot token (from @BotFather)
input string TG_ChatId      = "";      // Chat ID
input int    TG_SummaryMin  = 5;       // A only: send summary every N min (0=off)

string TG_UrlEncode(string s)
{
   uchar bytes[];
   int len = StringToCharArray(s, bytes, 0, -1, CP_UTF8) - 1;
   if(len <= 0) return("");
   string out = "";
   for(int i = 0; i < len; i++)
   {
      uchar b = bytes[i];
      if((b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
         || b == '-' || b == '_' || b == '.' || b == '~')
         out += CharToString(b);
      else
         out += StringFormat("%%%02X", (int)b);
   }
   return(out);
}

bool TG_Send(string text)
{
   if(!TG_Enabled) return(false);
   if(StringLen(TG_Token) == 0 || StringLen(TG_ChatId) == 0) return(false);
   string url     = "https://api.telegram.org/bot" + TG_Token + "/sendMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + TG_ChatId + "&parse_mode=HTML&text=" + TG_UrlEncode(text);
   uchar data[];
   int dl = StringToCharArray(post, data, 0, -1, CP_UTF8) - 1;
   if(dl < 0) dl = 0;
   ArrayResize(data, dl);
   uchar result[];
   string result_headers;
   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, data, result, result_headers);
   if(res == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Print("Telegram: WebRequest not allowed. Add https://api.telegram.org in Options.");
      else
         PrintFormat("Telegram WebRequest failed err=%d", err);
      return(false);
   }
   if(res != 200) PrintFormat("Telegram HTTP %d", res);
   return(res == 200);
}

void TG_Startup(string version, string role, string broker, string symbol)
{
   TG_Send(StringFormat("[START] AURUM LatencyArb %s [%s]\nBroker: %s\nSymbol: %s",
                        version, role, broker, symbol));
}

void TG_OrderOpen(string action, string broker, string symbol,
                  double lots, double entry, int digits, ulong ticket)
{
   TG_Send(StringFormat("[OPEN %s]\nBroker: %s\nSymbol: %s\nLots: %.2f\nEntry: %.*f\nTicket: %I64u",
                        action, broker, symbol, lots, digits, entry, ticket));
}

void TG_OrderClose(string action, string reason,
                   double pnl_pts, long duration_ms, ulong ticket)
{
   string result = pnl_pts > 0.5 ? "WIN" : (pnl_pts < -0.5 ? "LOSS" : "FLAT");
   TG_Send(StringFormat("[CLOSE %s - %s]\nReason: %s\nPnL: %+.1f pts\nDuration: %I64d ms\nTicket: %I64u",
                        action, result, reason, pnl_pts, duration_ms, ticket));
}

void TG_Summary(int minutes,
                double a_ticks_per_min, double b_ticks_per_min,
                long signals_open, long signals_close, double last_delta)
{
   string verdict;
   double a = MathMax(a_ticks_per_min, 1.0);
   double b = MathMax(b_ticks_per_min, 1.0);
   if(a_ticks_per_min > b_ticks_per_min * 1.05)
      verdict = StringFormat("A feed is FASTER (+%.0f%%)", ((a-b)/b)*100);
   else if(b_ticks_per_min > a_ticks_per_min * 1.05)
      verdict = StringFormat("B feed is FASTER (+%.0f%%)", ((b-a)/a)*100);
   else
      verdict = "similar tick rate";
   string sig_line = (signals_close >= 0)
      ? StringFormat("Signals: %I64d open / %I64d close", signals_open, signals_close)
      : StringFormat("Signals fired: %I64d", signals_open);
   TG_Send(StringFormat(
      "[%d-min SUMMARY]\nA: %.0f ticks/min\nB: %.0f ticks/min\n%s\n%s\nLast delta: %.1f pts",
      minutes, a_ticks_per_min, b_ticks_per_min, verdict, sig_line, last_delta));
}

void TG_Shutdown(string version, string role, string summary)
{
   TG_Send(StringFormat("[STOPPED] AURUM LatencyArb %s [%s]\n%s",
                        version, role, summary));
}

//=================== ROLE ==========================================
enum ENUM_ROLE
{
   ROLE_A1_WATCHER = 0,   // A1 - Watcher on broker 1 (writes aurum_a1_hb.csv)
   ROLE_A2_WATCHER = 1,   // A2 - Watcher on broker 2 (writes aurum_a2_hb.csv)
   ROLE_A3_WATCHER = 2,   // A3 - Watcher on broker 3 (writes aurum_a3_hb.csv)
   ROLE_B_EXECUTOR = 3,   // B  - Executor (reads 3 heartbeats, consensus, opens orders)
};

enum ENUM_TRADE_DIR
{
   DIR_BOTH      = 0,
   DIR_BUY_ONLY  = 1,
   DIR_SELL_ONLY = 2,
};

//=================== INPUTS ========================================
input group "=== Role ==="
input ENUM_ROLE      InpRole              = ROLE_A1_WATCHER;

input group "=== Trade ==="
input double         InpLots              = 0.01;
input bool           InpReverseSignal     = false;   // Reverse: BUY signal opens SELL, and vice versa

input group "=== Consensus (B executor) ==="
input double         InpConsensusThreshold = 45.0;   // Min |delta| per broker to count (lower than V4.2 — offset by 3-broker confirmation)
input int            InpRequireConsensus  = 3;       // How many of 3 must agree (2 = 2/3 loose, 3 = strict all)
input double         InpMaxAgreeSpread    = 150.0;   // Max spread between 3 deltas (glitch detection)
input int            InpMaxHeartbeatAgeMs = 500;     // Max age of A heartbeat before treating as stale
input int            InpCooldownMs        = 3000;    // Between consecutive signals
input ENUM_TRADE_DIR InpDirection         = DIR_BOTH;

input group "=== Signal Quality Filters (B side) ==="
input bool           InpUseAdxFilter      = true;     // Enable ADX trend strength filter (uses B's chart)
input ENUM_TIMEFRAMES InpFilterTF         = PERIOD_M1;
input int            InpAdxPeriod         = 14;
input double         InpAdxThreshold      = 25.0;
input bool           InpUseVolumeFilter   = false;    // Enable volume/candle-body filter
input int            InpVolumeLookback    = 20;
input double         InpVolumeMultiplier  = 1.5;

input group "=== SL / TP Bracket (B — autonomous) ==="
input double         InpTpPts             = 20.0;    // Take profit target (net pts, armed after breakeven)
input double         InpSlPts             = 60.0;    // Stop loss cap (net pts) - must be > spread
input double         InpMaxSpreadPts      = 55.0;    // Skip signal if current spread > this (spike guard)
input int            InpMaxHoldMs         = 5000;    // Timeout backstop (ms)
input int            InpExecCooldownMs    = 500;

input group "=== Tick Logger ==="
input string         InpFilePrefix        = "ticklog_arb_v43";
input bool           InpUseCommonDir      = true;
input int            InpFlushEvery        = 200;
input bool           InpShowHeartbeat     = true;
input int            InpFreezeAlertMs     = 2000;
input int            InpBigSpreadPts      = 100;

//=================== CONSTANTS =====================================
#define MAGIC              20260730
#define HB_FILE_A1         "aurum_a1_hb.csv"
#define HB_FILE_A2         "aurum_a2_hb.csv"
#define HB_FILE_A3         "aurum_a3_hb.csv"
#define ACTION_BUY         "BUY"
#define ACTION_SELL        "SELL"

//=================== STATE =========================================
CTrade   trade;

string   g_tag             = "";
bool     g_is_watcher      = true;

// tick logger
int      g_fh              = INVALID_HANDLE;
long     g_last_msc        = 0;
long     g_count           = 0;
string   g_filename        = "";
ulong    g_prev_arrival    = 0;
double   g_prev_mid        = 0.0;
double   g_prev_spread_pts = 0.0;
bool     g_have_prev       = false;
double   g_sum_gap_ms      = 0.0;
double   g_sum_spread      = 0.0;
double   g_max_gap_ms      = 0.0;
double   g_max_spread      = 0.0;
long     g_freeze_count    = 0;
long     g_spike_count     = 0;

// A watcher state (A1/A2/A3 — writes own heartbeat file)
string   g_my_hb_filename    = "";   // set in OnInit based on role
long     g_hb_writes         = 0;

// B executor state — consensus tracking
long     g_b_last_signal_msc = 0;
long     g_b_last_exec_msc   = 0;
long     g_b_exec_count      = 0;
long     g_b_close_count     = 0;
long     g_b_signals_fired   = 0;

// B — per-A heartbeat cache (most recent read)
long     g_a1_msc = 0;   double g_a1_bid = 0.0;  double g_a1_ask = 0.0;  bool g_a1_ok = false;
long     g_a2_msc = 0;   double g_a2_bid = 0.0;  double g_a2_ask = 0.0;  bool g_a2_ok = false;
long     g_a3_msc = 0;   double g_a3_bid = 0.0;  double g_a3_ask = 0.0;  bool g_a3_ok = false;

// B — most recent computed deltas (for chart comment)
double   g_last_delta_1 = 0.0;
double   g_last_delta_2 = 0.0;
double   g_last_delta_3 = 0.0;

// B — skip counters by reason
long     g_skip_stale_hb   = 0;   // 1 or more A heartbeats stale
long     g_skip_no_sign    = 0;   // deltas didn't all point same direction
long     g_skip_below_thr  = 0;   // not enough deltas passed threshold
long     g_skip_glitch     = 0;   // sanity check failed (huge spread between deltas)
long     g_skip_adx        = 0;   // ADX filter blocked
long     g_skip_vol        = 0;   // volume filter blocked
long     g_skip_spread     = 0;   // B spread too wide
long     g_skip_cooldown   = 0;   // still in cooldown

// B — position tracking
bool     g_b_pos_open        = false;
string   g_b_pos_action      = "";
ulong    g_b_pos_ticket      = 0;
double   g_b_pos_entry_price = 0.0;
double   g_b_pos_sl_price    = 0.0;
double   g_b_pos_tp_price    = 0.0;
bool     g_b_pos_tp_armed    = false;
long     g_b_pos_open_msc    = 0;
string   g_b_last_close_reason = "";
double   g_b_pos_entry_delta = 0.0;  // consensus delta at entry (median)

// ADX + volume handles/state (B only)
double   g_b_last_adx        = 0.0;
double   g_b_last_vol_ratio  = 0.0;
int      g_adx_handle        = INVALID_HANDLE;

// Telegram summary tracking (A only)
long     g_last_summary_msc          = 0;
long     g_ticks_at_last_summary     = 0;
long     g_b_hb_updates              = 0;
long     g_b_hb_updates_last_summary = 0;
long     g_b_hb_last_msc_seen        = 0;

//+------------------------------------------------------------------+
string Sanitize(string s)
{
   string out = "";
   for(int i=0; i<StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      bool ok = (c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z')||c=='_'||c=='-';
      out += ok ? ShortToString(c) : "_";
   }
   return out;
}

long NowMs()
{
   return (long)TimeCurrent() * 1000 + (long)(GetTickCount64() % 1000);
}

// Return heartbeat filename for this role
string HeartbeatFileForRole(ENUM_ROLE r)
{
   if(r == ROLE_A1_WATCHER) return HB_FILE_A1;
   if(r == ROLE_A2_WATCHER) return HB_FILE_A2;
   if(r == ROLE_A3_WATCHER) return HB_FILE_A3;
   return "";  // B doesn't write
}

// Role label for logs / chart
string RoleTag(ENUM_ROLE r)
{
   if(r == ROLE_A1_WATCHER) return "A1";
   if(r == ROLE_A2_WATCHER) return "A2";
   if(r == ROLE_A3_WATCHER) return "A3";
   if(r == ROLE_B_EXECUTOR) return "B";
   return "?";
}

//+------------------------------------------------------------------+
//| Heartbeat I/O                                                     |
//+------------------------------------------------------------------+
bool WriteHeartbeatToFile(string fname, double bid, double ask)
{
   int flags = FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE;
   int h = FileOpen(fname, flags, ',');
   if(h == INVALID_HANDLE) return(false);
   double spread_pts = (ask - bid) / _Point;
   FileWrite(h,
      (string)NowMs(),
      DoubleToString(bid, _Digits), DoubleToString(ask, _Digits),
      (string)_Digits, DoubleToString(spread_pts, 1));
   FileFlush(h); FileClose(h);
   return(true);
}

bool ReadHeartbeatFromFile(string fname, long &out_msc, double &out_bid, double &out_ask)
{
   int flags = FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE;
   int h = FileOpen(fname, flags, ',');
   if(h == INVALID_HANDLE) return(false);
   string s_msc = FileReadString(h);
   string s_bid = FileReadString(h);
   string s_ask = FileReadString(h);
   FileClose(h);
   if(StringLen(s_msc) == 0 || StringLen(s_bid) == 0) return(false);
   out_msc = StringToInteger(s_msc);
   out_bid = StringToDouble(s_bid);
   out_ask = StringToDouble(s_ask);
   return(true);
}

//+------------------------------------------------------------------+
//| B: open + close position                                          |
//+------------------------------------------------------------------+
void OpenPosition(string action, double lots)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = _Point;
   int digits = _Digits;

   // Spread guard — reject if current spread wider than filter
   double current_spread_pts = (ask - bid) / point;
   if(current_spread_pts > InpMaxSpreadPts)
   {
      g_skip_spread++;
      PrintFormat("[B] %s SKIPPED — spread=%.0f > MaxSpread=%.0f (spike guard)",
                  action, current_spread_pts, InpMaxSpreadPts);
      return;
   }

   // Check minimum broker stop level
   long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(InpSlPts <= current_spread_pts + stops_level)
   {
      PrintFormat("[B] %s SKIPPED — SlPts=%.0f <= spread(%.0f)+stops(%I64d)",
                  action, InpSlPts, current_spread_pts, stops_level);
      return;
   }

   // Send MARKET order WITHOUT SL/TP first — we'll modify after we know actual fill price
   bool ok = false;
   if(action == ACTION_BUY)
      ok = trade.Buy(lots, _Symbol, 0, 0, 0, "gold sport EA");
   else if(action == ACTION_SELL)
      ok = trade.Sell(lots, _Symbol, 0, 0, 0, "gold sport EA");

   if(!ok)
   {
      PrintFormat("[B] %s open failed: %d (%s)", action,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }

   ulong ticket = trade.ResultOrder();
   double actual_entry = trade.ResultPrice();  // ← ACTUAL fill price
   if(actual_entry <= 0)
   {
      // fallback if broker didn't return price
      actual_entry = (action == ACTION_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }

   // Now compute SL based on ACTUAL entry (fixes stale-ask bug)
   double sl_price = 0.0;
   if(action == ACTION_BUY)
      sl_price = NormalizeDouble(actual_entry - InpSlPts * point, digits);
   else
      sl_price = NormalizeDouble(actual_entry + InpSlPts * point, digits);

   // Modify position to add SL only (TP deferred)
   if(!trade.PositionModify(ticket, sl_price, 0))
   {
      PrintFormat("[B] Failed to set SL on ticket %I64u: %d (%s)",
                  ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      // continue anyway — position is open with no SL yet, timeout will backstop
   }

   g_b_pos_open        = true;
   g_b_pos_action      = action;
   g_b_pos_ticket      = ticket;
   g_b_pos_entry_price = actual_entry;
   g_b_pos_sl_price    = sl_price;
   g_b_pos_tp_price    = 0.0;
   g_b_pos_tp_armed    = false;
   g_b_pos_open_msc    = NowMs();
   g_b_last_exec_msc   = NowMs();
   g_b_exec_count++;

   PrintFormat("[B] OPEN %s ticket=%I64u lots=%.2f entry=%.*f SL=%.*f  (TP deferred until breakeven)",
               action, ticket, lots, digits, actual_entry, digits, sl_price);
   TG_OrderOpen(action, AccountInfoString(ACCOUNT_COMPANY), _Symbol,
                lots, actual_entry, digits, ticket);
}

double CurrentPnLPts()
{
   if(!g_b_pos_open) return 0.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_b_pos_action == ACTION_BUY)
      return (bid - g_b_pos_entry_price) / _Point;
   return (g_b_pos_entry_price - ask) / _Point;
}

void ClosePosition(string reason)
{
   if(!g_b_pos_open) return;
   double pnl_pts = CurrentPnLPts();
   long duration = NowMs() - g_b_pos_open_msc;
   ulong ticket = g_b_pos_ticket;
   string action = g_b_pos_action;

   if(trade.PositionClose(ticket))
   {
      g_b_pos_open        = false;
      g_b_pos_action      = "";
      g_b_pos_ticket      = 0;
      g_b_pos_entry_price = 0.0;
      g_b_pos_sl_price    = 0.0;
      g_b_pos_tp_price    = 0.0;
      g_b_pos_tp_armed    = false;
      g_b_pos_open_msc    = 0;
      g_b_close_count++;
      g_b_last_close_reason = reason;
      PrintFormat("[B] CLOSE %s reason=%s pnl=%.1f pts duration=%I64d ms ticket=%I64u",
                  action, reason, pnl_pts, duration, ticket);
      TG_OrderClose(action, reason, pnl_pts, duration, ticket);
   }
   else
   {
      PrintFormat("[B] CLOSE failed reason=%s ticket=%I64u err=%d (%s)",
                  reason, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| B: monitor position — detect broker-side SL/TP close + timeout   |
//+------------------------------------------------------------------+
void MonitorPosition()
{
   if(!g_b_pos_open) return;

   // Check if position still exists (broker may have closed via SL/TP)
   if(!PositionSelectByTicket(g_b_pos_ticket))
   {
      // Position closed by broker — determine reason from history
      string reason = "BROKER_CLOSE";
      double pnl_pts_est = 0.0;
      long duration = NowMs() - g_b_pos_open_msc;
      ulong closed_ticket = g_b_pos_ticket;
      string closed_action = g_b_pos_action;

      // Try to find the closing deal in history
      if(HistorySelectByPosition(g_b_pos_ticket))
      {
         int deals = HistoryDealsTotal();
         for(int i = deals - 1; i >= 0; i--)
         {
            ulong deal_ticket = HistoryDealGetTicket(i);
            if(deal_ticket == 0) continue;
            if(HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) != (long)g_b_pos_ticket) continue;
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
            if(entry != DEAL_ENTRY_OUT) continue;

            ENUM_DEAL_REASON deal_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
            if(deal_reason == DEAL_REASON_SL)       reason = "SL_HIT";
            else if(deal_reason == DEAL_REASON_TP)  reason = "TP_HIT";
            else if(deal_reason == DEAL_REASON_SO)  reason = "STOPOUT";
            else if(deal_reason == DEAL_REASON_EXPERT) reason = "EA_CLOSE";
            else reason = StringFormat("REASON_%d", (int)deal_reason);

            double exit_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
            if(closed_action == ACTION_BUY)
               pnl_pts_est = (exit_price - g_b_pos_entry_price) / _Point;
            else
               pnl_pts_est = (g_b_pos_entry_price - exit_price) / _Point;
            break;
         }
      }

      g_b_pos_open        = false;
      g_b_pos_action      = "";
      g_b_pos_ticket      = 0;
      g_b_pos_entry_price = 0.0;
      g_b_pos_sl_price    = 0.0;
      g_b_pos_tp_price    = 0.0;
      g_b_pos_tp_armed    = false;
      g_b_pos_open_msc    = 0;
      g_b_close_count++;
      g_b_last_close_reason = reason;

      PrintFormat("[B] BROKER CLOSED %s reason=%s pnl=%.1f pts duration=%I64d ms ticket=%I64u",
                  closed_action, reason, pnl_pts_est, duration, closed_ticket);
      TG_OrderClose(closed_action, reason, pnl_pts_est, duration, closed_ticket);
      return;
   }

   // Position still open — check TP arming and timeout
   double pnl_pts = CurrentPnLPts();

   // Arm TP once past breakeven (pnl >= 0 means we've cleared spread cost)
   if(!g_b_pos_tp_armed && pnl_pts >= 0)
   {
      double point = _Point;
      int digits = _Digits;
      double tp_price = 0.0;
      if(g_b_pos_action == ACTION_BUY)
         tp_price = NormalizeDouble(g_b_pos_entry_price + InpTpPts * point, digits);
      else
         tp_price = NormalizeDouble(g_b_pos_entry_price - InpTpPts * point, digits);

      if(trade.PositionModify(g_b_pos_ticket, g_b_pos_sl_price, tp_price))
      {
         g_b_pos_tp_price = tp_price;
         g_b_pos_tp_armed = true;
         PrintFormat("[B] TP ARMED at %.*f (pnl was %.1f pts) — broker will close on hit",
                     digits, tp_price, pnl_pts);
      }
      else
      {
         PrintFormat("[B] Failed to arm TP: %d (%s)",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   long elapsed = NowMs() - g_b_pos_open_msc;
   if(elapsed >= InpMaxHoldMs)
      ClosePosition("TIMEOUT");
}

//+------------------------------------------------------------------+
//| A: signal quality filters                                         |
//+------------------------------------------------------------------+
double GetCurrentAdx()
{
   if(g_adx_handle == INVALID_HANDLE) return 100.0;   // handle not ready — allow
   double buf[];
   if(CopyBuffer(g_adx_handle, 0, 0, 1, buf) < 1) return 0.0;
   return buf[0];
}

double GetVolumeRatio()
{
   long vol[];
   int need = InpVolumeLookback + 1;
   if(CopyTickVolume(_Symbol, InpFilterTF, 0, need, vol) < need) return 1.0;
   double avg = 0;
   for(int i=1; i<=InpVolumeLookback; i++) avg += (double)vol[i];
   avg /= InpVolumeLookback;
   if(avg <= 0) return 1.0;
   return (double)vol[0] / avg;
}

// Return true if signal passes ALL quality filters
bool PassesQualityFilters(string &reject_reason)
{
   reject_reason = "";
   if(InpUseAdxFilter)
   {
      double adx = GetCurrentAdx();
      g_b_last_adx = adx;
      if(adx < InpAdxThreshold)
      {
         g_skip_adx++;
         reject_reason = StringFormat("ADX=%.1f < %.1f", adx, InpAdxThreshold);
         return false;
      }
   }
   if(InpUseVolumeFilter)
   {
      double ratio = GetVolumeRatio();
      g_b_last_vol_ratio = ratio;
      if(ratio < InpVolumeMultiplier)
      {
         g_skip_vol++;
         reject_reason = StringFormat("VolRatio=%.2f < %.2f", ratio, InpVolumeMultiplier);
         return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| A watcher: just publish heartbeat (no signal logic)               |
//+------------------------------------------------------------------+
void WatcherPublish(double a_bid, double a_ask)
{
   WriteHeartbeatToFile(g_my_hb_filename, a_bid, a_ask);
   g_hb_writes++;
}

//+------------------------------------------------------------------+
//| B: compute median of 3 numbers                                    |
//+------------------------------------------------------------------+
double MedianOf3(double x, double y, double z)
{
   if((x <= y && y <= z) || (z <= y && y <= x)) return y;
   if((y <= x && x <= z) || (z <= x && x <= y)) return x;
   return z;
}

//+------------------------------------------------------------------+
//| B: consensus check — reads 3 A heartbeats, decides signal         |
//+------------------------------------------------------------------+
void ExecutorConsensusCheck()
{
   if(g_b_pos_open) return;  // already trading

   // Cooldown between signals
   if(NowMs() - g_b_last_signal_msc < InpCooldownMs)
      return;

   // 1. Read all 3 A heartbeats (any may be missing)
   g_a1_ok = ReadHeartbeatFromFile(HB_FILE_A1, g_a1_msc, g_a1_bid, g_a1_ask);
   g_a2_ok = ReadHeartbeatFromFile(HB_FILE_A2, g_a2_msc, g_a2_bid, g_a2_ask);
   g_a3_ok = ReadHeartbeatFromFile(HB_FILE_A3, g_a3_msc, g_a3_bid, g_a3_ask);

   // 2. Freshness — mark stale/missing brokers as inactive (do NOT block)
   long now = NowMs();
   bool a1_active = g_a1_ok && (now - g_a1_msc) <= InpMaxHeartbeatAgeMs;
   bool a2_active = g_a2_ok && (now - g_a2_msc) <= InpMaxHeartbeatAgeMs;
   bool a3_active = g_a3_ok && (now - g_a3_msc) <= InpMaxHeartbeatAgeMs;

   int active_count = (a1_active ? 1 : 0) + (a2_active ? 1 : 0) + (a3_active ? 1 : 0);

   // Need at least InpRequireConsensus active brokers to even attempt
   if(active_count < InpRequireConsensus)
   {
      g_skip_stale_hb++;
      return;
   }

   // 3. Get own B price
   double b_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double b_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double b_mid = (b_bid + b_ask) * 0.5;
   double point = _Point;

   // 4. Compute delta for each ACTIVE A broker (inactive = 0)
   double d1 = 0, d2 = 0, d3 = 0;
   if(a1_active)
   {
      double a1_mid = (g_a1_bid + g_a1_ask) * 0.5;
      d1 = (a1_mid - b_mid) / point;
   }
   if(a2_active)
   {
      double a2_mid = (g_a2_bid + g_a2_ask) * 0.5;
      d2 = (a2_mid - b_mid) / point;
   }
   if(a3_active)
   {
      double a3_mid = (g_a3_bid + g_a3_ask) * 0.5;
      d3 = (a3_mid - b_mid) / point;
   }

   g_last_delta_1 = d1;
   g_last_delta_2 = d2;
   g_last_delta_3 = d3;

   // 5. Sign consensus — only count active brokers' signs
   int pos_count = 0, neg_count = 0;
   if(a1_active) { if(d1 > 0) pos_count++; else if(d1 < 0) neg_count++; }
   if(a2_active) { if(d2 > 0) pos_count++; else if(d2 < 0) neg_count++; }
   if(a3_active) { if(d3 > 0) pos_count++; else if(d3 < 0) neg_count++; }

   bool buy_side  = (pos_count >= InpRequireConsensus);
   bool sell_side = (neg_count >= InpRequireConsensus);

   if(!buy_side && !sell_side)
   {
      g_skip_no_sign++;
      return;
   }

   // 6. Threshold consensus — count active brokers passing |delta| threshold
   int agree = 0;
   double thr = InpConsensusThreshold;
   double d1a = a1_active ? MathAbs(d1) : 0;
   double d2a = a2_active ? MathAbs(d2) : 0;
   double d3a = a3_active ? MathAbs(d3) : 0;
   if(a1_active && d1a >= thr) agree++;
   if(a2_active && d2a >= thr) agree++;
   if(a3_active && d3a >= thr) agree++;

   if(agree < InpRequireConsensus)
   {
      g_skip_below_thr++;
      return;
   }

   // 7. Sanity check — max spread between ACTIVE deltas
   double dmax = -DBL_MAX, dmin = DBL_MAX;
   if(a1_active) { if(d1a > dmax) dmax = d1a; if(d1a < dmin) dmin = d1a; }
   if(a2_active) { if(d2a > dmax) dmax = d2a; if(d2a < dmin) dmin = d2a; }
   if(a3_active) { if(d3a > dmax) dmax = d3a; if(d3a < dmin) dmin = d3a; }
   if(dmax - dmin > InpMaxAgreeSpread)
   {
      g_skip_glitch++;
      PrintFormat("[B] SKIP — deltas too spread: d1=%.1f d2=%.1f d3=%.1f (range=%.1f > %.1f) active=%d",
                  d1, d2, d3, dmax - dmin, InpMaxAgreeSpread, active_count);
      return;
   }

   // 8. Compute median/consensus delta from ACTIVE brokers only
   double consensus_delta;
   if(active_count == 3)
      consensus_delta = MedianOf3(d1, d2, d3);
   else if(active_count == 2)
   {
      // Average of the two active brokers
      double sum = 0;
      if(a1_active) sum += d1;
      if(a2_active) sum += d2;
      if(a3_active) sum += d3;
      consensus_delta = sum / 2.0;
   }
   else   // active_count == 1 (only reachable if InpRequireConsensus=1)
   {
      if(a1_active)      consensus_delta = d1;
      else if(a2_active) consensus_delta = d2;
      else               consensus_delta = d3;
   }

   if(MathAbs(consensus_delta) < thr)
   {
      g_skip_below_thr++;
      return;
   }

   // 9. Determine action
   bool allow_buy  = (InpDirection == DIR_BOTH || InpDirection == DIR_BUY_ONLY);
   bool allow_sell = (InpDirection == DIR_BOTH || InpDirection == DIR_SELL_ONLY);
   string action = "";
   if(buy_side && consensus_delta > 0 && allow_buy)
      action = ACTION_BUY;
   else if(sell_side && consensus_delta < 0 && allow_sell)
      action = ACTION_SELL;
   else
      return;   // direction filtered

   // 10. Signal quality filters (ADX, volume — on B's own chart)
   string reject_reason = "";
   if(!PassesQualityFilters(reject_reason))
   {
      PrintFormat("[B] %s signal consensus=%.1f SKIPPED — %s", action, consensus_delta, reject_reason);
      return;
   }

   // 11. Execution cooldown
   if(NowMs() - g_b_last_exec_msc < InpExecCooldownMs)
   {
      g_skip_cooldown++;
      return;
   }

   // 12. All checks passed — fire!
   g_b_last_signal_msc = NowMs();
   g_b_signals_fired++;
   g_b_pos_entry_delta = consensus_delta;

   PrintFormat("[B] SIGNAL %s consensus=%.1f  d1=%.1f d2=%.1f d3=%.1f  active=%d/3  agree=%d",
               action, consensus_delta, d1, d2, d3, active_count, agree);

   // Reverse toggle (safety option — normally false)
   string exec_action = action;
   if(InpReverseSignal)
   {
      exec_action = (action == ACTION_BUY) ? ACTION_SELL : ACTION_BUY;
      PrintFormat("[B] REVERSED: %s -> %s", action, exec_action);
   }

   OpenPosition(exec_action, InpLots);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Role setup — 3 A slots + 1 B slot
   g_tag              = RoleTag(InpRole);
   g_is_watcher       = (InpRole != ROLE_B_EXECUTOR);
   g_my_hb_filename   = HeartbeatFileForRole(InpRole);

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetTypeFillingBySymbol(_Symbol);

   string broker = Sanitize(AccountInfoString(ACCOUNT_COMPANY));
   string sym    = Sanitize(_Symbol);
   MqlDateTime dt; TimeToStruct(TimeLocal(), dt);
   string stamp  = StringFormat("%04d%02d%02d_%02d%02d",
                                dt.year, dt.mon, dt.day, dt.hour, dt.min);
   g_filename = StringFormat("%s_%s_%s_%s_%s.csv",
                             InpFilePrefix, g_tag, broker, sym, stamp);

   int flags = FILE_WRITE|FILE_CSV|FILE_ANSI;
   if(InpUseCommonDir) flags |= FILE_COMMON;

   g_fh = FileOpen(g_filename, flags, ',');
   if(g_fh == INVALID_HANDLE)
   {
      PrintFormat("FileOpen failed err=%d", GetLastError());
      return(INIT_FAILED);
   }
   FileWrite(g_fh,
      "ts_ms","bid","ask","broker_time_msc","spread_pts",
      "quote_latency_ms","gap_from_prev_ms","price_jump_pts","spread_jump_pts");
   FileFlush(g_fh);

   EventSetTimer(1);

   // ADX handle for executor (B) if filter enabled
   if(!g_is_watcher && InpUseAdxFilter)
   {
      g_adx_handle = iADX(_Symbol, InpFilterTF, InpAdxPeriod);
      if(g_adx_handle == INVALID_HANDLE)
         PrintFormat("[B] WARNING: ADX handle failed err=%d — filter disabled", GetLastError());
      else
         PrintFormat("[B] ADX filter enabled: period=%d threshold=%.1f TF=%d",
                     InpAdxPeriod, InpAdxThreshold, (int)InpFilterTF);
   }

   PrintFormat("AURUM_LatencyArb_V4.3 [%s] started. broker=%s symbol=%s -> %s%s  hb_file=%s",
               g_tag, broker, sym,
               (InpUseCommonDir?"[Common]\\Files\\":"\\Files\\"), g_filename,
               g_is_watcher ? g_my_hb_filename : "(reads a1,a2,a3)");

   TG_Startup("V4.3", g_tag, AccountInfoString(ACCOUNT_COMPANY), _Symbol);

   if(!g_is_watcher &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
      != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("[B] WARNING: Account is NOT in Hedging mode.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return;

   bool new_tick = (t.time_msc != g_last_msc);
   if(new_tick) g_last_msc = t.time_msc;

   if(g_is_watcher)
   {
      // A1/A2/A3 — just publish own heartbeat, no signal detection
      WatcherPublish(t.bid, t.ask);
   }
   else
   {
      // B — read 3 heartbeats, consensus check, monitor open position
      ExecutorConsensusCheck();
      MonitorPosition();
   }

   if(!new_tick || g_fh == INVALID_HANDLE) return;

   ulong  arrival    = GetTickCount64();
   double spread_pts = (t.ask - t.bid) / _Point;
   double mid        = (t.bid + t.ask) * 0.5;
   double quote_latency_ms = (double)((long)arrival - (long)t.time_msc);

   double gap_from_prev_ms = 0.0;
   double price_jump_pts   = 0.0;
   double spread_jump_pts  = 0.0;
   if(g_have_prev)
   {
      gap_from_prev_ms = (double)(arrival - g_prev_arrival);
      price_jump_pts   = MathAbs(mid - g_prev_mid) / _Point;
      spread_jump_pts  = spread_pts - g_prev_spread_pts;
   }

   FileWrite(g_fh,
      (string)arrival,
      DoubleToString(t.bid, _Digits), DoubleToString(t.ask, _Digits),
      (string)t.time_msc, DoubleToString(spread_pts, 1),
      DoubleToString(quote_latency_ms, 0), DoubleToString(gap_from_prev_ms, 0),
      DoubleToString(price_jump_pts, 1), DoubleToString(spread_jump_pts, 1));

   g_sum_gap_ms += gap_from_prev_ms;
   g_sum_spread += spread_pts;
   if(gap_from_prev_ms > g_max_gap_ms) g_max_gap_ms = gap_from_prev_ms;
   if(spread_pts       > g_max_spread) g_max_spread = spread_pts;
   if(g_have_prev && gap_from_prev_ms > InpFreezeAlertMs) g_freeze_count++;
   if(spread_pts > InpBigSpreadPts) g_spike_count++;

   g_prev_arrival    = arrival;
   g_prev_mid        = mid;
   g_prev_spread_pts = spread_pts;
   g_have_prev       = true;

   g_count++;
   if((g_count % InpFlushEvery) == 0) FileFlush(g_fh);
}

//+------------------------------------------------------------------+
//| OnTimer                                                           |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_fh != INVALID_HANDLE) FileFlush(g_fh);
   if(!InpShowHeartbeat) return;

   double avg_gap_ms = 0.0, avg_spread_pts = 0.0;
   if(g_count > 0)
   {
      avg_gap_ms     = g_sum_gap_ms / (double)g_count;
      avg_spread_pts = g_sum_spread / (double)g_count;
   }

   MqlTick t; SymbolInfoTick(_Symbol, t);
   string role_block;

   if(g_is_watcher)
   {
      // A1 / A2 / A3 — simple: just showing that we're publishing HB
      role_block = StringFormat(
         "role: %s (WATCHER V4.3 - price publisher)\n"
         "publishing to: %s\n"
         "hb writes: %I64d\n"
         "(No signal logic here — B does consensus.)",
         g_tag, g_my_hb_filename, g_hb_writes);
   }
   else
   {
      // B — full consensus + position status
      string pos_line = g_b_pos_open
         ? StringFormat("OPEN %s @ %.*f  pnl=%.1f pts  SL=%.*f  TP=%s  age=%I64d ms",
                        g_b_pos_action, _Digits, g_b_pos_entry_price,
                        CurrentPnLPts(),
                        _Digits, g_b_pos_sl_price,
                        g_b_pos_tp_armed ? StringFormat("%.*f (ARMED)", _Digits, g_b_pos_tp_price) : "not-armed",
                        NowMs() - g_b_pos_open_msc)
         : StringFormat("no position (last close: %s)",
                        StringLen(g_b_last_close_reason)>0 ? g_b_last_close_reason : "(none)");

      long now = NowMs();
      bool a1_act = g_a1_ok && (now - g_a1_msc) <= InpMaxHeartbeatAgeMs;
      bool a2_act = g_a2_ok && (now - g_a2_msc) <= InpMaxHeartbeatAgeMs;
      bool a3_act = g_a3_ok && (now - g_a3_msc) <= InpMaxHeartbeatAgeMs;
      int active_count = (a1_act?1:0) + (a2_act?1:0) + (a3_act?1:0);

      string a1_status = a1_act
         ? StringFormat("A1: ACTIVE  Δ=%+.1f  age=%I64d ms", g_last_delta_1, now - g_a1_msc)
         : (g_a1_ok ? StringFormat("A1: STALE (age=%I64d ms)", now - g_a1_msc) : "A1: NO FILE (not running?)");
      string a2_status = a2_act
         ? StringFormat("A2: ACTIVE  Δ=%+.1f  age=%I64d ms", g_last_delta_2, now - g_a2_msc)
         : (g_a2_ok ? StringFormat("A2: STALE (age=%I64d ms)", now - g_a2_msc) : "A2: NO FILE (not running?)");
      string a3_status = a3_act
         ? StringFormat("A3: ACTIVE  Δ=%+.1f  age=%I64d ms", g_last_delta_3, now - g_a3_msc)
         : (g_a3_ok ? StringFormat("A3: STALE (age=%I64d ms)", now - g_a3_msc) : "A3: NO FILE (not running?)");

      string filter_line = "filters: ";
      filter_line += InpUseAdxFilter
         ? StringFormat("ADX=%.1f (min %.1f) ", g_b_last_adx, InpAdxThreshold)
         : "ADX=off ";
      filter_line += InpUseVolumeFilter
         ? StringFormat("Vol=%.2f (min %.2f)", g_b_last_vol_ratio, InpVolumeMultiplier)
         : "Vol=off";

      string skip_line = StringFormat(
         "skipped: stale=%I64d nosign=%I64d belowthr=%I64d glitch=%I64d adx=%I64d vol=%I64d spread=%I64d",
         g_skip_stale_hb, g_skip_no_sign, g_skip_below_thr, g_skip_glitch,
         g_skip_adx, g_skip_vol, g_skip_spread);

      role_block = StringFormat(
         "role: B (EXECUTOR V4.3 - multi-broker consensus)\n"
         "%s\n%s\n%s\n"
         "active brokers: %d/3   signals fired: %I64d   opens: %I64d   closes: %I64d\n"
         "%s\n"
         "%s\n"
         "position: %s\n"
         "config: thr=%.0f req=%d/3 maxSpread=%.0f  TP=%.0f/SL=%.0f  timeout=%d ms",
         a1_status, a2_status, a3_status,
         active_count, g_b_signals_fired, g_b_exec_count, g_b_close_count,
         filter_line, skip_line, pos_line,
         InpConsensusThreshold, InpRequireConsensus, InpMaxAgreeSpread,
         InpTpPts, InpSlPts, InpMaxHoldMs);
   }

   Comment(StringFormat(
      "AURUM LatencyArb V4.3 (Multi-broker Consensus)\n"
      "%s\n"
      "broker: %s   symbol: %s\n"
      "-- feed quality --\n"
      "ticks: %I64d   avg gap: %.0f ms (max %.0f)\n"
      "avg spread: %.1f pts (max %.1f)\n"
      "freezes: %I64d   spread spikes: %I64d\n"
      "log: %s",
      role_block, AccountInfoString(ACCOUNT_COMPANY), _Symbol,
      g_count, avg_gap_ms, g_max_gap_ms, avg_spread_pts, g_max_spread,
      g_freeze_count, g_spike_count,
      g_filename));

   // Periodic Telegram summary (from B — where consensus/signals happen)
   if(!g_is_watcher && TG_Enabled && TG_SummaryMin > 0)
   {
      long now = NowMs();
      if(g_last_summary_msc == 0) g_last_summary_msc = now;
      long span_ms = (long)TG_SummaryMin * 60 * 1000;
      if(now - g_last_summary_msc >= span_ms)
      {
         long b_ticks_since = g_count - g_ticks_at_last_summary;
         g_ticks_at_last_summary = g_count;
         double b_rate = (double)b_ticks_since / (double)TG_SummaryMin;
         double median_delta = MedianOf3(g_last_delta_1, g_last_delta_2, g_last_delta_3);
         TG_Summary(TG_SummaryMin, b_rate, 0.0,
                    g_b_signals_fired, g_b_exec_count, median_delta);
         g_last_summary_msc = now;
      }
   }
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_adx_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_adx_handle);
      g_adx_handle = INVALID_HANDLE;
   }
   if(g_fh != INVALID_HANDLE)
   {
      FileFlush(g_fh); FileClose(g_fh);
      g_fh = INVALID_HANDLE;
   }
   Comment("");
   string summary;
   if(g_is_watcher)
   {
      summary = StringFormat("HB writes: %I64d\nTotal ticks: %I64d",
                             g_hb_writes, g_count);
      PrintFormat("V4.3 [%s] stopped. hb_writes=%I64d ticks=%I64d",
                  g_tag, g_hb_writes, g_count);
   }
   else
   {
      summary = StringFormat("Signals: %I64d fired / %I64d opens / %I64d closes\nTotal ticks: %I64d",
                             g_b_signals_fired, g_b_exec_count, g_b_close_count, g_count);
      PrintFormat("V4.3 [B] stopped. signals=%I64d opens=%I64d closes=%I64d ticks=%I64d pos_open=%s",
                  g_b_signals_fired, g_b_exec_count, g_b_close_count, g_count,
                  g_b_pos_open ? "YES(!)" : "no");
   }
   TG_Shutdown("V4.3", g_tag, summary);
}
//+------------------------------------------------------------------+
