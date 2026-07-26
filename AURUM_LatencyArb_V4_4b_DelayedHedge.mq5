//+------------------------------------------------------------------+
//|                 AURUM_LatencyArb_V4_4b_DelayedHedge.mq5          |
//|                                                 AURUM TECH / Por |
//|                                                                  |
//|  Delayed Hedge Strategy with Fast Feed Lead-Lag Arbitrage        |
//|                                                                  |
//|  KEY IMPROVEMENT vs V4.4:                                        |
//|    Spread cost was NOT accounted for in original hedge design.   |
//|    2 spreads x 40 pts = 80 pts loss on open+close hedge.         |
//|    Solution: Delayed Hedge — open one leg first, wait for        |
//|    profit above spread + margin, then hedge to lock guaranteed   |
//|    minimum profit.                                                |
//|                                                                  |
//|  Trade Cycle (V4.4b flow):                                       |
//|    1. V4.3 consensus fires → determine direction (UP/DOWN)       |
//|    2. Open single leg (BUY if UP, SELL if DOWN) + initial SL     |
//|    3. Wait for leg profit >= HedgeTriggerPts                      |
//|       (auto-adapted to current spread + guarantee margin)        |
//|    4. Open opposite hedge leg → +MinLockGuarantee locked ⭐      |
//|    5. Detect A peak (or trough) → close winning leg high (low)   |
//|    6. Detect A trough (or peak) → close losing leg improved      |
//|    7. Loop back to Phase 1                                       |
//|                                                                  |
//|  Profit breakdown:                                               |
//|    - Locked component: +InpMinLockGuarantee (fixed after hedge)  |
//|    - Variable component: +A_bounce_distance                      |
//|    - Worst case: +LockGuarantee (breakeven+)                     |
//|    - Best case: unbounded upside                                 |
//|                                                                  |
//|  Auto-Adapt Spread:                                              |
//|    Real-time HedgeTrigger = MAX(baseline, spread + guarantee)    |
//|    Prevents loss during news / rollover / wide spread events     |
//|                                                                  |
//|  Safety Layers:                                                  |
//|    - Initial SL 100 pts on single-leg phase                      |
//|    - No SL after hedge (locked profit protects)                  |
//|    - Emergency exit if net floating loss exceeds InpEmergencySlPts|
//|    - Max cycle time                                              |
//|    - Spread guard skips extreme conditions                       |
//|                                                                  |
//|  Requires:                                                       |
//|    - MT5 HEDGING mode at B (GOC Prime)                           |
//|    - 4 terminals on same VPS (3 A watchers + 1 B executor)       |
//+------------------------------------------------------------------+
#property copyright "AURUM TECH"
#property version   "1.41"
#property strict
#property description "Latency arb V4.4b - Delayed Hedge with Auto-adapt Spread"
#property description "Open single leg first, hedge only after profit exceeds spread cost"

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

input group "=== Delayed Hedge Setup (V4.4b core) ==="
input double         InpHedgeTriggerPts     = 50.0;    // Leg profit must reach this before opening hedge
                                                       // (Baseline; will auto-adapt to spread)
input double         InpMinLockGuarantee    = 10.0;    // Minimum locked profit after hedge (safety margin above spread)
input bool           InpAutoAdaptSpread     = true;    // Real-time adjust: trigger = MAX(baseline, spread + guarantee)
input double         InpMaxSpreadPts        = 55.0;    // Spread guard — skip signal if spread exceeds this
input int            InpExecCooldownMs      = 500;     // Cooldown between execution attempts

input group "=== A Peak Detection (close winning leg high) ==="
input double         InpAPeakDropPts      = 10.0;    // A drops this many pts from peak → close BUY (or add trigger for SELL)
input int            InpAPeakConfirmCount = 2;       // # of A brokers that must confirm (of 3)
input int            InpAPeakSustainMs    = 100;     // Drop must persist this long

input group "=== A Trough Detection (close losing leg / SELL winning ) ==="
input double         InpATroughBouncePts  = 8.0;     // A bounces this many pts from trough → close SELL (or reverse)
input int            InpATroughConfirmCount = 2;     // # of A brokers that must confirm (of 3)
input int            InpATroughSustainMs  = 100;     // Bounce must persist this long

input group "=== Safety Layers ==="
input double         InpInitialSlPts      = 100.0;   // SL on single-leg phase (before hedge)
input int            InpMaxCycleMs        = 15000;   // Max total cycle time — force close all
input double         InpEmergencySlPts    = 150.0;   // Force close if net floating loss exceeds
input int            InpMinLegHoldMs      = 200;     // Min time before allowing leg close (avoid instant close)
input bool           InpAutoRetryAfterExit = true;   // After full close, wait for next V4.3 signal automatically

input group "=== Tick Logger ==="
input string         InpFilePrefix        = "ticklog_arb_v44b";
input bool           InpUseCommonDir      = true;
input int            InpFlushEvery        = 200;
input bool           InpShowHeartbeat     = true;
input int            InpFreezeAlertMs     = 2000;
input int            InpBigSpreadPts      = 100;

// NOTE: keep this group LAST so existing .set files stay aligned.
input group "=== Telemetry (dashboard) ==="
input bool   InpTelemetryEnabled  = true;
input string InpDeploymentId      = "tm-guze-01";   // must match on both A and B
input string InpTelemetryUrl      = "https://aurum-trading-dashboard.vercel.app/api/events";
input string InpIngestKey         = "ZcAoWOoOHX9ZwgPeTRMLab4VeImFTvIu";
input string InpVpsHost           = "154.44.149.224";
input int    InpVpsPort           = 13389;
input int    InpHeartbeatSec      = 30;
input int    InpTelemetryFlushSec = 5;
input int    InpLagTimeoutMs      = 3000;

//=================== CONSTANTS =====================================
#define MAGIC              20260732
#define EA_VERSION         "4.4b"
#define TEL_QUEUE_CAP      200
#define TEL_BATCH_MAX      20
#define A_STALE_RELAY_MS   300000   // stop relaying A heartbeat after 5 min stale
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

// B — HEDGE position tracking (V4.4b: 2-phase — single leg → hedge)
enum ENUM_CYCLE_STATE
{
   CYCLE_IDLE           = 0,  // waiting for consensus signal
   CYCLE_SINGLE_LEG     = 1,  // single leg open (BUY or SELL), waiting for hedge trigger
   CYCLE_HEDGE_OPEN     = 2,  // both legs open (+MinLockGuarantee locked)
   CYCLE_WINNER_CLOSED  = 3,  // winning leg realized, waiting for A signal on loser
   CYCLE_FORCED_EXIT    = 4,  // emergency close both
};
ENUM_CYCLE_STATE g_cycle_state = CYCLE_IDLE;

// Direction of trade cycle
string g_cycle_direction = "";  // "UP" or "DOWN" — determines which leg is winner
                                // UP: BUY = winner, SELL = loser (hedge)
                                // DOWN: SELL = winner, BUY = loser (hedge)

// BUY leg tracking
bool     g_buy_open          = false;
ulong    g_buy_ticket        = 0;
double   g_buy_entry_price   = 0.0;
double   g_buy_sl_price      = 0.0;
long     g_buy_open_msc      = 0;
double   g_buy_realized_pts  = 0.0;
long     g_buy_close_msc     = 0;

// SELL leg tracking
bool     g_sell_open         = false;
ulong    g_sell_ticket       = 0;
double   g_sell_entry_price  = 0.0;
double   g_sell_sl_price     = 0.0;
long     g_sell_open_msc     = 0;
double   g_sell_realized_pts = 0.0;
long     g_sell_close_msc    = 0;

// Cycle-level tracking
long     g_cycle_start_msc   = 0;
long     g_cycle_count       = 0;
long     g_cycle_win_count   = 0;
long     g_cycle_loss_count  = 0;
double   g_cumulative_pts    = 0.0;
double   g_effective_hedge_trigger_pts = 0.0;   // ⭐ auto-adapted trigger (real-time)
string   g_last_close_reason = "";

// A PEAK tracking (used to close BUY winner or trigger reversal for SELL)
double   g_a_peak_1 = -DBL_MAX, g_a_peak_2 = -DBL_MAX, g_a_peak_3 = -DBL_MAX;
long     g_a_peak_1_msc = 0, g_a_peak_2_msc = 0, g_a_peak_3_msc = 0;
long     g_a_peak_drop_start_msc = 0;

// A TROUGH tracking (used to close SELL winner or trigger reversal for BUY)
double   g_a_trough_1 = DBL_MAX, g_a_trough_2 = DBL_MAX, g_a_trough_3 = DBL_MAX;
long     g_a_trough_1_msc = 0, g_a_trough_2_msc = 0, g_a_trough_3_msc = 0;
long     g_a_trough_bounce_start_msc = 0;

// Legacy (for compatibility)
bool     g_b_pos_open        = false;
string   g_b_pos_action      = "";
ulong    g_b_pos_ticket      = 0;
double   g_b_pos_entry_price = 0.0;
double   g_b_pos_sl_price    = 0.0;
double   g_b_pos_tp_price    = 0.0;
bool     g_b_pos_tp_armed    = false;
long     g_b_pos_open_msc    = 0;
string   g_b_last_close_reason = "";
double   g_b_pos_entry_delta = 0.0;

// ADX + volume handles/state (B only)
double   g_b_last_adx        = 0.0;
double   g_b_last_vol_ratio  = 0.0;
int      g_adx_handle        = INVALID_HANDLE;

// Telegram summary tracking
long     g_last_summary_msc          = 0;
long     g_ticks_at_last_summary     = 0;
long     g_b_hb_updates              = 0;
long     g_b_hb_updates_last_summary = 0;
long     g_b_hb_last_msc_seen        = 0;

