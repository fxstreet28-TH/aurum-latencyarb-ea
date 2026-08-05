//+------------------------------------------------------------------+
//|                              AURUM_Breakout_Straddle_V1.mq5       |
//|                                                 AURUM TECH / Por  |
//|                                                                  |
//|  Volatility-breakout straddle. Standalone EA — shares NO logic    |
//|  with the LatencyArb family: one broker, no A/B roles, no         |
//|  heartbeat files, no cross-broker consensus, no execution-speed   |
//|  dependence.                                                      |
//|                                                                  |
//|  Strategy:                                                        |
//|    1. Wait for a strong M1 bar (range >= InpStrengthMult x the    |
//|       average range of the last InpRangeLookback bars).           |
//|    2. Open BUY and SELL at the same lot simultaneously.           |
//|    3. When either leg reaches InpCutPts profit, close the other   |
//|       leg at market (cost of discovering direction).             |
//|    4. Let the winner run behind a real server-side trailing stop: |
//|       start InpInitialSlPts below the cut point, ratchet up one   |
//|       step per InpTrailStepPts of favourable advance.             |
//|    5. When the trailing stop takes the winner out the cycle ends. |
//|       Wait InpCooldownSec, then look for the next strong bar.     |
//|                                                                  |
//|  The strength filter IS the strategy — without it the system      |
//|  loses. Do NOT add a trend/direction filter and do NOT shrink     |
//|  InpTrailStepPts below 100 (it cuts off the runners that pay).    |
//+------------------------------------------------------------------+
#property copyright "AURUM TECH"
#property version   "1.00"
#property description "AURUM Breakout Straddle V1 — volatility breakout straddle on XAUUSD."
#property description "Requires an MT5 HEDGING account. One broker, standalone (not part of LatencyArb)."

#include <Trade\Trade.mqh>

//=================== INPUTS ========================================
input group "=== Entry filter ==="
input double InpStrengthMult      = 2.0;    // Bar range must be >= this x the average. Tested 1.8-2.5; below 1.8 the edge disappears
input int    InpRangeLookback     = 20;     // Bars used for the average range
input ENUM_TIMEFRAMES InpBarTF    = PERIOD_M1;
input bool   InpUseAdx            = false;  // Optional extra filter, off by default (untested)
input int    InpAdxPeriod         = 14;
input double InpAdxMin            = 25.0;
input bool   InpUseTickVolume     = false;  // Optional: bar tick volume >= multiple of its average
input double InpVolumeMult        = 1.5;

input group "=== Trade ==="
input double InpLots              = 0.01;
input double InpCutPts            = 100.0;  // Close the losing leg once the other is this far in profit
input double InpInitialSlPts      = 300.0;  // Stop distance for the winner, measured from the cut point
input double InpTrailStepPts      = 100.0;  // Ratchet the stop one step per this much advance. Do NOT go below 100 - it kills the runners
input int    InpMaxHoldSec        = 1800;   // Force close everything after this long
input int    InpCooldownSec       = 60;     // Minimum wait between cycles

input group "=== Guards ==="
input double InpMaxSpreadPts      = 45.0;   // Never open when spread is above this - a straddle pays it twice
input int    InpNoTradeMinsAroundRollover = 15;  // Skip either side of broker midnight
input bool   InpUseSessionFilter  = false;
input string InpSession1          = "";     // "HH:MM-HH:MM" UTC, blank = unused
input string InpSession2          = "";
input double InpMaxDailyLossPts   = 1500.0; // Stop trading for the day past this. 0 = disabled
input int    InpMaxConsecLosses   = 5;      // Pause after this many losing cycles in a row. 0 = disabled
input int    InpPauseAfterStopMins= 60;     // How long the pause lasts

input group "=== Identity ==="
input long   InpMagic             = 20260810;
input string InpDeploymentId      = "";     // Dashboard pair id
input bool   InpTelemetryEnabled  = true;
input string InpTelemetryUrl      = "https://aurum-trading-dashboard.vercel.app";
input string InpIngestKey         = "";
input int    InpPanelX            = 12;
input int    InpPanelY            = 20;
input int    InpPanelFont         = 9;

//=================== CONSTANTS =====================================
#define EA_VERSION        "bs1.0"
#define TEL_ENDPOINT_PATH "/api/events"
#define TEL_QUEUE_CAP     200
#define TEL_BATCH_MAX     20
#define HEARTBEAT_SEC     30
#define TEL_FLUSH_SEC     5
#define PANEL_PREFIX      "AURUM_BS_"
#define PANEL_MAX_LINES   20

//=================== STATE ========================================
CTrade trade;

enum ENUM_CYCLE_STATE { ST_IDLE = 0, ST_BOTH_OPEN = 1, ST_RUNNING = 2 };

ENUM_CYCLE_STATE g_state = ST_IDLE;

bool   g_is_tester = false;
string g_tel_url   = "";              // full endpoint URL (InpTelemetryUrl + /api/events)

// bar detection
datetime g_last_bar_time = 0;

// current cycle legs
ulong  g_buy_ticket   = 0;
ulong  g_sell_ticket  = 0;
double g_buy_entry    = 0.0;
double g_sell_entry   = 0.0;

// running (winner) state
bool   g_winner_is_buy = false;
ulong  g_winner_ticket = 0;
double g_winner_entry  = 0.0;
double g_cut_ref       = 0.0;         // reference price captured at the moment of the cut
double g_winner_sl     = 0.0;         // current server-side SL on the winner
int    g_trail_steps   = 0;
bool   g_stop_clamped  = false;       // logged-once flag for stops-level clamping
double g_cut_leg_pts   = 0.0;         // realised points of the cut leg (negative)

// cycle timing
long   g_cycle_open_ms = 0;
long   g_cycle_end_ms  = 0;           // NowMs() when the last cycle ended (cooldown base)

// panel: last evaluated bar
double g_last_bar_range = 0.0;
double g_last_avg_range = 0.0;

// circuit breakers / accounting
datetime g_broker_day    = 0;
double   g_daily_net_pts = 0.0;       // signed points realised this broker-day
int      g_daily_cycles  = 0;
int      g_daily_wins    = 0;
int      g_daily_losses  = 0;
bool     g_daily_lock    = false;     // daily-loss lockout until next broker-day
int      g_consec_losses = 0;
long     g_pause_until_ms = 0;        // consec-loss pause end (NowMs)

// session totals (OnDeinit summary)
int    g_tot_cycles   = 0;
int    g_tot_wins     = 0;
int    g_tot_losses   = 0;
double g_tot_net_pts  = 0.0;
int    g_max_consec   = 0;
double g_largest_win  = 0.0;
double g_largest_loss = 0.0;

// indicator handles (optional filters)
int    g_adx_handle = INVALID_HANDLE;

// tick counter (heartbeat payload)
long   g_ticks = 0;

// telemetry queue
string g_tel_q[];
long   g_tel_last_hb_ms    = 0;
long   g_tel_last_flush_ms = 0;

// per-cycle telemetry context (staged at signal, completed at close)
struct CycleCtx
{
   long   t_signal;
   string opened_at_iso;
   string session;
   double bar_range_pts;
   double avg_range_pts;
   double strength_mult;
   double spread_at_open;
   double buy_entry;
   double sell_entry;
};
CycleCtx g_cyc;

void ResetCtx(CycleCtx &c)
{
   c.t_signal      = 0;
   c.opened_at_iso = "";
   c.session       = "";
   c.bar_range_pts = 0.0;
   c.avg_range_pts = 0.0;
   c.strength_mult = 0.0;
   c.spread_at_open= 0.0;
   c.buy_entry     = 0.0;
   c.sell_entry    = 0.0;
}

//=================== SMALL HELPERS ================================
// Monotonic ms since boot — the single clock used for all ages/cooldowns.
long NowMs() { return (long)GetTickCount64(); }

double GetBid() { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double GetAsk() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double SpreadPts() { return (GetAsk() - GetBid()) / _Point; }

// Wall-clock ISO-8601 UTC, e.g. "2026-08-05T09:14:32.000Z" (human field only).
string IsoUtcNow()
{
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d.000Z",
                       d.year, d.mon, d.day, d.hour, d.min, d.sec);
}

// Trading-session bucket from the GMT hour (dashboard context).
string SessionFromGmt()
{
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   int h = d.hour;
   if(h >= 0  && h < 7)  return "ASIA";
   if(h >= 7  && h < 12) return "LONDON";
   if(h >= 12 && h < 16) return "LONDON_NY_OVERLAP";
   if(h >= 16 && h < 21) return "NY";
   return "ASIA";
}

// JSON string escaper.
string JsonEsc(string s)
{
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == '\\')      out += "\\\\";
      else if(c == '"')  out += "\\\"";
      else if(c == '\n') out += "\\n";
      else if(c == '\r') out += "\\r";
      else if(c == '\t') out += "\\t";
      else               out += ShortToString(c);
   }
   return out;
}

// Serialize a double as a JSON number (2dp) or "null" if inf/nan.
string JDbl(double v)
{
   if(!MathIsValidNumber(v)) return "null";
   return DoubleToString(v, 2);
}

// Broker-day boundary (server time, midnight-aligned).
datetime DayStart(datetime t) { return (datetime)(((long)t / 86400) * 86400); }

//=================== SESSION / ROLLOVER GATES =====================
bool ParseSession(string s, int &fromMin, int &toMin)
{
   int dash = StringFind(s, "-");
   if(dash < 0) return false;
   string a = StringSubstr(s, 0, dash);
   string b = StringSubstr(s, dash + 1);
   int ac = StringFind(a, ":");
   int bc = StringFind(b, ":");
   if(ac < 0 || bc < 0) return false;
   int ah = (int)StringToInteger(StringSubstr(a, 0, ac));
   int am = (int)StringToInteger(StringSubstr(a, ac + 1));
   int bh = (int)StringToInteger(StringSubstr(b, 0, bc));
   int bm = (int)StringToInteger(StringSubstr(b, bc + 1));
   fromMin = ah * 60 + am;
   toMin   = bh * 60 + bm;
   return true;
}

bool InOneSession(string s, int nowMin)
{
   if(StringLen(s) == 0) return false;
   int f, t;
   if(!ParseSession(s, f, t)) return false;
   if(f == t) return true;                    // degenerate → always on
   if(f < t)  return (nowMin >= f && nowMin < t);
   return (nowMin >= f || nowMin < t);        // wraps past midnight
}

// UTC session window (TimeGMT). Filter off → always true. Filter on with both
// windows blank → allow all (nothing configured).
bool InSessionWindow()
{
   if(!InpUseSessionFilter) return true;
   if(StringLen(InpSession1) == 0 && StringLen(InpSession2) == 0) return true;
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   int nowMin = d.hour * 60 + d.min;
   return InOneSession(InpSession1, nowMin) || InOneSession(InpSession2, nowMin);
}

// True within InpNoTradeMinsAroundRollover of broker midnight (server time).
bool InRolloverWindow()
{
   if(InpNoTradeMinsAroundRollover <= 0) return false;
   MqlDateTime d; TimeToStruct(TimeTradeServer(), d);
   int mins    = d.hour * 60 + d.min;
   int fromMid = mins;
   int toMid   = 1440 - mins;
   return (fromMid <= InpNoTradeMinsAroundRollover ||
           toMid   <= InpNoTradeMinsAroundRollover);
}

//=================== HISTORY READERS =============================
// Exit price of a closed position (the DEAL_ENTRY_OUT deal).
double ClosedExitPrice(ulong posid)
{
   for(int attempt = 0; attempt < 3; attempt++)
   {
      if(HistorySelectByPosition(posid))
      {
         int deals = HistoryDealsTotal();
         for(int i = deals - 1; i >= 0; i--)
         {
            ulong d = HistoryDealGetTicket(i);
            if(d == 0) continue;
            if(HistoryDealGetInteger(d, DEAL_POSITION_ID) != (long)posid) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
            return HistoryDealGetDouble(d, DEAL_PRICE);
         }
      }
   }
   return 0.0;
}

// Map the broker's close reason to our exit-reason enum. SL → TRAIL_STOP.
string ExitReasonFromHistory(ulong posid)
{
   if(HistorySelectByPosition(posid))
   {
      int deals = HistoryDealsTotal();
      for(int i = deals - 1; i >= 0; i--)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_POSITION_ID) != (long)posid) continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         ENUM_DEAL_REASON r = (ENUM_DEAL_REASON)HistoryDealGetInteger(d, DEAL_REASON);
         if(r == DEAL_REASON_SL) return "TRAIL_STOP";
         return "MANUAL";
      }
   }
   return "MANUAL";
}

// Realised money (currency) on a position, from its deal history.
double PositionNetMoney(ulong posid)
{
   if(posid == 0) return 0.0;
   double money = 0.0;
   if(HistorySelectByPosition(posid))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_POSITION_ID) != (long)posid) continue;
         money += HistoryDealGetDouble(d, DEAL_PROFIT)
                + HistoryDealGetDouble(d, DEAL_SWAP)
                + HistoryDealGetDouble(d, DEAL_COMMISSION);
      }
   }
   return money;
}

// Realised points of a closed leg from its own entry.
double ClosedLegPts(ulong posid, bool isBuy, double entry)
{
   double exit = ClosedExitPrice(posid);
   if(exit <= 0.0) return 0.0;
   return isBuy ? (exit - entry) / _Point : (entry - exit) / _Point;
}