//=================== TELEMETRY / OBSERVABILITY (V4.4b) =============
// Extended A-heartbeat cache (columns 6-9 of the CSV — identity fields).
// Filled by ReadHeartbeatFromFile; "" / 0 when reading an old 5-column file.
double   g_a1_spread = 0.0;  string g_a1_broker = "";  long g_a1_login = 0;  string g_a1_symbol = "";  long g_a1_tick = 0;
double   g_a2_spread = 0.0;  string g_a2_broker = "";  long g_a2_login = 0;  string g_a2_symbol = "";  long g_a2_tick = 0;
double   g_a3_spread = 0.0;  string g_a3_broker = "";  long g_a3_login = 0;  string g_a3_symbol = "";  long g_a3_tick = 0;

// B: ATR(M1,14) handle for b_atr_m1_pts (created once in OnInit)
int      g_atr_handle = INVALID_HANDLE;

// B: telemetry queue (JSON event strings). Ring buffer, cap TEL_QUEUE_CAP.
string   g_tel_q[];
long     g_tel_last_hb_ms    = 0;   // last heartbeat enqueue (NowMs)
long     g_tel_last_flush_ms = 0;   // last flush attempt (NowMs)

// B: ab_lag measurement (one shot per cycle). measured=false => JSON null.
bool     g_lag_active   = false;    // measurement window open
bool     g_lag_measured = false;    // reached target before timeout
bool     g_lag_is_buy   = false;    // B chases up (buy) or down (sell)
double   g_lag_target   = 0.0;      // a_mid B must reach
long     g_lag_t_a      = 0;        // A's stamped timestamp at signal (GetTickCount64 of A)
long     g_lag_start_ms = 0;        // NowMs at signal (timeout base)
long     g_lag_ms       = 0;        // measured t_b - t_a

// B: per-cycle telemetry — captured from signal fire through close
struct CycleTelemetry
{
   bool   active;
   long   t_signal;
   string direction;                // BUY | SELL (first leg)
   double a_delta_pts;
   int    a_brokers_agreed;
   double a_price_at_signal;
   double b_price_at_signal;
   double b_spread_pts_at_signal;
   string opened_at_iso;
   string session;
   double b_atr_m1_pts;
   // leg1
   long   t_leg1_fill;
   ulong  leg1_ticket;
   double leg1_expected_price;
   double leg1_actual_price;
   double leg1_slippage_pts;
   double hedge_trigger_pts_used;
   // hedge
   bool   hedge_opened;
   long   t_hedge_fill;
   ulong  hedge_ticket;
   double hedge_expected_price;
   double hedge_actual_price;
   double hedge_slippage_pts;
   double locked_profit_pts;
   // close
   long   t_close;
   string exit_reason;
   string final_state;
   double gross_pts;
   double net_pts;
   double net_money;
};
CycleTelemetry g_cyc;

void ResetCycleTelemetry()
{
   g_cyc.active                 = false;
   g_cyc.t_signal               = 0;
   g_cyc.direction              = "";
   g_cyc.a_delta_pts            = 0.0;
   g_cyc.a_brokers_agreed       = 0;
   g_cyc.a_price_at_signal      = 0.0;
   g_cyc.b_price_at_signal      = 0.0;
   g_cyc.b_spread_pts_at_signal = 0.0;
   g_cyc.opened_at_iso          = "";
   g_cyc.session                = "";
   g_cyc.b_atr_m1_pts           = 0.0;
   g_cyc.t_leg1_fill            = 0;
   g_cyc.leg1_ticket            = 0;
   g_cyc.leg1_expected_price    = 0.0;
   g_cyc.leg1_actual_price      = 0.0;
   g_cyc.leg1_slippage_pts      = 0.0;
   g_cyc.hedge_trigger_pts_used = 0.0;
   g_cyc.hedge_opened           = false;
   g_cyc.t_hedge_fill           = 0;
   g_cyc.hedge_ticket           = 0;
   g_cyc.hedge_expected_price   = 0.0;
   g_cyc.hedge_actual_price     = 0.0;
   g_cyc.hedge_slippage_pts     = 0.0;
   g_cyc.locked_profit_pts      = 0.0;
   g_cyc.t_close                = 0;
   g_cyc.exit_reason            = "";
   g_cyc.final_state            = "";
   g_cyc.gross_pts              = 0.0;
   g_cyc.net_pts                = 0.0;
   g_cyc.net_money              = 0.0;
}

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

// Monotonic ms since system boot. Same clock on every terminal on this VPS,
// so A and B timestamps are directly comparable. This is the ONLY clock used
// for latency, cooldowns, ages and durations.
long NowMs()
{
   return (long)GetTickCount64();
}

// Wall-clock, ISO 8601 UTC, e.g. "2026-07-27T09:14:32.000Z".
// Used ONLY for the human-readable opened_at field sent to the DB — never for
// latency/duration math (that is NowMs()).
string IsoUtcNow()
{
   datetime t = TimeGMT();
   MqlDateTime d; TimeToStruct(t, d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d.000Z",
                       d.year, d.mon, d.day, d.hour, d.min, d.sec);
}

// Trading session bucket from GMT hour (dashboard context field).
string SessionFromGmt()
{
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   int h = d.hour;
   if(h >= 0  && h < 7)  return "ASIA";
   if(h >= 7  && h < 12) return "LONDON";
   if(h >= 12 && h < 16) return "LONDON_NY_OVERLAP";
   if(h >= 16 && h < 21) return "NY";
   return "ASIA";  // 21-24
}

// B's ATR(M1,14) in points. 0.0 if handle/data not ready.
double CurrentAtrM1Pts()
{
   if(g_atr_handle == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, buf) < 1) return 0.0;
   if(!MathIsValidNumber(buf[0])) return 0.0;
   return buf[0] / _Point;
}

// JSON string escaper (handles the chars that would break a JSON string).
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

// Serialize a double as a JSON number (2 dp), or "null" if inf/nan.
string JDbl(double v)
{
   if(!MathIsValidNumber(v)) return "null";
   return DoubleToString(v, 2);
}

// Net money (account currency) realized on a position, from deal history.
double PositionNetMoney(ulong ticket)
{
   if(ticket == 0) return 0.0;
   double money = 0.0;
   if(HistorySelectByPosition(ticket))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0) continue;
         if(HistoryDealGetInteger(dt, DEAL_POSITION_ID) != (long)ticket) continue;
         money += HistoryDealGetDouble(dt, DEAL_PROFIT)
                + HistoryDealGetDouble(dt, DEAL_SWAP)
                + HistoryDealGetDouble(dt, DEAL_COMMISSION);
      }
   }
   return money;
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
// CSV columns (9): now_ms, bid, ask, digits, spread_pts, broker, login, symbol, tick_count
// The last 4 are appended so B can relay A's identity to the dashboard. broker
// is Sanitize()d so a comma in the company name cannot break the CSV.
bool WriteHeartbeatToFile(string fname, double bid, double ask)
{
   int flags = FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE;
   int h = FileOpen(fname, flags, ',');
   if(h == INVALID_HANDLE) return(false);
   double spread_pts = (ask - bid) / _Point;
   string broker = Sanitize(AccountInfoString(ACCOUNT_COMPANY));
   long   login  = AccountInfoInteger(ACCOUNT_LOGIN);
   FileWrite(h,
      (string)NowMs(),
      DoubleToString(bid, _Digits), DoubleToString(ask, _Digits),
      (string)_Digits, DoubleToString(spread_pts, 1),
      broker, (string)login, _Symbol, (string)g_count);
   FileFlush(h); FileClose(h);
   return(true);
}

// Reads the 9-column heartbeat. Tolerates the old 5-column format: the extra
// out params come back "" / 0 and the call still succeeds (no error).
bool ReadHeartbeatFromFile(string fname, long &out_msc, double &out_bid, double &out_ask,
                           double &out_spread, string &out_broker, long &out_login,
                           string &out_symbol, long &out_tick)
{
   int flags = FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE;
   int h = FileOpen(fname, flags, ',');
   if(h == INVALID_HANDLE) return(false);
   string s_msc    = FileReadString(h);   // 1
   string s_bid    = FileReadString(h);   // 2
   string s_ask    = FileReadString(h);   // 3
   string s_digits = FileReadString(h);   // 4 (consumed, not needed)
   string s_spread = FileReadString(h);   // 5
   string s_broker = FileReadString(h);   // 6 (new)
   string s_login  = FileReadString(h);   // 7 (new)
   string s_symbol = FileReadString(h);   // 8 (new)
   string s_tick   = FileReadString(h);   // 9 (new)
   FileClose(h);
   if(StringLen(s_msc) == 0 || StringLen(s_bid) == 0) return(false);
   out_msc    = StringToInteger(s_msc);
   out_bid    = StringToDouble(s_bid);
   out_ask    = StringToDouble(s_ask);
   out_spread = (StringLen(s_spread) > 0) ? StringToDouble(s_spread) : (out_ask - out_bid) / _Point;
   out_broker = s_broker;                                                // "" on old format
   out_login  = (StringLen(s_login) > 0) ? StringToInteger(s_login) : 0; // 0  on old format
   out_symbol = s_symbol;                                                // "" on old format
   out_tick   = (StringLen(s_tick)  > 0) ? StringToInteger(s_tick)  : 0; // 0  on old format
   return(true);
}