//=================== ORDER PRIMITIVES ============================
// Close a specific ticket at market, retrying. No long sleeps (hot-path safe).
bool ForceCloseTicket(ulong ticket, string reason)
{
   if(ticket == 0) return true;
   if(!PositionSelectByTicket(ticket)) return true;   // already gone
   for(int i = 0; i < 3; i++)
   {
      if(trade.PositionClose(ticket))
      {
         PrintFormat("[BS] CLOSE ticket=%I64u reason=%s", ticket, reason);
         return true;
      }
      PrintFormat("[BS] close attempt %d failed on %I64u: %d (%s)",
                  i + 1, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   return false;
}

// Ultimate safety net: close every position carrying our magic on this symbol.
void CloseAllMagicPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pos = PositionGetTicket(i);
      if(pos == 0) continue;
      if(!PositionSelectByTicket(pos)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(trade.PositionClose(pos))
         PrintFormat("[BS] SAFETY CLOSE ticket=%I64u reason=%s", pos, reason);
   }
}

// Open one leg. Resolves the REAL position id from the deal (DEAL_POSITION_ID),
// falling back to ResultOrder only where they coincide, then verifies it can be
// selected before returning. Never passes a raw ResultOrder to the caller.
bool OpenLeg(bool isBuy, ulong &out_ticket, double &out_entry)
{
   string action = isBuy ? "BUY" : "SELL";
   for(int attempt = 0; attempt < 3; attempt++)
   {
      bool ok = isBuy ? trade.Buy(InpLots, _Symbol, 0, 0, 0, "straddle")
                      : trade.Sell(InpLots, _Symbol, 0, 0, 0, "straddle");
      if(!ok)
      {
         PrintFormat("[BS] %s open attempt %d failed: %d (%s)",
                     action, attempt + 1, trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
         continue;
      }

      ulong ticket = 0;
      ulong deal   = trade.ResultDeal();
      if(deal > 0 && HistoryDealSelect(deal))
         ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(ticket == 0)
         ticket = trade.ResultOrder();          // only where order==position id

      bool selectable = false;
      for(int k = 0; k < 5; k++)
      {
         if(PositionSelectByTicket(ticket)) { selectable = true; break; }
         Sleep(10);
      }
      if(!selectable)
      {
         PrintFormat("[BS] CRITICAL: cannot select %s position after open. deal=%I64u order=%I64u resolved=%I64u",
                     action, deal, trade.ResultOrder(), ticket);
         // sweep whatever just opened so it can't orphan, then retry the leg
         CloseAllMagicPositions("unselectable after open");
         continue;
      }

      double entry = trade.ResultPrice();
      if(entry <= 0.0)
         entry = isBuy ? GetAsk() : GetBid();

      out_ticket = ticket;
      out_entry  = entry;
      PrintFormat("[BS] OPEN %s ticket=%I64u lots=%.2f entry=%.*f",
                  action, ticket, InpLots, _Digits, entry);
      return true;
   }
   return false;
}

// Attach / modify the winner's server-side SL. Immediate retries (no sleep).
bool SetWinnerSL(double sl)
{
   for(int i = 0; i < 3; i++)
   {
      if(trade.PositionModify(g_winner_ticket, sl, 0.0)) return true;
   }
   PrintFormat("[BS] PositionModify SL failed on %I64u: %d (%s)",
               g_winner_ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return false;
}

// Clamp a desired stop to the broker's minimum stops-level distance from the
// current market. Logs the clamp once per cycle.
double ClampStop(bool isBuy, double sl)
{
   long   lvl     = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double mindist = (double)(lvl + 1) * _Point;
   if(isBuy)
   {
      double maxsl = GetBid() - mindist;           // SL must sit below bid by >= level
      if(sl > maxsl)
      {
         if(!g_stop_clamped)
            PrintFormat("[BS] SL clamped to stops-level (lvl=%I64d) — requested too close", lvl);
         g_stop_clamped = true;
         sl = maxsl;
      }
   }
   else
   {
      double minsl = GetAsk() + mindist;           // SL must sit above ask by >= level
      if(sl < minsl)
      {
         if(!g_stop_clamped)
            PrintFormat("[BS] SL clamped to stops-level (lvl=%I64d) — requested too close", lvl);
         g_stop_clamped = true;
         sl = minsl;
      }
   }
   return NormalizeDouble(sl, _Digits);
}

//=================== TELEMETRY ===================================
void TelemetryEnqueue(string ev)
{
   int n = ArraySize(g_tel_q);
   if(n >= TEL_QUEUE_CAP)
   {
      for(int i = 1; i < n; i++) g_tel_q[i - 1] = g_tel_q[i];
      g_tel_q[n - 1] = ev;
   }
   else
   {
      ArrayResize(g_tel_q, n + 1);
      g_tel_q[n] = ev;
   }
}

string BuildHeartbeatJson()
{
   string s = "{";
   s += "\"deployment_id\":\"" + JsonEsc(InpDeploymentId) + "\",";
   s += "\"ea_version\":\""     + EA_VERSION + "\",";
   s += "\"role\":\"STRADDLE\",";
   s += "\"broker\":\""         + JsonEsc(AccountInfoString(ACCOUNT_COMPANY)) + "\",";
   s += "\"symbol\":\""         + JsonEsc(_Symbol) + "\",";
   s += "\"login\":"            + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   s += "\"event_type\":\"heartbeat\",";
   s += "\"payload\":{\"ticks\":" + IntegerToString(g_ticks) +
        ",\"spread_pts\":" + JDbl(SpreadPts()) + "}";
   s += "}";
   return s;
}

// Build + enqueue the cycle event. No HTTP here (flush runs in OnTimer).
void EnqueueCycle(string reason, double winner_pts, double cut_pts,
                  double net_pts, double gross_pts, double net_money, bool win)
{
   if(!InpTelemetryEnabled) return;
   if(g_is_tester)          return;

   long   t_close     = NowMs();
   string uidbase     = (StringLen(InpDeploymentId) > 0) ? InpDeploymentId : "bs";
   string uid         = StringFormat("%s-%I64d", uidbase, g_cyc.t_signal);
   string winner_side = g_winner_is_buy ? "BUY" : "SELL";
   long   dur_ms      = t_close - g_cyc.t_signal;

   string p = "{";
   p += "\"cycle_uid\":\""            + JsonEsc(uid) + "\",";
   p += "\"direction\":\""            + winner_side + "\",";
   p += "\"winner\":\""               + winner_side + "\",";
   p += "\"t_signal\":"               + IntegerToString(g_cyc.t_signal) + ",";
   p += "\"t_close\":"                + IntegerToString(t_close) + ",";
   p += "\"opened_at\":\""            + JsonEsc(g_cyc.opened_at_iso) + "\",";
   p += "\"cycle_duration_ms\":"      + IntegerToString(dur_ms) + ",";
   p += "\"bar_range_pts\":"          + JDbl(g_cyc.bar_range_pts) + ",";
   p += "\"avg_range_pts\":"          + JDbl(g_cyc.avg_range_pts) + ",";
   p += "\"strength_mult\":"          + JDbl(g_cyc.strength_mult) + ",";
   p += "\"spread_pts_at_open\":"     + JDbl(g_cyc.spread_at_open) + ",";
   p += "\"b_spread_pts_at_signal\":" + JDbl(g_cyc.spread_at_open) + ",";
   p += "\"buy_entry_price\":"        + JDbl(g_cyc.buy_entry) + ",";
   p += "\"sell_entry_price\":"       + JDbl(g_cyc.sell_entry) + ",";
   p += "\"cut_leg_pts\":"            + JDbl(cut_pts) + ",";
   p += "\"trail_steps\":"            + IntegerToString(g_trail_steps) + ",";
   p += "\"exit_reason\":\""          + JsonEsc(reason) + "\",";
   p += "\"gross_pts\":"              + JDbl(gross_pts) + ",";
   p += "\"net_pts\":"                + JDbl(net_pts) + ",";
   p += "\"net_money\":"              + JDbl(net_money) + ",";
   p += "\"is_win\":"                 + (win ? "true" : "false") + ",";
   p += "\"session\":\""              + JsonEsc(g_cyc.session) + "\"";
   p += "}";

   string ev = "{";
   ev += "\"deployment_id\":\"" + JsonEsc(InpDeploymentId) + "\",";
   ev += "\"ea_version\":\""     + EA_VERSION + "\",";
   ev += "\"role\":\"STRADDLE\",";
   ev += "\"broker\":\""         + JsonEsc(AccountInfoString(ACCOUNT_COMPANY)) + "\",";
   ev += "\"symbol\":\""         + JsonEsc(_Symbol) + "\",";
   ev += "\"event_type\":\"cycle\",";
   ev += "\"payload\":"          + p;
   ev += "}";

   TelemetryEnqueue(ev);
   Print("[TEL] cycle enqueued: " + ev);
}

// The ONLY place WebRequest runs. Called from OnTimer. Never in the tester.
void TelemetryFlush()
{
   if(MQLInfoInteger(MQL_TESTER)) return;   // Task 9: no WebRequest in the tester
   if(!InpTelemetryEnabled)       return;
   int n = ArraySize(g_tel_q);
   if(n == 0) return;

   int batch = (n < TEL_BATCH_MAX) ? n : TEL_BATCH_MAX;
   string body = "{\"events\":[";
   for(int i = 0; i < batch; i++)
   {
      if(i > 0) body += ",";
      body += g_tel_q[i];
   }
   body += "]}";

   string headers = "Content-Type: application/json\r\n"
                    "Authorization: Bearer " + InpIngestKey + "\r\n";
   uchar data[];
   int dl = StringToCharArray(body, data, 0, -1, CP_UTF8) - 1;
   if(dl < 0) dl = 0;
   ArrayResize(data, dl);
   uchar  result[];
   string result_headers;
   ResetLastError();
   int res = WebRequest("POST", g_tel_url, headers, 1500, data, result, result_headers);

   if(res == 200)
   {
      int rem = n - batch;
      for(int i = 0; i < rem; i++) g_tel_q[i] = g_tel_q[i + batch];
      ArrayResize(g_tel_q, rem);
   }
   else if(res == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Print("[TEL] WebRequest not allowed. Add " + InpTelemetryUrl +
               " in Tools > Options > Expert Advisors.");
      else
         PrintFormat("[TEL] WebRequest failed err=%d — keeping %d events for retry", err, n);
   }
   else
   {
      PrintFormat("[TEL] HTTP %d — keeping %d events for retry", res, n);
   }
}

//=================== CYCLE LIFECYCLE ============================
void ResetCycleState()
{
   g_state         = ST_IDLE;
   g_buy_ticket    = 0;
   g_sell_ticket   = 0;
   g_buy_entry     = 0.0;
   g_sell_entry    = 0.0;
   g_winner_is_buy = false;
   g_winner_ticket = 0;
   g_winner_entry  = 0.0;
   g_cut_ref       = 0.0;
   g_winner_sl     = 0.0;
   g_trail_steps   = 0;
   g_stop_clamped  = false;
   g_cut_leg_pts   = 0.0;
}

// Single finalisation point: accounting, breakers, telemetry, reset.
// winner_pts = the surviving/best leg's realised pts; cut_pts = the losing
// leg's realised pts (negative). net_pts = winner_pts + cut_pts.
void FinishCycle(string reason, double winner_pts, double cut_pts)
{
   double net_pts   = winner_pts + cut_pts;
   double gross_pts = winner_pts;
   double net_money = PositionNetMoney(g_buy_ticket) + PositionNetMoney(g_sell_ticket);
   bool   win       = (net_pts > 0.0);

   g_tot_cycles++;   g_daily_cycles++;
   g_tot_net_pts += net_pts;
   g_daily_net_pts += net_pts;

   if(win)
   {
      g_tot_wins++;  g_daily_wins++;
      g_consec_losses = 0;
      if(net_pts > g_largest_win) g_largest_win = net_pts;
   }
   else
   {
      g_tot_losses++; g_daily_losses++;
      g_consec_losses++;
      if(net_pts < g_largest_loss) g_largest_loss = net_pts;
      if(g_consec_losses > g_max_consec) g_max_consec = g_consec_losses;
   }

   PrintFormat("[BS] CYCLE END reason=%s winner=%s winner_pts=%.1f cut_pts=%.1f net=%.1f money=%.2f %s  (streak=%d daily=%.1f)",
               reason, g_winner_is_buy ? "BUY" : "SELL", winner_pts, cut_pts,
               net_pts, net_money, win ? "WIN" : "LOSS", g_consec_losses, g_daily_net_pts);

   // Circuit breakers -------------------------------------------------------
   if(InpMaxConsecLosses > 0 && g_consec_losses >= InpMaxConsecLosses)
   {
      g_pause_until_ms = NowMs() + (long)InpPauseAfterStopMins * 60000;
      PrintFormat("[BS] CONSEC-LOSS BREAKER: %d losses in a row — pausing %d min",
                  g_consec_losses, InpPauseAfterStopMins);
      g_consec_losses = 0;   // reset the streak; the pause is the penalty
   }
   if(InpMaxDailyLossPts > 0.0 && (-g_daily_net_pts) >= InpMaxDailyLossPts)
   {
      g_daily_lock = true;
      PrintFormat("[BS] DAILY-LOSS BREAKER: %.1f pts down — no new cycles until next broker day",
                  -g_daily_net_pts);
   }

   EnqueueCycle(reason, winner_pts, cut_pts, net_pts, gross_pts, net_money, win);

   g_cycle_end_ms = NowMs();
   ResetCycleState();
}

// Promote the surviving leg to the winner if its partner vanished externally
// while both were open (broker stopout etc.) — never leave a naked, unstopped
// single leg. Attaches a mandatory server-side stop.
void PromoteSurvivor(bool buy_survives)
{
   double bid = GetBid();
   double ask = GetAsk();
   g_winner_is_buy = buy_survives;
   g_winner_ticket = buy_survives ? g_buy_ticket : g_sell_ticket;
   g_winner_entry  = buy_survives ? g_buy_entry  : g_sell_entry;
   g_cut_ref       = buy_survives ? bid : ask;
   g_trail_steps   = 0;
   g_stop_clamped  = false;

   // the vanished leg's realised loss
   bool lost_is_buy = !buy_survives;
   ulong lost = buy_survives ? g_sell_ticket : g_buy_ticket;
   double lost_entry = buy_survives ? g_sell_entry : g_buy_entry;
   g_cut_leg_pts = ClosedLegPts(lost, lost_is_buy, lost_entry);

   double sl = buy_survives ? (g_cut_ref - InpInitialSlPts * _Point)
                            : (g_cut_ref + InpInitialSlPts * _Point);
   sl = ClampStop(buy_survives, sl);
   if(!SetWinnerSL(sl))
   {
      PrintFormat("[BS] cannot protect promoted survivor %I64u — closing it", g_winner_ticket);
      ForceCloseTicket(g_winner_ticket, "no SL on survivor");
      double wpts = ClosedLegPts(g_winner_ticket, buy_survives, g_winner_entry);
      FinishCycle("MANUAL", wpts, g_cut_leg_pts);
      return;
   }
   g_winner_sl = sl;
   g_state     = ST_RUNNING;
   PrintFormat("[BS] survivor promoted to RUNNING %s (partner vanished) SL=%.*f",
               buy_survives ? "BUY" : "SELL", _Digits, sl);
}

// Cut the losing leg once the winner is InpCutPts in profit.
void CutLoser(bool buy_won)
{
   double bid = GetBid();
   double ask = GetAsk();
   ulong  loser  = buy_won ? g_sell_ticket : g_buy_ticket;
   ulong  winner = buy_won ? g_buy_ticket  : g_sell_ticket;

   bool closed = false;
   for(int i = 0; i < 3; i++)
   {
      if(trade.PositionClose(loser)) { closed = true; break; }
      PrintFormat("[BS] cut attempt %d failed on loser %I64u: %d (%s)",
                  i + 1, loser, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   if(!closed)
   {
      // Never leave an unmanaged hedge — close BOTH legs and end the cycle.
      PrintFormat("[BS] CUT FAILED 3x — closing both legs and ending cycle");
      ForceCloseTicket(winner, "cut failed, closing both");
      ForceCloseTicket(loser,  "cut failed, closing both");
      double bpts = ClosedLegPts(g_buy_ticket,  true,  g_buy_entry);
      double spts = ClosedLegPts(g_sell_ticket, false, g_sell_entry);
      g_winner_is_buy = (bpts >= spts);
      FinishCycle("MANUAL", MathMax(bpts, spts), MathMin(bpts, spts));
      return;
   }

   // realised loss of the cut leg (the cost of discovering direction)
   bool loser_is_buy = !buy_won;
   double loser_entry = buy_won ? g_sell_entry : g_buy_entry;
   g_cut_leg_pts = ClosedLegPts(loser, loser_is_buy, loser_entry);

   // set up the winner
   g_winner_is_buy = buy_won;
   g_winner_ticket = winner;
   g_winner_entry  = buy_won ? g_buy_entry : g_sell_entry;
   g_cut_ref       = buy_won ? bid : ask;    // winner's market exit price at the cut
   g_trail_steps   = 0;
   g_stop_clamped  = false;

   PrintFormat("[BS] CUT loser=%s cut_leg_pts=%.1f — winner=%s now RUNNING (cut_ref=%.*f)",
               loser_is_buy ? "BUY" : "SELL", g_cut_leg_pts,
               buy_won ? "BUY" : "SELL", _Digits, g_cut_ref);

   // Mandatory server-side initial stop, InpInitialSlPts from the cut point.
   double sl = buy_won ? (g_cut_ref - InpInitialSlPts * _Point)
                       : (g_cut_ref + InpInitialSlPts * _Point);
   sl = ClampStop(buy_won, sl);
   if(!SetWinnerSL(sl))
   {
      PrintFormat("[BS] ABORT: no SL could be attached to winner %I64u — closing it", winner);
      ForceCloseTicket(winner, "no SL on winner");
      double wpts = ClosedLegPts(winner, buy_won, g_winner_entry);
      FinishCycle("MANUAL", wpts, g_cut_leg_pts);
      return;
   }
   g_winner_sl = sl;
   g_state     = ST_RUNNING;
   PrintFormat("[BS] winner SL set at %.*f (initial %.0f pts from cut)",
               _Digits, sl, InpInitialSlPts);
}

// Ratchet the winner's stop favourably. Only ever moves in the winning
// direction, and only calls PositionModify when the stop actually changes.
void UpdateTrailingStop()
{
   double bid = GetBid();
   double ask = GetAsk();
   if(g_winner_is_buy)
   {
      double advance = (bid - g_cut_ref) / _Point;
      int    steps   = (advance > 0.0) ? (int)MathFloor(advance / InpTrailStepPts) : 0;
      if(steps > g_trail_steps) g_trail_steps = steps;
      double desired = g_cut_ref - InpInitialSlPts * _Point + steps * InpTrailStepPts * _Point;
      desired = ClampStop(true, desired);
      if(desired > g_winner_sl + _Point * 0.5)          // strictly higher → favourable
         if(SetWinnerSL(desired)) g_winner_sl = desired;
   }
   else
   {
      double advance = (g_cut_ref - ask) / _Point;
      int    steps   = (advance > 0.0) ? (int)MathFloor(advance / InpTrailStepPts) : 0;
      if(steps > g_trail_steps) g_trail_steps = steps;
      double desired = g_cut_ref + InpInitialSlPts * _Point - steps * InpTrailStepPts * _Point;
      desired = ClampStop(false, desired);
      if(desired < g_winner_sl - _Point * 0.5)          // strictly lower → favourable
         if(SetWinnerSL(desired)) g_winner_sl = desired;
   }
}

// Force-close whatever is open (InpMaxHoldSec timeout).
void ForceCloseCycle(string reason)
{
   if(g_state == ST_BOTH_OPEN)
   {
      ForceCloseTicket(g_buy_ticket,  reason);
      ForceCloseTicket(g_sell_ticket, reason);
      double bpts = ClosedLegPts(g_buy_ticket,  true,  g_buy_entry);
      double spts = ClosedLegPts(g_sell_ticket, false, g_sell_entry);
      g_winner_is_buy = (bpts >= spts);
      FinishCycle(reason, MathMax(bpts, spts), MathMin(bpts, spts));
   }
   else if(g_state == ST_RUNNING)
   {
      ForceCloseTicket(g_winner_ticket, reason);
      double wpts = ClosedLegPts(g_winner_ticket, g_winner_is_buy, g_winner_entry);
      FinishCycle(reason, wpts, g_cut_leg_pts);
   }
}

// Winner is gone (its server-side stop fired, or it was closed manually).
void FinalizeWinnerClosed()
{
   double wpts   = ClosedLegPts(g_winner_ticket, g_winner_is_buy, g_winner_entry);
   string reason = ExitReasonFromHistory(g_winner_ticket);
   FinishCycle(reason, wpts, g_cut_leg_pts);
}

// Both legs vanished externally while open — finalise from history.
void FinalizeBothVanished()
{
   double bpts = ClosedLegPts(g_buy_ticket,  true,  g_buy_entry);
   double spts = ClosedLegPts(g_sell_ticket, false, g_sell_entry);
   g_winner_is_buy = (bpts >= spts);
   FinishCycle("MANUAL", MathMax(bpts, spts), MathMin(bpts, spts));
}

// Progress an open cycle. Runs every tick (cutting/trailing must not depend on
// OnTimer). No network here.
void ManageCycle()
{
   if(g_state == ST_IDLE) return;

   // Max-hold backstop
   if((NowMs() - g_cycle_open_ms) >= (long)InpMaxHoldSec * 1000)
   {
      ForceCloseCycle("TIMEOUT");
      return;
   }

   if(g_state == ST_BOTH_OPEN)
   {
      bool buy_ok  = PositionSelectByTicket(g_buy_ticket);
      bool sell_ok = PositionSelectByTicket(g_sell_ticket);
      if(!buy_ok && !sell_ok) { FinalizeBothVanished(); return; }
      if(!buy_ok)             { PromoteSurvivor(false); return; }   // buy gone → sell survives
      if(!sell_ok)            { PromoteSurvivor(true);  return; }   // sell gone → buy survives

      double bid = GetBid();
      double ask = GetAsk();
      double buy_pts  = (bid - g_buy_entry)  / _Point;
      double sell_pts = (g_sell_entry - ask) / _Point;
      if(buy_pts >= InpCutPts)       CutLoser(true);
      else if(sell_pts >= InpCutPts) CutLoser(false);
      return;
   }

   if(g_state == ST_RUNNING)
   {
      if(!PositionSelectByTicket(g_winner_ticket)) { FinalizeWinnerClosed(); return; }
      UpdateTrailingStop();
      return;
   }
}

//=================== ENTRY ======================================
bool CanOpenNewCycle()
{
   if(g_state != ST_IDLE) return false;
   long now = NowMs();
   if(now - g_cycle_end_ms < (long)InpCooldownSec * 1000) return false;   // cooldown
   if(g_daily_lock) return false;
   if(g_pause_until_ms > 0)
   {
      if(now < g_pause_until_ms) return false;
      g_pause_until_ms = 0;      // pause elapsed → resume
   }
   if(InRolloverWindow()) return false;
   if(!InSessionWindow()) return false;
   return true;
}

// Optional ADX filter on the just-closed bar.
bool PassesAdx()
{
   if(!InpUseAdx) return true;
   if(g_adx_handle == INVALID_HANDLE) return true;   // handle unavailable → don't block
   double buf[];
   if(CopyBuffer(g_adx_handle, 0, 1, 1, buf) < 1) return true;
   return (buf[0] >= InpAdxMin);
}

// Optional tick-volume filter on the just-closed bar vs its average.
bool PassesVolume()
{
   if(!InpUseTickVolume) return true;
   long vol[];
   int need = InpRangeLookback + 2;
   if(CopyTickVolume(_Symbol, InpBarTF, 0, need, vol) < need) return true;
   ArraySetAsSeries(vol, true);
   double avg = 0.0;
   for(int i = 1; i <= InpRangeLookback; i++) avg += (double)vol[i];
   avg /= InpRangeLookback;
   if(avg <= 0.0) return true;
   return ((double)vol[1] >= InpVolumeMult * avg);
}

// Open the straddle: BUY then SELL, same lot. If SELL fails, close BUY.
void OpenStraddle(double range1, double avg)
{
   double spread = SpreadPts();
   if(spread > InpMaxSpreadPts)          // re-read the LIVE spread before sending
   {
      PrintFormat("[BS] entry skipped — spread=%.1f > max=%.1f", spread, InpMaxSpreadPts);
      return;
   }

   // stage telemetry context
   ResetCtx(g_cyc);
   g_cyc.t_signal      = NowMs();
   g_cyc.opened_at_iso = IsoUtcNow();
   g_cyc.session       = SessionFromGmt();
   g_cyc.bar_range_pts = range1;
   g_cyc.avg_range_pts = avg;
   g_cyc.strength_mult = (avg > 0.0) ? range1 / avg : 0.0;
   g_cyc.spread_at_open= spread;

   ulong  bt = 0; double bentry = 0.0;
   if(!OpenLeg(true, bt, bentry))
   {
      PrintFormat("[BS] BUY leg failed 3x — aborting cycle (no naked leg opened)");
      CloseAllMagicPositions("buy leg failed");
      return;
   }

   ulong  st = 0; double sentry = 0.0;
   if(!OpenLeg(false, st, sentry))
   {
      PrintFormat("[BS] SELL leg failed 3x — closing BUY leg immediately (never run one naked leg)");
      if(!ForceCloseTicket(bt, "entry leg2 failed"))
         CloseAllMagicPositions("entry leg2 failed, close-1 failed");
      return;
   }

   g_buy_ticket  = bt;  g_buy_entry  = bentry;
   g_sell_ticket = st;  g_sell_entry = sentry;
   g_cyc.buy_entry  = bentry;
   g_cyc.sell_entry = sentry;

   g_state         = ST_BOTH_OPEN;
   g_cycle_open_ms = NowMs();
   g_trail_steps   = 0;
   g_winner_sl     = 0.0;
   g_stop_clamped  = false;

   PrintFormat("[BS] STRADDLE OPEN  range=%.1f avg=%.1f (%.2fx)  BUY %.*f / SELL %.*f  spread=%.1f",
               range1, avg, g_cyc.strength_mult, _Digits, bentry, _Digits, sentry, spread);
}

// Called once per closed bar. Updates the panel figures, and — when flat and
// unblocked — opens a straddle on a strong bar.
void OnNewBar()
{
   int need = InpRangeLookback + 2;
   double high[], low[];
   if(CopyHigh(_Symbol, InpBarTF, 0, need, high) < need) return;
   if(CopyLow(_Symbol,  InpBarTF, 0, need, low)  < need) return;
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);

   double range1 = (high[1] - low[1]) / _Point;   // the just-closed bar (index 1)
   double sum = 0.0;
   for(int i = 1; i <= InpRangeLookback; i++) sum += (high[i] - low[i]) / _Point;
   double avg = sum / InpRangeLookback;

   g_last_bar_range = range1;
   g_last_avg_range = avg;

   if(avg <= 0.0) return;                          // no baseline yet
   bool strong = (range1 >= InpStrengthMult * avg);
   if(!strong) return;
   if(!PassesAdx() || !PassesVolume()) return;
   if(!CanOpenNewCycle()) return;

   OpenStraddle(range1, avg);
}

//=================== BROKER-DAY ROLLOVER =========================
void CheckBrokerDay()
{
   datetime day = DayStart(TimeTradeServer());
   if(g_broker_day == 0) { g_broker_day = day; return; }
   if(day != g_broker_day)
   {
      g_broker_day    = day;
      g_daily_net_pts = 0.0;
      g_daily_cycles  = 0;
      g_daily_wins    = 0;
      g_daily_losses  = 0;
      g_daily_lock    = false;
      Print("[BS] New broker day — daily counters and daily-loss lock reset");
   }
}

//=================== PANEL (object-based) ========================
void PanelEnsureBackdrop()
{
   string bg = PANEL_PREFIX + "bg";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX - 6);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY - 6);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 470);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 220);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, (color)C'18,20,26');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, (color)C'60,64,74');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   }
}

void PanelSetLine(int idx, string text, color clr)
{
   string name = PANEL_PREFIX + "L" + (string)idx;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpPanelFont);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY + idx * (InpPanelFont + 6));
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void PanelHideFrom(int idx)
{
   for(int i = idx; i < PANEL_MAX_LINES; i++)
   {
      string name = PANEL_PREFIX + "L" + (string)i;
      if(ObjectFind(0, name) >= 0) ObjectSetString(0, name, OBJPROP_TEXT, " ");
   }
}

void PanelDeinit()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
}

string FmtDur(long ms)
{
   long s = ms / 1000;
   if(s < 0) s = 0;
   if(s < 60) return StringFormat("%ds", (int)s);
   return StringFormat("%dm %02ds", (int)(s / 60), (int)(s % 60));
}

void PanelRender()
{
   PanelEnsureBackdrop();
   int i = 0;
   long now = NowMs();

   PanelSetLine(i++, StringFormat("AURUM Breakout Straddle v1.0   [ %s ]", _Symbol), clrWhite);
   PanelSetLine(i++, "-----------------------------------------------", (color)C'90,94,104');

   if(g_state == ST_IDLE)
   {
      string st; color stc;
      if(g_daily_lock)                                        { st = "DAILY LOSS LOCK";        stc = clrOrangeRed; }
      else if(g_pause_until_ms > 0 && now < g_pause_until_ms) { st = "PAUSED (consec losses)"; stc = clrOrangeRed; }
      else if(InRolloverWindow())                            { st = "ROLLOVER - no trading";   stc = clrGold; }
      else if(now - g_cycle_end_ms < (long)InpCooldownSec*1000){ st = "COOLDOWN";              stc = clrGold; }
      else if(InpUseSessionFilter && !InSessionWindow())     { st = "OUT OF SESSION";          stc = clrGold; }
      else                                                   { st = "WAITING FOR STRONG BAR";  stc = clrAqua; }
      PanelSetLine(i++, "state: " + st, stc);

      double ratio = (g_last_avg_range > 0.0) ? g_last_bar_range / g_last_avg_range : 0.0;
      color rc = (ratio >= InpStrengthMult) ? clrLime : clrSilver;
      PanelSetLine(i++, StringFormat("last bar range %.0f pts / avg %.0f pts  (%.2fx, need %.2fx)",
                        g_last_bar_range, g_last_avg_range, ratio, InpStrengthMult), rc);

      double sp = SpreadPts();
      PanelSetLine(i++, StringFormat("spread %.1f pts   (max %.1f)", sp, InpMaxSpreadPts),
                        (sp > InpMaxSpreadPts) ? clrOrangeRed : clrSilver);
   }
   else
   {
      long age = now - g_cycle_open_ms;
      if(g_state == ST_BOTH_OPEN)
      {
         PanelSetLine(i++, "state: BOTH OPEN", clrAqua);
         double bid = GetBid(), ask = GetAsk();
         double bpts = (bid - g_buy_entry) / _Point;
         double spts = (g_sell_entry - ask) / _Point;
         PanelSetLine(i++, StringFormat("BUY  %+.1f pts     SELL %+.1f pts   (cut at %.0f)",
                           bpts, spts, InpCutPts), clrSilver);
         PanelSetLine(i++, StringFormat("cycle age %s", FmtDur(age)), clrSilver);
      }
      else // ST_RUNNING
      {
         string side = g_winner_is_buy ? "BUY" : "SELL";
         PanelSetLine(i++, "state: RUNNING " + side, clrLime);
         double bid = GetBid(), ask = GetAsk();
         double wpts = g_winner_is_buy ? (bid - g_winner_entry) / _Point
                                       : (g_winner_entry - ask) / _Point;
         PanelSetLine(i++, StringFormat("winner %+.1f pts   stop %.*f   steps %d",
                           wpts, _Digits, g_winner_sl, g_trail_steps),
                           (wpts >= 0) ? clrLime : clrOrangeRed);
         PanelSetLine(i++, StringFormat("cycle age %s", FmtDur(age)), clrSilver);
      }
   }

   // Always-on accounting lines
   color netc = (g_daily_net_pts >= 0) ? clrLime : clrOrangeRed;
   PanelSetLine(i++, StringFormat("today: %d cycles   %dW %dL   net %+.0f pts",
                     g_daily_cycles, g_daily_wins, g_daily_losses, g_daily_net_pts), netc);

   string dl = (InpMaxDailyLossPts > 0.0)
      ? StringFormat("%.0f / %.0f", -g_daily_net_pts, InpMaxDailyLossPts)
      : "off";
   PanelSetLine(i++, StringFormat("streak: %d losses   daily loss %s",
                     g_consec_losses, dl), clrSilver);

   // Breaker detail lines with time remaining
   if(g_pause_until_ms > 0 && now < g_pause_until_ms)
      PanelSetLine(i++, StringFormat("  >> paused: resumes in %s", FmtDur(g_pause_until_ms - now)), clrOrangeRed);
   if(g_daily_lock)
      PanelSetLine(i++, "  >> daily lock: resumes next broker day", clrOrangeRed);

   PanelHideFrom(i);
   ObjectSetInteger(0, PANEL_PREFIX + "bg", OBJPROP_YSIZE, i * (InpPanelFont + 6) + 14);
}