//+------------------------------------------------------------------+
//| B: open + close position                                          |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Open a single leg (BUY or SELL) with immediate SL                 |
//| Returns ticket on success, 0 on failure                           |
//| Sets entry_price_out to actual fill price                         |
//+------------------------------------------------------------------+
ulong OpenLeg(string action, double lots, double sl_pts, double &entry_price_out,
              double &sl_price_out, double &expected_price_out)
{
   entry_price_out = 0;
   sl_price_out = 0;

   double point = _Point;
   int digits = _Digits;

   // Expected fill = the price we would pay/receive at market, captured the
   // instant BEFORE the order is sent (basis for leg1/hedge slippage).
   expected_price_out = (action == ACTION_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Send MARKET order WITHOUT SL first
   bool ok = false;
   if(action == ACTION_BUY)
      ok = trade.Buy(lots, _Symbol, 0, 0, 0, "gold sport EA V4.4b");
   else if(action == ACTION_SELL)
      ok = trade.Sell(lots, _Symbol, 0, 0, 0, "gold sport EA V4.4b");

   if(!ok)
   {
      PrintFormat("[B] %s open failed: %d (%s)", action,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return 0;
   }

   ulong ticket = trade.ResultOrder();
   double actual_entry = trade.ResultPrice();
   if(actual_entry <= 0)
   {
      actual_entry = (action == ACTION_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }

   double sl_price = (action == ACTION_BUY)
      ? NormalizeDouble(actual_entry - sl_pts * point, digits)
      : NormalizeDouble(actual_entry + sl_pts * point, digits);

   if(!trade.PositionModify(ticket, sl_price, 0))
   {
      PrintFormat("[B] Failed to set SL on ticket %I64u: %d (%s)",
                  ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   entry_price_out = actual_entry;
   sl_price_out = sl_price;
   return ticket;
}

//+------------------------------------------------------------------+
//| Open HEDGE — both BUY and SELL at market                          |
//| V4.4 core: hedge locked as starting position                      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| V4.4b: Compute effective hedge trigger (auto-adapt to spread)     |
//+------------------------------------------------------------------+
double ComputeEffectiveHedgeTrigger()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread_pts = (ask - bid) / _Point;

   if(!InpAutoAdaptSpread)
      return InpHedgeTriggerPts;

   double adaptive = spread_pts + InpMinLockGuarantee;
   return MathMax(InpHedgeTriggerPts, adaptive);
}

//+------------------------------------------------------------------+
//| V4.4b: Get current profit of leg in pts (uses close-price basis)  |
//+------------------------------------------------------------------+
double LegProfitPts(bool is_open, string action, double entry_price)
{
   if(!is_open) return 0.0;
   double point = _Point;
   if(action == ACTION_BUY)
      return (SymbolInfoDouble(_Symbol, SYMBOL_BID) - entry_price) / point;
   else
      return (entry_price - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / point;
}

//+------------------------------------------------------------------+
//| V4.4b: Open SINGLE LEG (BUY or SELL) — Phase 1                    |
//+------------------------------------------------------------------+
void OpenSingleLeg(string direction, double lots)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = _Point;
   double current_spread_pts = (ask - bid) / point;

   // Spread guard — skip signal if spread too wide
   if(current_spread_pts > InpMaxSpreadPts)
   {
      g_skip_spread++;
      PrintFormat("[B] SINGLE LEG SKIPPED — spread=%.0f > MaxSpread=%.0f",
                  current_spread_pts, InpMaxSpreadPts);
      return;
   }

   long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(InpInitialSlPts <= current_spread_pts + stops_level)
   {
      PrintFormat("[B] SINGLE LEG SKIPPED — SlPts=%.0f <= spread(%.0f)+stops(%I64d)",
                  InpInitialSlPts, current_spread_pts, stops_level);
      return;
   }

   // Determine which leg to open based on direction
   string first_action = (direction == "UP") ? ACTION_BUY : ACTION_SELL;

   double entry = 0, sl = 0, expected = 0;
   ulong ticket = OpenLeg(first_action, lots, InpInitialSlPts, entry, sl, expected);
   if(ticket == 0)
   {
      PrintFormat("[B] SINGLE LEG FAILED at %s", first_action);
      return;
   }

   long now = NowMs();

   // --- Telemetry: leg1 fill (signed slippage = disadvantage direction) ---
   g_cyc.t_leg1_fill         = now;
   g_cyc.leg1_ticket         = ticket;
   g_cyc.leg1_expected_price = expected;
   g_cyc.leg1_actual_price   = entry;
   g_cyc.leg1_slippage_pts   = (first_action == ACTION_BUY)
                               ? (entry - expected) / _Point   // paid more = worse
                               : (expected - entry) / _Point;  // sold lower = worse
   g_cyc.active = true;   // real trade opened → this cycle will emit telemetry

   // Open the ab_lag measurement window (timeout from t_signal).
   g_lag_active   = true;
   g_lag_measured = false;
   g_lag_ms       = 0;
   g_lag_start_ms = g_cyc.t_signal;

   // Record which leg
   if(first_action == ACTION_BUY)
   {
      g_buy_open        = true;
      g_buy_ticket      = ticket;
      g_buy_entry_price = entry;
      g_buy_sl_price    = sl;
      g_buy_open_msc    = now;
      g_buy_realized_pts = 0.0;
      g_buy_close_msc = 0;
   }
   else
   {
      g_sell_open        = true;
      g_sell_ticket      = ticket;
      g_sell_entry_price = entry;
      g_sell_sl_price    = sl;
      g_sell_open_msc    = now;
      g_sell_realized_pts = 0.0;
      g_sell_close_msc = 0;
   }

   g_cycle_state       = CYCLE_SINGLE_LEG;
   g_cycle_direction   = direction;
   g_cycle_start_msc   = now;
   g_b_pos_open        = true;
   g_b_pos_open_msc    = now;
   g_b_exec_count++;

   // Compute and store effective hedge trigger for this cycle
   g_effective_hedge_trigger_pts = ComputeEffectiveHedgeTrigger();
   g_cyc.hedge_trigger_pts_used  = g_effective_hedge_trigger_pts;

   ResetPeakTroughTracking();

   int digits = _Digits;
   PrintFormat("[B] SINGLE LEG OPEN %s@%.*f SL=%.*f  spread=%.1f  hedgeTrigger=%.1f pts",
               first_action, digits, entry, digits, sl,
               current_spread_pts, g_effective_hedge_trigger_pts);

   TG_OrderOpen(first_action + " (initial)", AccountInfoString(ACCOUNT_COMPANY), _Symbol,
                lots, entry, digits, ticket);
}

//+------------------------------------------------------------------+
//| V4.4b: Add hedge leg (opposite direction) — Phase 3                |
//| Called when single leg profit >= effective_hedge_trigger           |
//+------------------------------------------------------------------+
void AddHedgeLeg(double lots)
{
   string hedge_action = (g_cycle_direction == "UP") ? ACTION_SELL : ACTION_BUY;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = _Point;
   double current_spread_pts = (ask - bid) / point;

   // Open hedge leg WITHOUT SL (locked profit protects)
   // Pass 0 SL to skip modify — or use very wide SL as backstop
   double entry = 0, sl = 0, expected = 0;
   ulong ticket = OpenLeg(hedge_action, lots, 500.0, entry, sl, expected);   // 500 pts backstop SL
   if(ticket == 0)
   {
      PrintFormat("[B] HEDGE LEG FAILED — %s could not open", hedge_action);
      // Keep single leg open — will exit on A signal or SL
      return;
   }

   long now = NowMs();
   int digits = _Digits;

   // --- Telemetry: hedge fill + locked profit of leg1 at this instant ---
   bool leg1_is_buy = (g_cycle_direction == "UP");   // leg1 = winner leg
   g_cyc.hedge_opened         = true;
   g_cyc.t_hedge_fill         = now;
   g_cyc.hedge_ticket         = ticket;
   g_cyc.hedge_expected_price = expected;
   g_cyc.hedge_actual_price   = entry;
   g_cyc.hedge_slippage_pts   = (hedge_action == ACTION_BUY)
                                ? (entry - expected) / _Point
                                : (expected - entry) / _Point;
   g_cyc.locked_profit_pts    = leg1_is_buy
                                ? LegProfitPts(g_buy_open,  ACTION_BUY,  g_buy_entry_price)
                                : LegProfitPts(g_sell_open, ACTION_SELL, g_sell_entry_price);

   if(hedge_action == ACTION_BUY)
   {
      g_buy_open        = true;
      g_buy_ticket      = ticket;
      g_buy_entry_price = entry;
      g_buy_sl_price    = sl;
      g_buy_open_msc    = now;
      g_buy_realized_pts = 0.0;

      // Remove SL from SELL winner (locked profit protects)
      trade.PositionModify(g_sell_ticket, 0, 0);
      g_sell_sl_price = 0;
   }
   else
   {
      g_sell_open        = true;
      g_sell_ticket      = ticket;
      g_sell_entry_price = entry;
      g_sell_sl_price    = sl;
      g_sell_open_msc    = now;
      g_sell_realized_pts = 0.0;

      // Remove SL from BUY winner
      trade.PositionModify(g_buy_ticket, 0, 0);
      g_buy_sl_price = 0;
   }

   g_cycle_state = CYCLE_HEDGE_OPEN;

   double locked_pts = (g_sell_entry_price - g_buy_entry_price) / point;
   PrintFormat("[B] HEDGE ADDED %s@%.*f  locked=%+.1f pts  spread=%.1f  original SLs removed",
               hedge_action, digits, entry, locked_pts, current_spread_pts);

   TG_OrderOpen(hedge_action + " (hedge)", AccountInfoString(ACCOUNT_COMPANY), _Symbol,
                lots, entry, digits, ticket);
}

// Legacy wrapper — no longer used but kept for compatibility
void OpenHedge(double lots)
{
   // V4.4b: this is now replaced by OpenSingleLeg + AddHedgeLeg
   // Kept as no-op to preserve function signature
}

//+------------------------------------------------------------------+
//| Reset A peak/trough tracking (call at cycle start)                |
//+------------------------------------------------------------------+
void ResetPeakTroughTracking()
{
   g_a_peak_1 = -DBL_MAX;   g_a_peak_2 = -DBL_MAX;   g_a_peak_3 = -DBL_MAX;
   g_a_peak_1_msc = 0;      g_a_peak_2_msc = 0;      g_a_peak_3_msc = 0;
   g_a_peak_drop_start_msc = 0;

   g_a_trough_1 = DBL_MAX;  g_a_trough_2 = DBL_MAX;  g_a_trough_3 = DBL_MAX;
   g_a_trough_1_msc = 0;    g_a_trough_2_msc = 0;    g_a_trough_3_msc = 0;
   g_a_trough_bounce_start_msc = 0;
}

//+------------------------------------------------------------------+
//| Close a specific leg — returns realized pts                       |
//+------------------------------------------------------------------+
double CloseLeg(ulong ticket, string action, double entry_price, string reason)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;

   double point = _Point;
   double exit_price = 0.0;
   double pnl_pts = 0.0;

   if(action == ACTION_BUY)
      exit_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      exit_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(!trade.PositionClose(ticket))
   {
      PrintFormat("[B] Failed to close %s ticket=%I64u: %d (%s)",
                  action, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return 0.0;
   }

   // Use actual exit from ResultPrice if available
   double actual_exit = trade.ResultPrice();
   if(actual_exit > 0) exit_price = actual_exit;

   if(action == ACTION_BUY)
      pnl_pts = (exit_price - entry_price) / point;
   else
      pnl_pts = (entry_price - exit_price) / point;

   int digits = _Digits;
   PrintFormat("[B] CLOSE %s @%.*f  pnl=%+.1f pts  reason=%s  ticket=%I64u",
               action, digits, exit_price, pnl_pts, reason, ticket);
   TG_OrderClose(action, reason, pnl_pts, NowMs() - g_cycle_start_msc, ticket);

   return pnl_pts;
}

//+------------------------------------------------------------------+
//| Force-close entire cycle (both legs if still open)                |
//+------------------------------------------------------------------+
void CloseCycle(string reason)
{
   int digits = _Digits;
   double point = _Point;
   double net_pts = g_buy_realized_pts + g_sell_realized_pts;
   ENUM_CYCLE_STATE prev_state = g_cycle_state;   // for telemetry final_state

   if(g_buy_open)
   {
      double pts = CloseLeg(g_buy_ticket, ACTION_BUY, g_buy_entry_price, reason);
      g_buy_realized_pts = pts;
      net_pts += pts;
      g_buy_open = false;
      g_buy_close_msc = NowMs();
   }
   if(g_sell_open)
   {
      double pts = CloseLeg(g_sell_ticket, ACTION_SELL, g_sell_entry_price, reason);
      g_sell_realized_pts = pts;
      net_pts += pts;
      g_sell_open = false;
      g_sell_close_msc = NowMs();
   }

   g_cumulative_pts += net_pts;
   g_cycle_count++;
   if(net_pts > 0) g_cycle_win_count++;
   else            g_cycle_loss_count++;

   long duration = NowMs() - g_cycle_start_msc;
   PrintFormat("[B] CYCLE END #%I64d  reason=%s  buy=%+.1f sell=%+.1f  NET=%+.1f pts  duration=%I64d ms  cumulative=%+.1f",
               g_cycle_count, reason, g_buy_realized_pts, g_sell_realized_pts,
               net_pts, duration, g_cumulative_pts);

   // --- Telemetry: forced close (timeout / emergency) ---
   string tel_exit = (reason == "CYCLE_TIMEOUT") ? "TIMEOUT"
                   : (reason == "EMERGENCY_SL")  ? "EMERGENCY_SL"
                   : reason;
   string tel_state = (prev_state == CYCLE_HEDGE_OPEN)    ? "HEDGE_OPEN"
                    : (prev_state == CYCLE_WINNER_CLOSED) ? "WINNER_CLOSED"
                    : "SINGLE_LEG";
   FinalizeCycleTelemetry(tel_exit, tel_state, net_pts);

   g_cycle_state = CYCLE_IDLE;
   g_b_pos_open = false;
   g_b_last_close_reason = reason;
   g_last_close_reason = reason;
}

//+------------------------------------------------------------------+
//| Update A peak/trough state from current heartbeats                |
//| Called every tick during CYCLE_HEDGE_OPEN or CYCLE_BUY_CLOSED     |
//+------------------------------------------------------------------+
void UpdateAPeakTrough(bool a1_active, bool a2_active, bool a3_active)
{
   long now = NowMs();

   // Track PEAKS (use bid for BUY exit = we want to close BUY at highest B bid)
   if(a1_active)
   {
      double a1_mid = (g_a1_bid + g_a1_ask) * 0.5;
      if(a1_mid > g_a_peak_1) { g_a_peak_1 = a1_mid; g_a_peak_1_msc = now; }
      if(a1_mid < g_a_trough_1) { g_a_trough_1 = a1_mid; g_a_trough_1_msc = now; }
   }
   if(a2_active)
   {
      double a2_mid = (g_a2_bid + g_a2_ask) * 0.5;
      if(a2_mid > g_a_peak_2) { g_a_peak_2 = a2_mid; g_a_peak_2_msc = now; }
      if(a2_mid < g_a_trough_2) { g_a_trough_2 = a2_mid; g_a_trough_2_msc = now; }
   }
   if(a3_active)
   {
      double a3_mid = (g_a3_bid + g_a3_ask) * 0.5;
      if(a3_mid > g_a_peak_3) { g_a_peak_3 = a3_mid; g_a_peak_3_msc = now; }
      if(a3_mid < g_a_trough_3) { g_a_trough_3 = a3_mid; g_a_trough_3_msc = now; }
   }
}

//+------------------------------------------------------------------+
//| Detect A peak — how many A brokers dropped by threshold           |
//+------------------------------------------------------------------+
int CountAPeakDrops(bool a1_active, bool a2_active, bool a3_active, double drop_pts)
{
   double point = _Point;
   int count = 0;
   if(a1_active && g_a_peak_1 > -DBL_MAX)
   {
      double a1_mid = (g_a1_bid + g_a1_ask) * 0.5;
      if((g_a_peak_1 - a1_mid) / point >= drop_pts) count++;
   }
   if(a2_active && g_a_peak_2 > -DBL_MAX)
   {
      double a2_mid = (g_a2_bid + g_a2_ask) * 0.5;
      if((g_a_peak_2 - a2_mid) / point >= drop_pts) count++;
   }
   if(a3_active && g_a_peak_3 > -DBL_MAX)
   {
      double a3_mid = (g_a3_bid + g_a3_ask) * 0.5;
      if((g_a_peak_3 - a3_mid) / point >= drop_pts) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Detect A trough — how many A brokers bounced by threshold         |
//+------------------------------------------------------------------+
int CountATroughBounces(bool a1_active, bool a2_active, bool a3_active, double bounce_pts)
{
   double point = _Point;
   int count = 0;
   if(a1_active && g_a_trough_1 < DBL_MAX)
   {
      double a1_mid = (g_a1_bid + g_a1_ask) * 0.5;
      if((a1_mid - g_a_trough_1) / point >= bounce_pts) count++;
   }
   if(a2_active && g_a_trough_2 < DBL_MAX)
   {
      double a2_mid = (g_a2_bid + g_a2_ask) * 0.5;
      if((a2_mid - g_a_trough_2) / point >= bounce_pts) count++;
   }
   if(a3_active && g_a_trough_3 < DBL_MAX)
   {
      double a3_mid = (g_a3_bid + g_a3_ask) * 0.5;
      if((a3_mid - g_a_trough_3) / point >= bounce_pts) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get current floating pnl in pts for a leg                         |
//+------------------------------------------------------------------+
double LegFloatingPts(bool is_open, string action, double entry_price)
{
   if(!is_open) return 0.0;
   double point = _Point;
   if(action == ACTION_BUY)
      return (SymbolInfoDouble(_Symbol, SYMBOL_BID) - entry_price) / point;
   else
      return (entry_price - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / point;
}

//+------------------------------------------------------------------+
//| Check if a leg was closed by broker (SL hit)                      |
//| Returns true if closed, sets realized_pts + reason                |
//+------------------------------------------------------------------+
bool CheckLegBrokerClose(ulong ticket, string action, double entry_price,
                        double &realized_pts, string &reason)
{
   if(PositionSelectByTicket(ticket)) return false;   // still open

   // Position closed by broker — find deal in history
   reason = "BROKER_CLOSE";
   realized_pts = 0.0;

   if(HistorySelectByPosition(ticket))
   {
      int deals = HistoryDealsTotal();
      for(int i = deals - 1; i >= 0; i--)
      {
         ulong deal_ticket = HistoryDealGetTicket(i);
         if(deal_ticket == 0) continue;
         if(HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) != (long)ticket) continue;
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT) continue;

         ENUM_DEAL_REASON deal_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
         if(deal_reason == DEAL_REASON_SL)       reason = "SL_HIT";
         else if(deal_reason == DEAL_REASON_TP)  reason = "TP_HIT";
         else if(deal_reason == DEAL_REASON_SO)  reason = "STOPOUT";
         else if(deal_reason == DEAL_REASON_EXPERT) reason = "EA_CLOSE";
         else reason = StringFormat("REASON_%d", (int)deal_reason);

         double exit_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         if(action == ACTION_BUY)
            realized_pts = (exit_price - entry_price) / _Point;
         else
            realized_pts = (entry_price - exit_price) / _Point;
         break;
      }
   }
   return true;
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
//| B: monitor hedge cycle — detect A peak/trough, close legs         |
//| V4.4 CORE LOGIC                                                   |
//+------------------------------------------------------------------+
void MonitorHedgeCycle()
{
   if(g_cycle_state == CYCLE_IDLE) return;

   long now = NowMs();

   // ------- Handle broker-side closes first (SL hit on either leg) -------
   if(g_buy_open)
   {
      double pts; string reason;
      if(CheckLegBrokerClose(g_buy_ticket, ACTION_BUY, g_buy_entry_price, pts, reason))
      {
         g_buy_open = false;
         g_buy_realized_pts = pts;
         g_buy_close_msc = now;
         PrintFormat("[B] BUY leg auto-closed by broker: %s  pnl=%+.1f pts", reason, pts);
         TG_OrderClose(ACTION_BUY, reason, pts, now - g_buy_open_msc, g_buy_ticket);
      }
   }
   if(g_sell_open)
   {
      double pts; string reason;
      if(CheckLegBrokerClose(g_sell_ticket, ACTION_SELL, g_sell_entry_price, pts, reason))
      {
         g_sell_open = false;
         g_sell_realized_pts = pts;
         g_sell_close_msc = now;
         PrintFormat("[B] SELL leg auto-closed by broker: %s  pnl=%+.1f pts", reason, pts);
         TG_OrderClose(ACTION_SELL, reason, pts, now - g_sell_open_msc, g_sell_ticket);
      }
   }

   // If both legs closed by broker → end cycle
   if(!g_buy_open && !g_sell_open)
   {
      double net = g_buy_realized_pts + g_sell_realized_pts;
      g_cumulative_pts += net;
      g_cycle_count++;
      if(net > 0) g_cycle_win_count++; else g_cycle_loss_count++;
      PrintFormat("[B] CYCLE END #%I64d (all broker-closed)  NET=%+.1f pts",
                  g_cycle_count, net);
      // --- Telemetry: both legs closed by broker (SL hit on single-leg phase) ---
      FinalizeCycleTelemetry("INITIAL_SL", g_cyc.hedge_opened ? "HEDGE_OPEN" : "SINGLE_LEG", net);
      g_cycle_state = CYCLE_IDLE;
      g_b_pos_open = false;
      return;
   }

   // ------- Read fresh A heartbeats -------
   g_a1_ok = ReadHeartbeatFromFile(HB_FILE_A1, g_a1_msc, g_a1_bid, g_a1_ask,
                                   g_a1_spread, g_a1_broker, g_a1_login, g_a1_symbol, g_a1_tick);
   g_a2_ok = ReadHeartbeatFromFile(HB_FILE_A2, g_a2_msc, g_a2_bid, g_a2_ask,
                                   g_a2_spread, g_a2_broker, g_a2_login, g_a2_symbol, g_a2_tick);
   g_a3_ok = ReadHeartbeatFromFile(HB_FILE_A3, g_a3_msc, g_a3_bid, g_a3_ask,
                                   g_a3_spread, g_a3_broker, g_a3_login, g_a3_symbol, g_a3_tick);

   long age1 = now - g_a1_msc, age2 = now - g_a2_msc, age3 = now - g_a3_msc;
   bool a1_active = g_a1_ok && age1 >= 0 && age1 <= InpMaxHeartbeatAgeMs;
   bool a2_active = g_a2_ok && age2 >= 0 && age2 <= InpMaxHeartbeatAgeMs;
   bool a3_active = g_a3_ok && age3 >= 0 && age3 <= InpMaxHeartbeatAgeMs;

   UpdateAPeakTrough(a1_active, a2_active, a3_active);

   // ------- Safety check: cycle timeout -------
   long cycle_age = now - g_cycle_start_msc;
   if(cycle_age >= InpMaxCycleMs)
   {
      CloseCycle("CYCLE_TIMEOUT");
      return;
   }

   // ------- Safety check: emergency net loss (all states) -------
   double buy_float = LegFloatingPts(g_buy_open, ACTION_BUY, g_buy_entry_price);
   double sell_float = LegFloatingPts(g_sell_open, ACTION_SELL, g_sell_entry_price);
   double net_floating = g_buy_realized_pts + g_sell_realized_pts + buy_float + sell_float;
   if(net_floating <= -InpEmergencySlPts)
   {
      PrintFormat("[B] EMERGENCY EXIT — net floating %.1f <= -%.1f", net_floating, InpEmergencySlPts);
      CloseCycle("EMERGENCY_SL");
      return;
   }

   // ==================================================================
   // STATE: CYCLE_SINGLE_LEG — waiting for profit to reach hedge trigger
   // ==================================================================
   if(g_cycle_state == CYCLE_SINGLE_LEG)
   {
      bool is_buy = (g_cycle_direction == "UP");
      double leg_profit = is_buy
         ? LegProfitPts(g_buy_open, ACTION_BUY, g_buy_entry_price)
         : LegProfitPts(g_sell_open, ACTION_SELL, g_sell_entry_price);

      // Check A signal — if A reverses before hitting hedge trigger,
      // close single leg at current profit (positive or small negative)
      if(is_buy && g_buy_open && (now - g_buy_open_msc) >= InpMinLegHoldMs)
      {
         int drops = CountAPeakDrops(a1_active, a2_active, a3_active, InpAPeakDropPts);
         if(drops >= InpAPeakConfirmCount)
         {
            if(g_a_peak_drop_start_msc == 0)
               g_a_peak_drop_start_msc = now;
            if((now - g_a_peak_drop_start_msc) >= InpAPeakSustainMs)
            {
               // A peaked — close BUY at whatever profit (take small win or breakeven)
               double pts = CloseLeg(g_buy_ticket, ACTION_BUY, g_buy_entry_price,
                                     "A_PEAK_EARLY_EXIT");
               g_buy_open = false;
               g_buy_realized_pts = pts;
               g_buy_close_msc = now;

               // Cycle complete (single leg only, no hedge)
               double net = pts;
               g_cumulative_pts += net;
               g_cycle_count++;
               if(net > 0) g_cycle_win_count++; else g_cycle_loss_count++;
               PrintFormat("[B] CYCLE END #%I64d (single-leg early exit)  BUY=%+.1f  NET=%+.1f",
                           g_cycle_count, pts, net);
               FinalizeCycleTelemetry("A_PEAK", "SINGLE_LEG", net);
               g_cycle_state = CYCLE_IDLE;
               g_b_pos_open = false;
               return;
            }
         }
         else
         {
            g_a_peak_drop_start_msc = 0;
         }
      }
      else if(!is_buy && g_sell_open && (now - g_sell_open_msc) >= InpMinLegHoldMs)
      {
         int bounces = CountATroughBounces(a1_active, a2_active, a3_active, InpATroughBouncePts);
         if(bounces >= InpATroughConfirmCount)
         {
            if(g_a_trough_bounce_start_msc == 0)
               g_a_trough_bounce_start_msc = now;
            if((now - g_a_trough_bounce_start_msc) >= InpATroughSustainMs)
            {
               double pts = CloseLeg(g_sell_ticket, ACTION_SELL, g_sell_entry_price,
                                     "A_TROUGH_EARLY_EXIT");
               g_sell_open = false;
               g_sell_realized_pts = pts;
               g_sell_close_msc = now;
               double net = pts;
               g_cumulative_pts += net;
               g_cycle_count++;
               if(net > 0) g_cycle_win_count++; else g_cycle_loss_count++;
               PrintFormat("[B] CYCLE END #%I64d (single-leg early exit)  SELL=%+.1f  NET=%+.1f",
                           g_cycle_count, pts, net);
               FinalizeCycleTelemetry("A_TROUGH", "SINGLE_LEG", net);
               g_cycle_state = CYCLE_IDLE;
               g_b_pos_open = false;
               return;
            }
         }
         else
         {
            g_a_trough_bounce_start_msc = 0;
         }
      }

      // Check if profit reached hedge trigger — add hedge leg
      if(leg_profit >= g_effective_hedge_trigger_pts)
      {
         PrintFormat("[B] HEDGE TRIGGER HIT — %s profit=%.1f >= trigger=%.1f  → adding hedge",
                     is_buy ? "BUY" : "SELL", leg_profit, g_effective_hedge_trigger_pts);
         AddHedgeLeg(InpLots);

         // After adding hedge, reset peak/trough tracking to focus on winner exit
         ResetPeakTroughTracking();
      }

      return;
   }

   // ==================================================================
   // STATE: CYCLE_HEDGE_OPEN — both legs open, waiting for A signal on winner
   // ==================================================================
   if(g_cycle_state == CYCLE_HEDGE_OPEN)
   {
      bool winner_is_buy = (g_cycle_direction == "UP");

      if(winner_is_buy && g_buy_open && (now - g_buy_open_msc) >= InpMinLegHoldMs)
      {
         // Watch for A peak → close BUY (winner) at high
         int drops = CountAPeakDrops(a1_active, a2_active, a3_active, InpAPeakDropPts);
         if(drops >= InpAPeakConfirmCount)
         {
            if(g_a_peak_drop_start_msc == 0)
               g_a_peak_drop_start_msc = now;
            if((now - g_a_peak_drop_start_msc) >= InpAPeakSustainMs)
            {
               double pts = CloseLeg(g_buy_ticket, ACTION_BUY, g_buy_entry_price,
                                     "A_PEAK_WINNER");
               g_buy_open = false;
               g_buy_realized_pts = pts;
               g_buy_close_msc = now;
               g_cycle_state = CYCLE_WINNER_CLOSED;
               g_cyc.exit_reason = "A_PEAK";   // winner (BUY) closed on A peak

               // Reset trough tracking for loser exit
               g_a_trough_1 = DBL_MAX; g_a_trough_2 = DBL_MAX; g_a_trough_3 = DBL_MAX;
               g_a_trough_1_msc = 0;   g_a_trough_2_msc = 0;   g_a_trough_3_msc = 0;
               g_a_trough_bounce_start_msc = 0;

               PrintFormat("[B] STATE → WINNER_CLOSED (BUY realized %+.1f, waiting A trough for SELL)", pts);
            }
         }
         else
         {
            g_a_peak_drop_start_msc = 0;
         }
      }
      else if(!winner_is_buy && g_sell_open && (now - g_sell_open_msc) >= InpMinLegHoldMs)
      {
         // Watch for A trough → close SELL (winner) at low
         int bounces = CountATroughBounces(a1_active, a2_active, a3_active, InpATroughBouncePts);
         if(bounces >= InpATroughConfirmCount)
         {
            if(g_a_trough_bounce_start_msc == 0)
               g_a_trough_bounce_start_msc = now;
            if((now - g_a_trough_bounce_start_msc) >= InpATroughSustainMs)
            {
               double pts = CloseLeg(g_sell_ticket, ACTION_SELL, g_sell_entry_price,
                                     "A_TROUGH_WINNER");
               g_sell_open = false;
               g_sell_realized_pts = pts;
               g_sell_close_msc = now;
               g_cycle_state = CYCLE_WINNER_CLOSED;
               g_cyc.exit_reason = "A_TROUGH";   // winner (SELL) closed on A trough

               // Reset peak tracking for loser exit
               g_a_peak_1 = -DBL_MAX; g_a_peak_2 = -DBL_MAX; g_a_peak_3 = -DBL_MAX;
               g_a_peak_1_msc = 0;    g_a_peak_2_msc = 0;    g_a_peak_3_msc = 0;
               g_a_peak_drop_start_msc = 0;

               PrintFormat("[B] STATE → WINNER_CLOSED (SELL realized %+.1f, waiting A peak for BUY)", pts);
            }
         }
         else
         {
            g_a_trough_bounce_start_msc = 0;
         }
      }
      return;
   }

   // ==================================================================
   // STATE: CYCLE_WINNER_CLOSED — waiting for opposite A signal on loser
   // ==================================================================
   if(g_cycle_state == CYCLE_WINNER_CLOSED)
   {
      bool loser_is_sell = (g_cycle_direction == "UP");  // if UP, BUY was winner, SELL is loser

      if(loser_is_sell && g_sell_open)
      {
         // Watch for A trough (price came down) → SELL loser now has better exit price
         int bounces = CountATroughBounces(a1_active, a2_active, a3_active, InpATroughBouncePts);
         if(bounces >= InpATroughConfirmCount)
         {
            if(g_a_trough_bounce_start_msc == 0)
               g_a_trough_bounce_start_msc = now;
            if((now - g_a_trough_bounce_start_msc) >= InpATroughSustainMs)
            {
               double pts = CloseLeg(g_sell_ticket, ACTION_SELL, g_sell_entry_price,
                                     "A_TROUGH_LOSER");
               g_sell_open = false;
               g_sell_realized_pts = pts;
               g_sell_close_msc = now;

               double net = g_buy_realized_pts + g_sell_realized_pts;
               g_cumulative_pts += net;
               g_cycle_count++;
               if(net > 0) g_cycle_win_count++; else g_cycle_loss_count++;
               PrintFormat("[B] CYCLE END #%I64d (full cycle)  BUY=%+.1f SELL=%+.1f NET=%+.1f cumulative=%+.1f",
                           g_cycle_count, g_buy_realized_pts, g_sell_realized_pts, net, g_cumulative_pts);
               // --- Telemetry: full cycle complete (keeps winner exit_reason) ---
               FinalizeCycleTelemetry("", "WINNER_CLOSED", net);
               g_cycle_state = CYCLE_IDLE;
               g_b_pos_open = false;
               g_last_close_reason = "COMPLETE";
            }
         }
         else
         {
            g_a_trough_bounce_start_msc = 0;
         }
      }
      else if(!loser_is_sell && g_buy_open)
      {
         // DOWN cycle: SELL was winner, BUY is loser → wait for A peak (price coming up)
         int drops = CountAPeakDrops(a1_active, a2_active, a3_active, InpAPeakDropPts);
         if(drops >= InpAPeakConfirmCount)
         {
            if(g_a_peak_drop_start_msc == 0)
               g_a_peak_drop_start_msc = now;
            if((now - g_a_peak_drop_start_msc) >= InpAPeakSustainMs)
            {
               double pts = CloseLeg(g_buy_ticket, ACTION_BUY, g_buy_entry_price,
                                     "A_PEAK_LOSER");
               g_buy_open = false;
               g_buy_realized_pts = pts;
               g_buy_close_msc = now;

               double net = g_buy_realized_pts + g_sell_realized_pts;
               g_cumulative_pts += net;
               g_cycle_count++;
               if(net > 0) g_cycle_win_count++; else g_cycle_loss_count++;
               PrintFormat("[B] CYCLE END #%I64d (full cycle)  BUY=%+.1f SELL=%+.1f NET=%+.1f cumulative=%+.1f",
                           g_cycle_count, g_buy_realized_pts, g_sell_realized_pts, net, g_cumulative_pts);
               // --- Telemetry: full cycle complete (keeps winner exit_reason) ---
               FinalizeCycleTelemetry("", "WINNER_CLOSED", net);
               g_cycle_state = CYCLE_IDLE;
               g_b_pos_open = false;
               g_last_close_reason = "COMPLETE";
            }
         }
         else
         {
            g_a_peak_drop_start_msc = 0;
         }
      }
      return;
   }
}

// Legacy wrapper for backward compat with OnTick call
void MonitorPosition()
{
   MonitorHedgeCycle();
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
   // V4.4: only accept new signal when cycle is IDLE
   if(g_cycle_state != CYCLE_IDLE) return;
   if(g_b_pos_open) return;  // safety

   // If autoretry is disabled and we already had a cycle, stop
   if(!InpAutoRetryAfterExit && g_cycle_count > 0) return;

   // Cooldown between signals
   if(NowMs() - g_b_last_signal_msc < InpCooldownMs)
      return;

   // 1. Read all 3 A heartbeats (any may be missing)
   g_a1_ok = ReadHeartbeatFromFile(HB_FILE_A1, g_a1_msc, g_a1_bid, g_a1_ask,
                                   g_a1_spread, g_a1_broker, g_a1_login, g_a1_symbol, g_a1_tick);
   g_a2_ok = ReadHeartbeatFromFile(HB_FILE_A2, g_a2_msc, g_a2_bid, g_a2_ask,
                                   g_a2_spread, g_a2_broker, g_a2_login, g_a2_symbol, g_a2_tick);
   g_a3_ok = ReadHeartbeatFromFile(HB_FILE_A3, g_a3_msc, g_a3_bid, g_a3_ask,
                                   g_a3_spread, g_a3_broker, g_a3_login, g_a3_symbol, g_a3_tick);

   // 2. Freshness — mark stale/missing brokers as inactive (do NOT block).
   //    age >= 0 rejects a future/garbage timestamp (was one-sided before).
   long now = NowMs();
   long age1 = now - g_a1_msc, age2 = now - g_a2_msc, age3 = now - g_a3_msc;
   bool a1_active = g_a1_ok && age1 >= 0 && age1 <= InpMaxHeartbeatAgeMs;
   bool a2_active = g_a2_ok && age2 >= 0 && age2 <= InpMaxHeartbeatAgeMs;
   bool a3_active = g_a3_ok && age3 >= 0 && age3 <= InpMaxHeartbeatAgeMs;

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

   // 12. All checks passed — OPEN SINGLE LEG (V4.4b Delayed Hedge)
   //     Determine direction from action (BUY = UP, SELL = DOWN)
   //     Hedge leg will be added later when profit reaches trigger
   g_b_last_signal_msc = NowMs();
   g_b_signals_fired++;
   g_b_pos_entry_delta = consensus_delta;

   string direction = (action == ACTION_BUY) ? "UP" : "DOWN";

   // --- Telemetry: capture signal context (cyc.active is set later, only if
   //     the leg actually opens, inside OpenSingleLeg). ---
   double a_mid_target = b_mid + consensus_delta * point;   // A price B must chase to
   long   t_a = 0;                                          // freshest active A timestamp
   if(a1_active && g_a1_msc > t_a) t_a = g_a1_msc;
   if(a2_active && g_a2_msc > t_a) t_a = g_a2_msc;
   if(a3_active && g_a3_msc > t_a) t_a = g_a3_msc;

   ResetCycleTelemetry();
   g_cyc.t_signal               = g_b_last_signal_msc;
   g_cyc.direction              = action;                   // BUY | SELL
   g_cyc.a_delta_pts            = consensus_delta;
   g_cyc.a_brokers_agreed       = agree;
   g_cyc.a_price_at_signal      = a_mid_target;
   g_cyc.b_price_at_signal      = b_mid;
   g_cyc.b_spread_pts_at_signal = (b_ask - b_bid) / point;
   g_cyc.opened_at_iso          = IsoUtcNow();
   g_cyc.session                = SessionFromGmt();
   g_cyc.b_atr_m1_pts           = CurrentAtrM1Pts();

   // ab_lag targets (window is armed in OpenSingleLeg on successful fill).
   g_lag_is_buy = (action == ACTION_BUY);
   g_lag_target = a_mid_target;
   g_lag_t_a    = t_a;

   PrintFormat("[B] SIGNAL %s consensus=%.1f  d1=%.1f d2=%.1f d3=%.1f  active=%d/3  agree=%d  → opening SINGLE LEG (%s)",
               action, consensus_delta, d1, d2, d3, active_count, agree, direction);

   OpenSingleLeg(direction, InpLots);
}

//+------------------------------------------------------------------+
//| TELEMETRY ENGINE (B executor only)                                |
//|                                                                   |
//| Transport rules (hot-path safe):                                  |
//|   - OnTick NEVER calls WebRequest. It only enqueues JSON strings. |
//|   - WebRequest happens ONLY in OnTimer -> TelemetryFlush, and     |
//|     ONLY while g_cycle_state == CYCLE_IDLE (no open position).    |
//|   - A watchers never send HTTP (they only write the heartbeat).   |
//+------------------------------------------------------------------+

// Called every B tick from OnTick. Pure measurement — no HTTP, no trading.
void UpdateLagMeasurement()
{
   if(!g_lag_active) return;
   long now = NowMs();
   if(now - g_lag_start_ms > InpLagTimeoutMs)
   {
      g_lag_active = false;   // timed out → g_lag_measured stays false → JSON null
      return;
   }
   double b_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double b_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double b_mid = (b_bid + b_ask) * 0.5;
   bool reached = g_lag_is_buy ? (b_mid >= g_lag_target) : (b_mid <= g_lag_target);
   if(reached)
   {
      g_lag_ms       = now - g_lag_t_a;   // both stamps are GetTickCount64 on this VPS
      g_lag_measured = true;
      g_lag_active   = false;             // measure once per cycle
   }
}

// Ring buffer: append one JSON event, dropping the oldest if at cap.
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

// Build a heartbeat event JSON (common envelope + free-form payload).
string BuildHeartbeatJson(string role, string broker, long login, string symbol,
                          long ticks, double spread_pts)
{
   string s = "{";
   s += "\"deployment_id\":\"" + JsonEsc(InpDeploymentId) + "\",";
   s += "\"ea_version\":\""     + EA_VERSION + "\",";
   s += "\"role\":\""           + JsonEsc(role) + "\",";
   s += "\"broker\":\""         + JsonEsc(broker) + "\",";
   s += "\"symbol\":\""         + JsonEsc(symbol) + "\",";
   s += "\"login\":"            + IntegerToString(login) + ",";
   s += "\"vps_host\":\""       + JsonEsc(InpVpsHost) + "\",";
   s += "\"vps_port\":"         + IntegerToString(InpVpsPort) + ",";
   s += "\"event_type\":\"heartbeat\",";
   s += "\"payload\":{\"ticks\":" + IntegerToString(ticks) +
        ",\"spread_pts\":" + JDbl(spread_pts) + "}";
   s += "}";
   return s;
}

// Build the cycle event JSON from the captured g_cyc state.
string BuildCycleJson()
{
   string uid = StringFormat("%s-%I64d", InpDeploymentId, g_cyc.t_signal);
   long sig2fill = g_cyc.t_leg1_fill - g_cyc.t_signal;
   long dur      = g_cyc.t_close - g_cyc.t_signal;
   bool is_win   = (g_cyc.net_pts > 0.0);

   string p = "{";
   p += "\"cycle_uid\":\""      + JsonEsc(uid) + "\",";
   p += "\"direction\":\""      + JsonEsc(g_cyc.direction) + "\",";
   p += "\"t_signal\":"         + IntegerToString(g_cyc.t_signal) + ",";
   p += "\"t_leg1_fill\":"      + IntegerToString(g_cyc.t_leg1_fill) + ",";
   p += "\"t_hedge_fill\":"     + (g_cyc.hedge_opened ? IntegerToString(g_cyc.t_hedge_fill) : "null") + ",";
   p += "\"t_close\":"          + IntegerToString(g_cyc.t_close) + ",";
   p += "\"opened_at\":\""      + JsonEsc(g_cyc.opened_at_iso) + "\",";
   p += "\"cycle_duration_ms\":"+ IntegerToString(dur) + ",";
   p += "\"ab_lag_ms\":"        + (g_lag_measured ? IntegerToString(g_lag_ms) : "null") + ",";
   p += "\"signal_to_fill_ms\":"+ IntegerToString(sig2fill) + ",";
   p += "\"a_delta_pts\":"      + JDbl(g_cyc.a_delta_pts) + ",";
   p += "\"a_brokers_agreed\":" + IntegerToString(g_cyc.a_brokers_agreed) + ",";
   p += "\"a_price_at_signal\":"+ JDbl(g_cyc.a_price_at_signal) + ",";
   p += "\"b_price_at_signal\":"+ JDbl(g_cyc.b_price_at_signal) + ",";
   p += "\"b_spread_pts_at_signal\":" + JDbl(g_cyc.b_spread_pts_at_signal) + ",";
   p += "\"hedge_opened\":"     + (g_cyc.hedge_opened ? "true" : "false") + ",";
   p += "\"hedge_trigger_pts_used\":" + JDbl(g_cyc.hedge_trigger_pts_used) + ",";
   p += "\"leg1_ticket\":"      + IntegerToString((long)g_cyc.leg1_ticket) + ",";
   p += "\"leg1_expected_price\":" + JDbl(g_cyc.leg1_expected_price) + ",";
   p += "\"leg1_actual_price\":"   + JDbl(g_cyc.leg1_actual_price) + ",";
   p += "\"leg1_slippage_pts\":"   + JDbl(g_cyc.leg1_slippage_pts) + ",";
   p += "\"hedge_ticket\":"        + (g_cyc.hedge_opened ? IntegerToString((long)g_cyc.hedge_ticket) : "null") + ",";
   p += "\"hedge_expected_price\":"+ (g_cyc.hedge_opened ? JDbl(g_cyc.hedge_expected_price) : "null") + ",";
   p += "\"hedge_actual_price\":"  + (g_cyc.hedge_opened ? JDbl(g_cyc.hedge_actual_price) : "null") + ",";
   p += "\"hedge_slippage_pts\":"  + (g_cyc.hedge_opened ? JDbl(g_cyc.hedge_slippage_pts) : "null") + ",";
   p += "\"locked_profit_pts\":"   + (g_cyc.hedge_opened ? JDbl(g_cyc.locked_profit_pts) : "null") + ",";
   p += "\"exit_reason\":\""     + JsonEsc(g_cyc.exit_reason) + "\",";
   p += "\"final_state\":\""     + JsonEsc(g_cyc.final_state) + "\",";
   p += "\"gross_pts\":"         + JDbl(g_cyc.gross_pts) + ",";
   p += "\"net_pts\":"           + JDbl(g_cyc.net_pts) + ",";
   p += "\"net_money\":"         + JDbl(g_cyc.net_money) + ",";
   p += "\"is_win\":"            + (is_win ? "true" : "false") + ",";
   p += "\"session\":\""         + JsonEsc(g_cyc.session) + "\",";
   p += "\"b_atr_m1_pts\":"      + JDbl(g_cyc.b_atr_m1_pts);
   p += "}";

   string ev = "{";
   ev += "\"deployment_id\":\"" + JsonEsc(InpDeploymentId) + "\",";
   ev += "\"ea_version\":\""     + EA_VERSION + "\",";
   ev += "\"role\":\"B\",";
   ev += "\"broker\":\""         + JsonEsc(AccountInfoString(ACCOUNT_COMPANY)) + "\",";
   ev += "\"symbol\":\""         + JsonEsc(_Symbol) + "\",";
   ev += "\"event_type\":\"cycle\",";
   ev += "\"payload\":"          + p;
   ev += "}";
   return ev;
}

// Called at every cycle-end site. Fills the outcome fields, builds the cycle
// event and enqueues it (no HTTP here — flush happens in OnTimer).
// net_pts must be the SAME value the EA logs for this cycle (passed by the
// call site), so telemetry never diverges from the EA's own accounting.
void FinalizeCycleTelemetry(string exit_reason, string final_state, double net_pts)
{
   if(!g_cyc.active) return;              // no live cycle / already finalized
   g_cyc.active = false;

   g_cyc.t_close     = NowMs();
   if(StringLen(exit_reason) > 0) g_cyc.exit_reason = exit_reason;  // "" keeps winner-close reason
   g_cyc.final_state = final_state;
   g_cyc.net_pts     = net_pts;
   g_cyc.gross_pts   = net_pts;           // gross not separately measured (see report)

   double money = PositionNetMoney(g_cyc.leg1_ticket);
   if(g_cyc.hedge_opened) money += PositionNetMoney(g_cyc.hedge_ticket);
   g_cyc.net_money = money;

   g_lag_active = false;                  // stop measuring for this cycle

   if(!InpTelemetryEnabled) return;
   string js = BuildCycleJson();
   TelemetryEnqueue(js);
   Print("[TEL] cycle enqueued: " + js);
}

// Enqueue B's own heartbeat + (relayed) A1's heartbeat. B only.
void TelemetryEnqueueHeartbeats()
{
   if(!InpTelemetryEnabled) return;

   // B's own heartbeat
   double b_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double b_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double b_spread = (b_ask - b_bid) / _Point;
   TelemetryEnqueue(BuildHeartbeatJson("B",
                    AccountInfoString(ACCOUNT_COMPANY),
                    AccountInfoInteger(ACCOUNT_LOGIN),
                    _Symbol, g_count, b_spread));

   // A1's heartbeat, relayed from its file (A never sends HTTP itself).
   double a_bid, a_ask, a_spread; string a_broker, a_symbol; long a_login, a_tick, a_msc;
   if(ReadHeartbeatFromFile(HB_FILE_A1, a_msc, a_bid, a_ask, a_spread,
                            a_broker, a_login, a_symbol, a_tick))
   {
      g_a1_msc = a_msc; g_a1_bid = a_bid; g_a1_ask = a_ask; g_a1_ok = true;
      g_a1_spread = a_spread; g_a1_broker = a_broker; g_a1_login = a_login;
      g_a1_symbol = a_symbol; g_a1_tick = a_tick;

      long age = NowMs() - a_msc;
      // Only relay while fresh enough; skip old-format files with no identity.
      if(age >= 0 && age <= A_STALE_RELAY_MS && StringLen(a_symbol) > 0)
      {
         TelemetryEnqueue(BuildHeartbeatJson("A1", a_broker, a_login,
                          a_symbol, a_tick, a_spread));
      }
   }
}

// Flush the queue over HTTP. ONLY called from OnTimer. Batched, idempotent
// (cycle_uid dedups), retries on failure by leaving events in the queue.
void TelemetryFlush()
{
   if(!InpTelemetryEnabled)          return;
   if(g_is_watcher)                  return;   // A never sends HTTP
   if(g_cycle_state != CYCLE_IDLE)   return;   // never stall mid-cycle
   int n = ArraySize(g_tel_q);
   if(n == 0)                        return;

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
   int res = WebRequest("POST", InpTelemetryUrl, headers, 1500, data, result, result_headers);

   if(res == 200)
   {
      int rem = n - batch;                       // drop the sent prefix
      for(int i = 0; i < rem; i++) g_tel_q[i] = g_tel_q[i + batch];
      ArrayResize(g_tel_q, rem);
   }
   else if(res == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Print("[TEL] WebRequest not allowed. Add " + InpTelemetryUrl +
               " in Tools>Options>Expert Advisors (terminal B only).");
      else
         PrintFormat("[TEL] WebRequest failed err=%d — keeping %d events for retry", err, n);
   }
   else
   {
      PrintFormat("[TEL] HTTP %d — keeping %d events for retry", res, n);
   }
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

   // Telemetry setup (B executor only) — ATR handle for b_atr_m1_pts + state.
   if(!g_is_watcher)
   {
      ResetCycleTelemetry();
      ArrayResize(g_tel_q, 0);
      g_tel_last_hb_ms    = 0;
      g_tel_last_flush_ms = NowMs();
      g_atr_handle = iATR(_Symbol, PERIOD_M1, 14);
      if(g_atr_handle == INVALID_HANDLE)
         PrintFormat("[B] WARNING: ATR handle failed err=%d — b_atr_m1_pts will be 0", GetLastError());
      if(InpTelemetryEnabled)
         PrintFormat("[B] Telemetry ON  deployment=%s  url=%s  (WebRequest allowlist required)",
                     InpDeploymentId, InpTelemetryUrl);
   }

   PrintFormat("AURUM_LatencyArb_V4.4b [%s] started. broker=%s symbol=%s -> %s%s  hb_file=%s",
               g_tag, broker, sym,
               (InpUseCommonDir?"[Common]\\Files\\":"\\Files\\"), g_filename,
               g_is_watcher ? g_my_hb_filename : "(reads a1,a2,a3)");

   TG_Startup("V4.4b", g_tag, AccountInfoString(ACCOUNT_COMPANY), _Symbol);

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
      UpdateLagMeasurement();   // observability only — NO WebRequest on this path
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

   // ---- Telemetry (B executor only) — the ONLY place WebRequest runs ----
   if(!g_is_watcher && InpTelemetryEnabled)
   {
      long tnow = NowMs();
      if(g_tel_last_hb_ms == 0 || (tnow - g_tel_last_hb_ms) >= (long)InpHeartbeatSec * 1000)
      {
         TelemetryEnqueueHeartbeats();
         g_tel_last_hb_ms = tnow;
      }
      if((tnow - g_tel_last_flush_ms) >= (long)InpTelemetryFlushSec * 1000)
      {
         TelemetryFlush();   // internally no-ops unless g_cycle_state == CYCLE_IDLE
         g_tel_last_flush_ms = tnow;
      }
   }

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
         "role: %s (WATCHER V4.4b - price publisher)\n"
         "publishing to: %s\n"
         "hb writes: %I64d\n"
         "(No signal logic here — B does consensus.)",
         g_tag, g_my_hb_filename, g_hb_writes);
   }
   else
   {
      // B — full consensus + position status
      // Build hedge position display
      int digits = _Digits;
      double point = _Point;
      double buy_float = LegFloatingPts(g_buy_open, ACTION_BUY, g_buy_entry_price);
      double sell_float = LegFloatingPts(g_sell_open, ACTION_SELL, g_sell_entry_price);

      string state_name = "IDLE";
      if(g_cycle_state == CYCLE_SINGLE_LEG)
         state_name = StringFormat("SINGLE_LEG [%s] (waiting profit >= %.0f pts to add hedge)",
                                     g_cycle_direction, g_effective_hedge_trigger_pts);
      else if(g_cycle_state == CYCLE_HEDGE_OPEN)
         state_name = StringFormat("HEDGE_OPEN [%s] (waiting A signal on winner)", g_cycle_direction);
      else if(g_cycle_state == CYCLE_WINNER_CLOSED)
         state_name = StringFormat("WINNER_CLOSED [%s] (waiting reverse A signal on loser)", g_cycle_direction);
      else if(g_cycle_state == CYCLE_FORCED_EXIT)
         state_name = "FORCED_EXIT";

      string buy_line = g_buy_open
         ? StringFormat("BUY:  OPEN @%.*f  SL=%.*f  float=%+.1f pts  age=%I64d ms",
                        digits, g_buy_entry_price, digits, g_buy_sl_price, buy_float,
                        NowMs() - g_buy_open_msc)
         : (g_buy_close_msc > 0
            ? StringFormat("BUY:  CLOSED  realized=%+.1f pts", g_buy_realized_pts)
            : "BUY:  (not open)");

      string sell_line = g_sell_open
         ? StringFormat("SELL: OPEN @%.*f  SL=%.*f  float=%+.1f pts  age=%I64d ms",
                        digits, g_sell_entry_price, digits, g_sell_sl_price, sell_float,
                        NowMs() - g_sell_open_msc)
         : (g_sell_close_msc > 0
            ? StringFormat("SELL: CLOSED  realized=%+.1f pts", g_sell_realized_pts)
            : "SELL: (not open)");

      long now = NowMs();
      long age1 = now - g_a1_msc, age2 = now - g_a2_msc, age3 = now - g_a3_msc;
      bool a1_act = g_a1_ok && age1 >= 0 && age1 <= InpMaxHeartbeatAgeMs;
      bool a2_act = g_a2_ok && age2 >= 0 && age2 <= InpMaxHeartbeatAgeMs;
      bool a3_act = g_a3_ok && age3 >= 0 && age3 <= InpMaxHeartbeatAgeMs;
      int active_count = (a1_act?1:0) + (a2_act?1:0) + (a3_act?1:0);

      // Compute current effective hedge trigger (for display)
      double display_trigger = ComputeEffectiveHedgeTrigger();
      double display_spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;

      // A peak/trough status
      string peak_line = "peaks: -";
      string trough_line = "troughs: -";
      if(g_cycle_state == CYCLE_HEDGE_OPEN || g_cycle_state == CYCLE_SINGLE_LEG)
      {
         int peak_confirms = CountAPeakDrops(a1_act, a2_act, a3_act, InpAPeakDropPts);
         peak_line = StringFormat("A peak drops: %d/%d (need %.0f pts, %d brokers)",
                                   peak_confirms, active_count, InpAPeakDropPts, InpAPeakConfirmCount);
      }
      if(g_cycle_state == CYCLE_WINNER_CLOSED || g_cycle_state == CYCLE_SINGLE_LEG)
      {
         int trough_confirms = CountATroughBounces(a1_act, a2_act, a3_act, InpATroughBouncePts);
         trough_line = StringFormat("A trough bounces: %d/%d (need %.0f pts, %d brokers)",
                                     trough_confirms, active_count, InpATroughBouncePts, InpATroughConfirmCount);
      }

      string a1_status = a1_act
         ? StringFormat("A1: ACTIVE  Δ=%+.1f  age=%I64d ms", g_last_delta_1, now - g_a1_msc)
         : (g_a1_ok ? StringFormat("A1: STALE (age=%I64d ms)", now - g_a1_msc) : "A1: NO FILE");
      string a2_status = a2_act
         ? StringFormat("A2: ACTIVE  Δ=%+.1f  age=%I64d ms", g_last_delta_2, now - g_a2_msc)
         : (g_a2_ok ? StringFormat("A2: STALE (age=%I64d ms)", now - g_a2_msc) : "A2: NO FILE");
      string a3_status = a3_act
         ? StringFormat("A3: ACTIVE  Δ=%+.1f  age=%I64d ms", g_last_delta_3, now - g_a3_msc)
         : (g_a3_ok ? StringFormat("A3: STALE (age=%I64d ms)", now - g_a3_msc) : "A3: NO FILE");

      string cycle_stats = StringFormat(
         "cycles: %I64d (wins=%I64d losses=%I64d)  cumulative=%+.1f pts",
         g_cycle_count, g_cycle_win_count, g_cycle_loss_count, g_cumulative_pts);

      string spread_line = StringFormat("spread=%.1f pts  hedgeTrigger=%.1f pts  autoAdapt=%s",
                                         display_spread, display_trigger,
                                         InpAutoAdaptSpread ? "ON" : "OFF");

      role_block = StringFormat(
         "role: B (EXECUTOR V4.4b - Delayed Hedge + Auto-adapt)\n"
         "%s\n%s\n%s\n"
         "active brokers: %d/3   signals fired: %I64d\n"
         "STATE: %s\n"
         "%s\n"
         "%s\n%s\n"
         "%s\n%s\n"
         "%s\n"
         "config: thr=%.0f req=%d/3  peakDrop=%.0f troughBounce=%.0f  SL=%.0f  cycleMax=%d ms",
         a1_status, a2_status, a3_status,
         active_count, g_b_signals_fired,
         state_name,
         spread_line,
         buy_line, sell_line,
         peak_line, trough_line,
         cycle_stats,
         InpConsensusThreshold, InpRequireConsensus,
         InpAPeakDropPts, InpATroughBouncePts,
         InpInitialSlPts, InpMaxCycleMs);
   }

   Comment(StringFormat(
      "AURUM LatencyArb V4.4b (Delayed Hedge + Auto-adapt Spread)\n"
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
   if(g_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
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
      PrintFormat("V4.4b [%s] stopped. hb_writes=%I64d ticks=%I64d",
                  g_tag, g_hb_writes, g_count);
   }
   else
   {
      summary = StringFormat("Signals: %I64d fired / %I64d opens / %I64d closes\nTotal ticks: %I64d",
                             g_b_signals_fired, g_b_exec_count, g_b_close_count, g_count);
      PrintFormat("V4.4b [B] stopped. signals=%I64d opens=%I64d closes=%I64d ticks=%I64d pos_open=%s",
                  g_b_signals_fired, g_b_exec_count, g_b_close_count, g_count,
                  g_b_pos_open ? "YES(!)" : "no");
   }
   TG_Shutdown("V4.4b", g_tag, summary);
}
//+------------------------------------------------------------------+
//|                        DASHBOARD SETUP                            |
//|                                                                  |
//|  Telemetry (dashboard) transport — terminal B ONLY:              |
//|                                                                  |
//|  1. On terminal B, open:                                         |
//|        Tools -> Options -> Expert Advisors                       |
//|     Tick "Allow WebRequest for listed URL" and ADD:             |
//|        https://aurum-trading-dashboard.vercel.app               |
//|     (A watchers never call WebRequest — do NOT add it there.)    |
//|                                                                  |
//|  2. Set the SAME InpDeploymentId on A and B (default tm-guze-01).|
//|                                                                  |
//|  3. Only terminal B posts to the dashboard. It sends:            |
//|       - heartbeat every InpHeartbeatSec: one for B (role "B")    |
//|         and one relayed for A (role "A1", read from A's HB file).|
//|       - one cycle event when each trade cycle closes.            |
//|                                                                  |
//|  WebRequest is called ONLY from OnTimer -> TelemetryFlush and    |
//|  ONLY while flat (g_cycle_state == CYCLE_IDLE). OnTick never      |
//|  touches the network (telemetry side) — it only enqueues.        |
//+------------------------------------------------------------------+