//=================== LIFECYCLE ==================================
int OnInit()
{
   g_is_tester = (bool)MQLInfoInteger(MQL_TESTER);

   // --- Task 2: the account MUST be HEDGING. On netting, BUY+SELL net to flat
   //     and the whole strategy silently does nothing. ---
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
      != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("========================================================");
      Print("[BS] FATAL: account is NOT in HEDGING mode.");
      Print("[BS] The straddle needs simultaneous BUY+SELL positions.");
      Print("[BS] On a netting account they cancel to flat and nothing trades.");
      Print("[BS] Use an MT5 HEDGING account. Refusing to run.");
      Print("========================================================");
      return(INIT_FAILED);
   }

   // --- Task 1: validate inputs ---
   if(InpStrengthMult < 1.0)
   {
      PrintFormat("[BS] FATAL: InpStrengthMult=%.2f must be >= 1.0", InpStrengthMult);
      return(INIT_FAILED);
   }
   if(InpCutPts <= 0.0)
   {
      PrintFormat("[BS] FATAL: InpCutPts=%.1f must be > 0", InpCutPts);
      return(INIT_FAILED);
   }
   if(InpTrailStepPts <= 0.0)
   {
      PrintFormat("[BS] FATAL: InpTrailStepPts=%.1f must be > 0", InpTrailStepPts);
      return(INIT_FAILED);
   }
   if(InpRangeLookback < 1)
   {
      PrintFormat("[BS] FATAL: InpRangeLookback=%d must be >= 1", InpRangeLookback);
      return(INIT_FAILED);
   }

   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpLots < vmin || InpLots > vmax)
   {
      PrintFormat("[BS] FATAL: InpLots=%.4f outside broker range [%.4f, %.4f]",
                  InpLots, vmin, vmax);
      return(INIT_FAILED);
   }
   if(vstep > 0.0)
   {
      double steps = InpLots / vstep;
      if(MathAbs(steps - MathRound(steps)) > 1e-6)
      {
         PrintFormat("[BS] FATAL: InpLots=%.4f is not a multiple of the volume step %.4f",
                     InpLots, vstep);
         return(INIT_FAILED);
      }
   }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints((ulong)(InpMaxSpreadPts + 50.0));

   // Optional ADX handle
   if(InpUseAdx)
   {
      g_adx_handle = iADX(_Symbol, InpBarTF, InpAdxPeriod);
      if(g_adx_handle == INVALID_HANDLE)
         PrintFormat("[BS] WARNING: ADX handle failed err=%d — ADX filter disabled", GetLastError());
   }

   // Telemetry endpoint = base URL + /api/events
   g_tel_url = InpTelemetryUrl;
   int plen = StringLen(TEL_ENDPOINT_PATH);
   if(StringLen(g_tel_url) < plen ||
      StringSubstr(g_tel_url, StringLen(g_tel_url) - plen) != TEL_ENDPOINT_PATH)
   {
      if(StringLen(g_tel_url) > 0 && StringGetCharacter(g_tel_url, StringLen(g_tel_url) - 1) == '/')
         g_tel_url = StringSubstr(g_tel_url, 0, StringLen(g_tel_url) - 1);
      g_tel_url += TEL_ENDPOINT_PATH;
   }

   ArrayResize(g_tel_q, 0);
   g_tel_last_hb_ms    = 0;
   g_tel_last_flush_ms = NowMs();

   g_broker_day    = DayStart(TimeTradeServer());
   g_last_bar_time = iTime(_Symbol, InpBarTF, 0);   // don't fire on the current forming bar
   ResetCycleState();
   ResetCtx(g_cyc);

   EventSetTimer(1);

   PrintFormat("[BS] AURUM Breakout Straddle V1 started. symbol=%s broker=%s lots=%.2f strength=%.2fx trail=%.0f",
               _Symbol, AccountInfoString(ACCOUNT_COMPANY), InpLots, InpStrengthMult, InpTrailStepPts);
   if(InpTelemetryEnabled && !g_is_tester)
      PrintFormat("[BS] Telemetry ON deployment=%s url=%s (add the base URL to WebRequest allowlist)",
                  InpDeploymentId, g_tel_url);
   if(g_is_tester)
      Print("[BS] Strategy Tester detected — WebRequest disabled, panel best-effort.");

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   g_ticks++;

   CheckBrokerDay();

   // Progress any open cycle first (cut / trail / timeout) — every tick.
   ManageCycle();

   // Evaluate entry on bar close only.
   datetime bt = iTime(_Symbol, InpBarTF, 0);
   if(bt != g_last_bar_time)
   {
      g_last_bar_time = bt;
      OnNewBar();
   }
}

void OnTimer()
{
   // Telemetry (never in the tester). WebRequest happens ONLY here.
   if(!g_is_tester && InpTelemetryEnabled)
   {
      long tnow = NowMs();
      if(g_tel_last_hb_ms == 0 || (tnow - g_tel_last_hb_ms) >= (long)HEARTBEAT_SEC * 1000)
      {
         TelemetryEnqueue(BuildHeartbeatJson());
         g_tel_last_hb_ms = tnow;
      }
      if((tnow - g_tel_last_flush_ms) >= (long)TEL_FLUSH_SEC * 1000)
      {
         TelemetryFlush();
         g_tel_last_flush_ms = tnow;
      }
   }

   PanelRender();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_adx_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_adx_handle);
      g_adx_handle = INVALID_HANDLE;
   }
   PanelDeinit();
   Comment("");

   Print("========================================================");
   Print("[BS] AURUM Breakout Straddle V1 — session summary");
   PrintFormat("[BS]   cycles:            %d", g_tot_cycles);
   PrintFormat("[BS]   wins / losses:     %d / %d", g_tot_wins, g_tot_losses);
   PrintFormat("[BS]   net points:        %+.1f", g_tot_net_pts);
   PrintFormat("[BS]   max consec losses: %d", g_max_consec);
   PrintFormat("[BS]   largest win:       %+.1f pts", g_largest_win);
   PrintFormat("[BS]   largest loss:      %+.1f pts", g_largest_loss);
   Print("========================================================");
}
//+------------------------------------------------------------------+
