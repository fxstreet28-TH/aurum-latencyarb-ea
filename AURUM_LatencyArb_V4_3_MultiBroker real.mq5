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
//|                                                                  |
//|  Changelog:                                                      |
//|    1.33 - Position-id tracking rebuild:                          |
//|           * resolve the POSITION id from the deal (DEAL_POSITION |
//|             _ID) instead of trusting trade.ResultOrder(), which  |
//|             diverges on some hedging brokers (e.g. Vantage) and  |
//|             left positions un-selectable, un-SL'd and orphaned.  |
//|           * SL is now mandatory: retry, then close the position  |
//|             rather than ever run it unprotected.                 |
//|           * single-slot B state replaced by a configurable slot  |
//|             array (InpMaxConcurrent, 1-3 concurrent positions),  |
//|             each slot timing out and telemetering independently. |
//|           * orphan sweeper closes any magic position no slot is  |
//|             tracking (OnTimer, B only).                          |
//|           * optional UTC session-window filter (TimeGMT).        |
//+------------------------------------------------------------------+
#property copyright "AURUM TECH"
#property version   "1.33"
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
input int            InpMaxConcurrent     = 1;       // Max positions open at once (1-3). Tested: 2 gives no gain over 1.

input group "=== Consensus (B executor) ==="
input double         InpConsensusThreshold = 80.0;   // Min |delta| per broker to count (measured optimum; survives up to ~30 pts slippage)
input int            InpRequireConsensus  = 1;       // How many of 3 must agree (2 = 2/3 loose, 3 = strict all)
input double         InpMaxAgreeSpread    = 150.0;   // Max spread between 3 deltas (glitch detection)
input int            InpMaxHeartbeatAgeMs = 500;     // Max age of A heartbeat before treating as stale
input int            InpCooldownMs        = 3000;    // Between consecutive signals
input ENUM_TRADE_DIR InpDirection         = DIR_BOTH;
input bool           InpUseSessionFilter  = false;   // Restrict trading to a UTC time window
input int            InpSessionStartUTC   = 12;      // Inclusive hour, server-independent (uses TimeGMT)
input int            InpSessionEndUTC     = 21;      // Exclusive hour

input group "=== Signal Quality Filters (B side) ==="
input bool           InpUseAdxFilter      = false;    // Enable ADX trend strength filter (uses B's chart)
input ENUM_TIMEFRAMES InpFilterTF         = PERIOD_M1;
input int            InpAdxPeriod         = 14;
input double         InpAdxThreshold      = 25.0;
input bool           InpUseVolumeFilter   = false;    // Enable volume/candle-body filter
input int            InpVolumeLookback    = 20;
input double         InpVolumeMultiplier  = 1.5;

input group "=== SL / TP Bracket (B — autonomous) ==="
input double         InpTpPts             = 100.0;   // Take profit target (net pts, armed after breakeven; measured convergence 93-113 pts)
input double         InpSlPts             = 100.0;   // Stop loss cap (net pts) - must be > spread (symmetric with TP)
input double         InpMaxSpreadPts      = 25.0;    // Skip signal if current spread > this (executor spread is ~13 pts)
input int            InpMaxHoldMs         = 10000;   // Timeout backstop (ms)
input int            InpExecCooldownMs    = 500;

input group "=== Tick Logger ==="
input string         InpFilePrefix        = "ticklog_arb_v43";
input bool           InpUseCommonDir      = true;
input int            InpFlushEvery        = 200;
input bool           InpShowHeartbeat     = true;
input int            InpFreezeAlertMs     = 2000;
input int            InpBigSpreadPts      = 100;

// NOTE: keep this group LAST so existing .set files stay aligned.
input group "=== Telemetry (dashboard) ==="
input bool   InpTelemetryEnabled  = true;
input string InpDeploymentId      = "v43-01";   // must match on both A and B
input string InpTelemetryUrl      = "https://aurum-trading-dashboard.vercel.app/api/events";
input string InpIngestKey         = "ZcAoWOoOHX9ZwgPeTRMLab4VeImFTvIu";
input string InpVpsHost           = "";      // fill in on attach
input int    InpVpsPort           = 0;       // fill in on attach
input int    InpHeartbeatSec      = 30;
input int    InpTelemetryFlushSec = 5;
input int    InpLagTimeoutMs      = 3000;

//=================== CONSTANTS =====================================
#define MAGIC              20260730
#define MAX_SLOTS          3
#define EA_VERSION         "4.3"
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
long     g_skip_session    = 0;   // outside the UTC session window (filter on)

// B — position tracking.
// The old single-slot scalars (g_b_pos_*) are replaced by g_slots[] (defined
// just after the CycleTelemetry struct, since each slot embeds a cycle record).
string   g_b_last_close_reason = "";
int      g_max_concurrent      = 1;   // clamped InpMaxConcurrent (set in OnInit)
long     g_magic               = 0;   // value passed to SetExpertMagicNumber (OnInit)
int      g_orphans_closed      = 0;   // running count of orphan positions swept

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

//=================== TELEMETRY / OBSERVABILITY (V4.3 port) =========
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

// B: per-cycle telemetry — captured from signal fire through close.
// V4.3 is single-leg only: no hedge fields here — they are emitted as JSON
// null (and final_state as "SINGLE_LEG") in BuildCycleJson().
struct CycleTelemetry
{
   bool   active;
   long   t_signal;
   string direction;                // BUY | SELL (first/only leg)
   double a_delta_pts;
   int    a_brokers_agreed;
   double a_price_at_signal;
   double b_price_at_signal;
   double b_spread_pts_at_signal;
   string opened_at_iso;
   string session;
   double b_atr_m1_pts;
   // leg1 (the only leg in V4.3)
   long   t_leg1_fill;
   ulong  leg1_ticket;
   double leg1_expected_price;
   double leg1_actual_price;
   double leg1_slippage_pts;
   // close
   long   t_close;
   string exit_reason;
   string final_state;
   double gross_pts;
   double net_pts;
   double net_money;
};
void ResetCycleTelemetry(CycleTelemetry &c)
{
   c.active                 = false;
   c.t_signal               = 0;
   c.direction              = "";
   c.a_delta_pts            = 0.0;
   c.a_brokers_agreed       = 0;
   c.a_price_at_signal      = 0.0;
   c.b_price_at_signal      = 0.0;
   c.b_spread_pts_at_signal = 0.0;
   c.opened_at_iso          = "";
   c.session                = "";
   c.b_atr_m1_pts           = 0.0;
   c.t_leg1_fill            = 0;
   c.leg1_ticket            = 0;
   c.leg1_expected_price    = 0.0;
   c.leg1_actual_price      = 0.0;
   c.leg1_slippage_pts      = 0.0;
   c.t_close                = 0;
   c.exit_reason            = "";
   c.final_state            = "";
   c.gross_pts              = 0.0;
   c.net_pts                = 0.0;
   c.net_money              = 0.0;
}

//=================== B POSITION SLOTS ==============================
// One slot per concurrent B position (1..MAX_SLOTS, configured by
// InpMaxConcurrent). Each slot owns its own cycle-telemetry record so two
// open positions can never overwrite each other's t_signal / slippage etc.
struct PosSlot
{
   bool           active;
   ulong          ticket;
   string         action;       // ACTION_BUY / ACTION_SELL
   double         entry_price;
   double         sl_price;
   double         tp_price;
   bool           tp_armed;
   long           open_msc;
   CycleTelemetry cyc;          // per-slot telemetry record
};
PosSlot g_slots[MAX_SLOTS];

int ActiveSlots()
{
   int n = 0;
   for(int i = 0; i < MAX_SLOTS; i++) if(g_slots[i].active) n++;
   return n;
}

int FreeSlotIndex()
{
   for(int i = 0; i < MAX_SLOTS; i++) if(!g_slots[i].active) return i;
   return -1;
}

int SlotByTicket(ulong t)
{
   for(int i = 0; i < MAX_SLOTS; i++)
      if(g_slots[i].active && g_slots[i].ticket == t) return i;
   return -1;
}

void ClearSlot(int i)
{
   g_slots[i].active      = false;
   g_slots[i].ticket      = 0;
   g_slots[i].action      = "";
   g_slots[i].entry_price = 0.0;
   g_slots[i].sl_price    = 0.0;
   g_slots[i].tp_price    = 0.0;
   g_slots[i].tp_armed    = false;
   g_slots[i].open_msc    = 0;
   ResetCycleTelemetry(g_slots[i].cyc);
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

// UTC session-window gate (B). Uses TimeGMT() so the window is broker-server
// independent — the A/B pair may run on brokers with different server times.
// Handles a window that wraps past midnight (start > end, e.g. 21..6).
bool InSessionWindow()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   int h = d.hour;
   int s = InpSessionStartUTC;
   int e = InpSessionEndUTC;
   if(s == e) return true;               // degenerate window → treat as always-on
   if(s < e)  return (h >= s && h < e);  // normal window
   return (h >= s || h < e);             // wraps past midnight
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
//| B: close any position with our magic that no slot is tracking.    |
//| Reachable only from OnTimer (routine sweep, B only) and from the  |
//| OpenPosition critical-failure branch (immediate cleanup of a      |
//| just-opened position we could not select/register).              |
//+------------------------------------------------------------------+
int CloseOrphans()
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pos = PositionGetTicket(i);
      if(pos == 0) continue;
      if(!PositionSelectByTicket(pos)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(SlotByTicket(pos) >= 0) continue;                 // legitimately held
      if(trade.PositionClose(pos))
      {
         closed++;
         PrintFormat("[B] ORPHAN CLOSED ticket=%I64u — no slot was tracking it", pos);
      }
   }
   g_orphans_closed += closed;
   return closed;
}

//+------------------------------------------------------------------+
//| B: open + close position                                          |
//+------------------------------------------------------------------+
void OpenPosition(string action, double lots)
{
   int slot = FreeSlotIndex();
   if(slot < 0)
   {
      PrintFormat("[B] %s SKIPPED — no free slot (%d/%d active)",
                  action, ActiveSlots(), g_max_concurrent);
      return;
   }

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

   // Expected fill = the price we would pay/receive at market, captured the
   // instant BEFORE the order is sent (basis for leg1 slippage telemetry).
   double expected_price = (action == ACTION_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

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

   // --- Resolve the REAL position id from the deal. trade.ResultOrder() is the
   //     ORDER ticket; on some hedging brokers (e.g. Vantage) the position id
   //     differs, and PositionSelectByTicket / PositionModify then fail — which
   //     is how naked, orphaned positions happened. DEAL_POSITION_ID is the
   //     authoritative position id; fall back to the order only where they
   //     coincide. Then verify we can actually select it before continuing. ---
   ulong ticket = 0;
   ulong deal   = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(ticket == 0)
      ticket = trade.ResultOrder();          // brokers where they coincide

   bool selectable = false;
   for(int attempt = 0; attempt < 5; attempt++)
   {
      if(PositionSelectByTicket(ticket)) { selectable = true; break; }
      Sleep(20);
   }
   if(!selectable)
   {
      PrintFormat("[B] CRITICAL: cannot select position after open. deal=%I64u order=%I64u resolved=%I64u",
                  deal, trade.ResultOrder(), ticket);
      CloseOrphans();                        // sweep the position we could not register
      return;
   }

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

   // --- SL is MANDATORY. Retry a few times, then close the position rather than
   //     ever run it unprotected. No code path may register a slot without SL. ---
   bool sl_set = false;
   for(int attempt = 0; attempt < 3; attempt++)
   {
      if(trade.PositionModify(ticket, sl_price, 0)) { sl_set = true; break; }
      PrintFormat("[B] SL attempt %d failed on %I64u: %d (%s)",
                  attempt + 1, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      Sleep(30);
   }
   if(!sl_set)
   {
      PrintFormat("[B] ABORT: no SL could be attached to %I64u — closing immediately", ticket);
      trade.PositionClose(ticket);
      return;                                 // never register an unprotected position
   }

   long now = NowMs();

   g_slots[slot].active      = true;
   g_slots[slot].action      = action;
   g_slots[slot].ticket      = ticket;
   g_slots[slot].entry_price = actual_entry;
   g_slots[slot].sl_price    = sl_price;
   g_slots[slot].tp_price    = 0.0;
   g_slots[slot].tp_armed    = false;
   g_slots[slot].open_msc    = now;
   g_b_last_exec_msc   = now;
   g_b_exec_count++;

   // --- Telemetry: leg1 fill (signed slippage = disadvantage direction) ---
   //     Written into THIS slot's cycle record (staged at signal time).
   g_slots[slot].cyc.t_leg1_fill         = now;
   g_slots[slot].cyc.leg1_ticket         = ticket;
   g_slots[slot].cyc.leg1_expected_price = expected_price;
   g_slots[slot].cyc.leg1_actual_price   = actual_entry;
   g_slots[slot].cyc.leg1_slippage_pts   = (action == ACTION_BUY)
                               ? (actual_entry - expected_price) / point   // paid more = worse
                               : (expected_price - actual_entry) / point;  // sold lower = worse
   g_slots[slot].cyc.active = true;   // real trade opened → this cycle will emit telemetry

   // Open the ab_lag measurement window (timeout measured from t_signal).
   // ab_lag remains a single global best-effort measurement — exact at
   // InpMaxConcurrent=1; with >1 concurrent it tracks the most recent open.
   g_lag_active   = true;
   g_lag_measured = false;
   g_lag_ms       = 0;
   g_lag_start_ms = g_slots[slot].cyc.t_signal;

   PrintFormat("[B] OPEN[%d] %s ticket=%I64u lots=%.2f entry=%.*f SL=%.*f  (TP deferred until breakeven)",
               slot, action, ticket, lots, digits, actual_entry, digits, sl_price);
   TG_OrderOpen(action, AccountInfoString(ACCOUNT_COMPANY), _Symbol,
                lots, actual_entry, digits, ticket);
}

double CurrentPnLPts(int slot)
{
   if(!g_slots[slot].active) return 0.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_slots[slot].action == ACTION_BUY)
      return (bid - g_slots[slot].entry_price) / _Point;
   return (g_slots[slot].entry_price - ask) / _Point;
}

void ClosePosition(int slot, string reason)
{
   if(!g_slots[slot].active) return;
   double pnl_pts = CurrentPnLPts(slot);
   long duration = NowMs() - g_slots[slot].open_msc;
   ulong ticket = g_slots[slot].ticket;
   string action = g_slots[slot].action;

   if(trade.PositionClose(ticket))
   {
      g_b_close_count++;
      g_b_last_close_reason = reason;
      PrintFormat("[B] CLOSE[%d] %s reason=%s pnl=%.1f pts duration=%I64d ms ticket=%I64u",
                  slot, action, reason, pnl_pts, duration, ticket);
      TG_OrderClose(action, reason, pnl_pts, duration, ticket);
      // --- Telemetry: EA-initiated close (V4.3 only ever calls this for TIMEOUT).
      //     net_pts is the SAME value the EA logs above, so telemetry cannot diverge.
      //     Finalize reads this slot's cycle record, so it must run before ClearSlot.
      FinalizeCycleTelemetry(slot, reason, "SINGLE_LEG", pnl_pts);
      ClearSlot(slot);
   }
   else
   {
      PrintFormat("[B] CLOSE[%d] failed reason=%s ticket=%I64u err=%d (%s)",
                  slot, reason, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| B: monitor positions — detect broker-side SL/TP close + timeout   |
//| Each active slot is handled independently (own open_msc timeout). |
//+------------------------------------------------------------------+
void MonitorPosition()
{
   for(int i = 0; i < MAX_SLOTS; i++)
   {
      if(!g_slots[i].active) continue;

      // Check if position still exists (broker may have closed via SL/TP)
      if(!PositionSelectByTicket(g_slots[i].ticket))
      {
         // Position closed by broker — determine reason from history
         string reason = "BROKER_CLOSE";
         double pnl_pts_est = 0.0;
         long duration = NowMs() - g_slots[i].open_msc;
         ulong closed_ticket = g_slots[i].ticket;
         string closed_action = g_slots[i].action;

         // Try to find the closing deal in history
         if(HistorySelectByPosition(g_slots[i].ticket))
         {
            int deals = HistoryDealsTotal();
            for(int d = deals - 1; d >= 0; d--)
            {
               ulong deal_ticket = HistoryDealGetTicket(d);
               if(deal_ticket == 0) continue;
               if(HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) != (long)g_slots[i].ticket) continue;
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
                  pnl_pts_est = (exit_price - g_slots[i].entry_price) / _Point;
               else
                  pnl_pts_est = (g_slots[i].entry_price - exit_price) / _Point;
               break;
            }
         }

         g_b_close_count++;
         g_b_last_close_reason = reason;

         PrintFormat("[B] BROKER CLOSED[%d] %s reason=%s pnl=%.1f pts duration=%I64d ms ticket=%I64u",
                     i, closed_action, reason, pnl_pts_est, duration, closed_ticket);
         TG_OrderClose(closed_action, reason, pnl_pts_est, duration, closed_ticket);
         // --- Telemetry: broker closed the position (SL/TP hit, stopout, etc.).
         //     Finalize reads this slot's cycle record, so it must run before ClearSlot.
         FinalizeCycleTelemetry(i, reason, "SINGLE_LEG", pnl_pts_est);
         ClearSlot(i);
         continue;
      }

      // Position still open — check TP arming and timeout
      double pnl_pts = CurrentPnLPts(i);

      // Arm TP once past breakeven (pnl >= 0 means we've cleared spread cost)
      if(!g_slots[i].tp_armed && pnl_pts >= 0)
      {
         double point = _Point;
         int digits = _Digits;
         double tp_price = 0.0;
         if(g_slots[i].action == ACTION_BUY)
            tp_price = NormalizeDouble(g_slots[i].entry_price + InpTpPts * point, digits);
         else
            tp_price = NormalizeDouble(g_slots[i].entry_price - InpTpPts * point, digits);

         if(trade.PositionModify(g_slots[i].ticket, g_slots[i].sl_price, tp_price))
         {
            g_slots[i].tp_price = tp_price;
            g_slots[i].tp_armed = true;
            PrintFormat("[B] TP ARMED[%d] at %.*f (pnl was %.1f pts) — broker will close on hit",
                        i, digits, tp_price, pnl_pts);
         }
         else
         {
            PrintFormat("[B] Failed to arm TP[%d]: %d (%s)",
                        i, trade.ResultRetcode(), trade.ResultRetcodeDescription());
         }
      }

      long elapsed = NowMs() - g_slots[i].open_msc;
      if(elapsed >= InpMaxHoldMs)
         ClosePosition(i, "TIMEOUT");
   }
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
   if(ActiveSlots() >= g_max_concurrent) return;  // all configured slots busy

   // Cooldown between signals (global, not per-slot)
   if(NowMs() - g_b_last_signal_msc < InpCooldownMs)
      return;

   // Session-window filter (UTC, TimeGMT-based). Off by default.
   if(!InSessionWindow())
   {
      g_skip_session++;
      return;
   }

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

   // 12. All checks passed — fire!
   g_b_last_signal_msc = NowMs();
   g_b_signals_fired++;

   PrintFormat("[B] SIGNAL %s consensus=%.1f  d1=%.1f d2=%.1f d3=%.1f  active=%d/3  agree=%d",
               action, consensus_delta, d1, d2, d3, active_count, agree);

   // Reverse toggle (safety option — normally false)
   string exec_action = action;
   if(InpReverseSignal)
   {
      exec_action = (action == ACTION_BUY) ? ACTION_SELL : ACTION_BUY;
      PrintFormat("[B] REVERSED: %s -> %s", action, exec_action);
   }

   // --- Telemetry: stage the signal context into the TARGET slot's cycle
   //     record. The slot is only activated inside OpenPosition (on a
   //     successful, SL-protected fill), which recomputes FreeSlotIndex() and
   //     gets this same index (single-threaded; the ActiveSlots guard above
   //     guarantees a free slot exists). cyc.active is set there, not here. ---
   //     ab_lag chases the A price in the SIGNAL direction (feed lead, not the
   //     executed trade), so g_lag_is_buy follows `action`, not `exec_action`.
   int slot = FreeSlotIndex();
   if(slot < 0) return;   // no room (guard above should prevent this)

   double a_mid_target = b_mid + consensus_delta * point;   // A price B must chase to
   long   t_a = 0;                                          // freshest active A timestamp
   if(a1_active && g_a1_msc > t_a) t_a = g_a1_msc;
   if(a2_active && g_a2_msc > t_a) t_a = g_a2_msc;
   if(a3_active && g_a3_msc > t_a) t_a = g_a3_msc;

   ResetCycleTelemetry(g_slots[slot].cyc);
   g_slots[slot].cyc.t_signal               = g_b_last_signal_msc;
   g_slots[slot].cyc.direction              = exec_action;  // BUY | SELL (leg actually opened)
   g_slots[slot].cyc.a_delta_pts            = consensus_delta;
   g_slots[slot].cyc.a_brokers_agreed       = agree;
   g_slots[slot].cyc.a_price_at_signal      = a_mid_target;
   g_slots[slot].cyc.b_price_at_signal      = b_mid;
   g_slots[slot].cyc.b_spread_pts_at_signal = (b_ask - b_bid) / point;
   g_slots[slot].cyc.opened_at_iso          = IsoUtcNow();
   g_slots[slot].cyc.session                = SessionFromGmt();
   g_slots[slot].cyc.b_atr_m1_pts           = CurrentAtrM1Pts();

   // ab_lag targets (window is armed in OpenPosition on successful fill).
   g_lag_is_buy = (action == ACTION_BUY);
   g_lag_target = a_mid_target;
   g_lag_t_a    = t_a;

   OpenPosition(exec_action, InpLots);
}

//+------------------------------------------------------------------+
//| TELEMETRY ENGINE (B executor only)                                |
//|                                                                   |
//| Transport rules (hot-path safe):                                  |
//|   - OnTick NEVER calls WebRequest. It only enqueues JSON strings. |
//|   - WebRequest happens ONLY in OnTimer -> TelemetryFlush, and     |
//|     ONLY while fully flat (ActiveSlots() == 0 — V4.3 has no cycle |
//|     state machine, so "flat" is the single-leg equivalent of      |
//|     V4.4b's CYCLE_IDLE).                                          |
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

// Build the cycle event JSON from a slot's captured cycle state.
// V4.3 is single-leg: every hedge_* field is emitted as JSON null, hedge_opened
// is false, and final_state is always "SINGLE_LEG". exit_reason is sent verbatim
// (V4.3's own reason string — NOT mapped to V4.4b's enum).
string BuildCycleJson(int slot)
{
   CycleTelemetry c = g_slots[slot].cyc;   // read-only local copy

   string uid = StringFormat("%s-%I64d", InpDeploymentId, c.t_signal);
   long sig2fill = c.t_leg1_fill - c.t_signal;
   long dur      = c.t_close - c.t_signal;
   bool is_win   = (c.net_pts > 0.0);

   string p = "{";
   p += "\"cycle_uid\":\""      + JsonEsc(uid) + "\",";
   p += "\"direction\":\""      + JsonEsc(c.direction) + "\",";
   p += "\"t_signal\":"         + IntegerToString(c.t_signal) + ",";
   p += "\"t_leg1_fill\":"      + IntegerToString(c.t_leg1_fill) + ",";
   p += "\"t_hedge_fill\":null,";
   p += "\"t_close\":"          + IntegerToString(c.t_close) + ",";
   p += "\"opened_at\":\""      + JsonEsc(c.opened_at_iso) + "\",";
   p += "\"cycle_duration_ms\":"+ IntegerToString(dur) + ",";
   p += "\"ab_lag_ms\":"        + (g_lag_measured ? IntegerToString(g_lag_ms) : "null") + ",";
   p += "\"signal_to_fill_ms\":"+ IntegerToString(sig2fill) + ",";
   p += "\"a_delta_pts\":"      + JDbl(c.a_delta_pts) + ",";
   p += "\"a_brokers_agreed\":" + IntegerToString(c.a_brokers_agreed) + ",";
   p += "\"a_price_at_signal\":"+ JDbl(c.a_price_at_signal) + ",";
   p += "\"b_price_at_signal\":"+ JDbl(c.b_price_at_signal) + ",";
   p += "\"b_spread_pts_at_signal\":" + JDbl(c.b_spread_pts_at_signal) + ",";
   p += "\"hedge_opened\":false,";
   p += "\"hedge_trigger_pts_used\":null,";
   p += "\"leg1_ticket\":"      + IntegerToString((long)c.leg1_ticket) + ",";
   p += "\"leg1_expected_price\":" + JDbl(c.leg1_expected_price) + ",";
   p += "\"leg1_actual_price\":"   + JDbl(c.leg1_actual_price) + ",";
   p += "\"leg1_slippage_pts\":"   + JDbl(c.leg1_slippage_pts) + ",";
   p += "\"hedge_ticket\":null,";
   p += "\"hedge_expected_price\":null,";
   p += "\"hedge_actual_price\":null,";
   p += "\"hedge_slippage_pts\":null,";
   p += "\"locked_profit_pts\":null,";
   p += "\"exit_reason\":\""     + JsonEsc(c.exit_reason) + "\",";
   p += "\"final_state\":\""     + JsonEsc(c.final_state) + "\",";
   p += "\"gross_pts\":"         + JDbl(c.gross_pts) + ",";
   p += "\"net_pts\":"           + JDbl(c.net_pts) + ",";
   p += "\"net_money\":"         + JDbl(c.net_money) + ",";
   p += "\"is_win\":"            + (is_win ? "true" : "false") + ",";
   p += "\"session\":\""         + JsonEsc(c.session) + "\",";
   p += "\"b_atr_m1_pts\":"      + JDbl(c.b_atr_m1_pts);
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
void FinalizeCycleTelemetry(int slot, string exit_reason, string final_state, double net_pts)
{
   if(!g_slots[slot].cyc.active) return;  // no live cycle / already finalized
   g_slots[slot].cyc.active = false;

   g_slots[slot].cyc.t_close     = NowMs();
   if(StringLen(exit_reason) > 0) g_slots[slot].cyc.exit_reason = exit_reason;
   g_slots[slot].cyc.final_state = final_state;   // always "SINGLE_LEG" for V4.3
   g_slots[slot].cyc.net_pts     = net_pts;
   g_slots[slot].cyc.gross_pts   = net_pts;       // gross not separately measured (see report)
   g_slots[slot].cyc.net_money   = PositionNetMoney(g_slots[slot].cyc.leg1_ticket);

   g_lag_active = false;                  // stop measuring for this cycle

   if(!InpTelemetryEnabled) return;
   string js = BuildCycleJson(slot);
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
   if(!InpTelemetryEnabled)  return;
   if(g_is_watcher)          return;   // A never sends HTTP
   if(ActiveSlots() > 0)     return;   // never stall mid-position — only flush while fully flat
   int n = ArraySize(g_tel_q);
   if(n == 0)                return;

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

   g_magic = MAGIC;                       // shared by trade + orphan sweeper
   trade.SetExpertMagicNumber((ulong)g_magic);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Clamp the concurrent-position count to 1..MAX_SLOTS and log the effective value.
   g_max_concurrent = InpMaxConcurrent;
   if(g_max_concurrent < 1)         g_max_concurrent = 1;
   if(g_max_concurrent > MAX_SLOTS) g_max_concurrent = MAX_SLOTS;
   for(int i = 0; i < MAX_SLOTS; i++) ClearSlot(i);

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
      PrintFormat("[B] InpMaxConcurrent=%d -> effective %d (clamped to 1..%d)",
                  InpMaxConcurrent, g_max_concurrent, MAX_SLOTS);
      if(InpUseSessionFilter)
         PrintFormat("[B] Session filter ON: UTC [%02d:00, %02d:00)%s",
                     InpSessionStartUTC, InpSessionEndUTC,
                     (InpSessionStartUTC > InpSessionEndUTC) ? " (wraps midnight)" : "");
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

   // ---- Orphan sweep — B executor only, once per tick. Closes any position
   //      carrying our magic that no slot is tracking (never from OnTick/A). ----
   if(InpRole == ROLE_B_EXECUTOR)
      CloseOrphans();

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
         TelemetryFlush();   // internally no-ops unless fully flat (ActiveSlots() == 0)
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
         "role: %s (WATCHER V4.3 - price publisher)\n"
         "publishing to: %s\n"
         "hb writes: %I64d\n"
         "(No signal logic here — B does consensus.)",
         g_tag, g_my_hb_filename, g_hb_writes);
   }
   else
   {
      // B — full consensus + slot status.
      // One line per active slot, plus the slot count and orphan counter.
      long now = NowMs();
      string pos_block = StringFormat("slots: %d/%d active", ActiveSlots(), g_max_concurrent);
      for(int si = 0; si < MAX_SLOTS; si++)
      {
         if(!g_slots[si].active) continue;
         double age_s = (now - g_slots[si].open_msc) / 1000.0;
         pos_block += StringFormat("\n  [%d] %-4s %.*f  SL %.*f  age %.1fs  pnl %+.1f",
                        si, g_slots[si].action, _Digits, g_slots[si].entry_price,
                        _Digits, g_slots[si].sl_price, age_s, CurrentPnLPts(si));
      }
      pos_block += StringFormat("\norphans closed: %d", g_orphans_closed);

      long age1 = now - g_a1_msc, age2 = now - g_a2_msc, age3 = now - g_a3_msc;
      bool a1_act = g_a1_ok && age1 >= 0 && age1 <= InpMaxHeartbeatAgeMs;
      bool a2_act = g_a2_ok && age2 >= 0 && age2 <= InpMaxHeartbeatAgeMs;
      bool a3_act = g_a3_ok && age3 >= 0 && age3 <= InpMaxHeartbeatAgeMs;
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
         "skipped: stale=%I64d nosign=%I64d belowthr=%I64d glitch=%I64d adx=%I64d vol=%I64d spread=%I64d session=%I64d",
         g_skip_stale_hb, g_skip_no_sign, g_skip_below_thr, g_skip_glitch,
         g_skip_adx, g_skip_vol, g_skip_spread, g_skip_session);

      role_block = StringFormat(
         "role: B (EXECUTOR V4.3 - multi-broker consensus)\n"
         "%s\n%s\n%s\n"
         "active brokers: %d/3   signals fired: %I64d   opens: %I64d   closes: %I64d\n"
         "%s\n"
         "%s\n"
         "%s\n"
         "config: thr=%.0f req=%d/3 maxSpread=%.0f  TP=%.0f/SL=%.0f  timeout=%d ms  conc=%d",
         a1_status, a2_status, a3_status,
         active_count, g_b_signals_fired, g_b_exec_count, g_b_close_count,
         filter_line, skip_line, pos_block,
         InpConsensusThreshold, InpRequireConsensus, InpMaxAgreeSpread,
         InpTpPts, InpSlPts, InpMaxHoldMs, g_max_concurrent);
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
      PrintFormat("V4.3 [%s] stopped. hb_writes=%I64d ticks=%I64d",
                  g_tag, g_hb_writes, g_count);
   }
   else
   {
      summary = StringFormat("Signals: %I64d fired / %I64d opens / %I64d closes\nTotal ticks: %I64d",
                             g_b_signals_fired, g_b_exec_count, g_b_close_count, g_count);
      PrintFormat("V4.3 [B] stopped. signals=%I64d opens=%I64d closes=%I64d ticks=%I64d active_slots=%d",
                  g_b_signals_fired, g_b_exec_count, g_b_close_count, g_count,
                  ActiveSlots());
   }
   TG_Shutdown("V4.3", g_tag, summary);
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
//|  2. Set the SAME InpDeploymentId on A and B (default v43-01).    |
//|                                                                  |
//|  3. Only terminal B posts to the dashboard. It sends:            |
//|       - heartbeat every InpHeartbeatSec: one for B (role "B")    |
//|         and one relayed for A (role "A1", read from A's HB file).|
//|       - one cycle event when each single-leg trade closes.       |
//|                                                                  |
//|  V4.3 is single-leg only: every hedge_* field in the cycle       |
//|  payload is null, hedge_opened is false, and final_state is      |
//|  always "SINGLE_LEG". exit_reason carries V4.3's own reason      |
//|  string (TIMEOUT / SL_HIT / TP_HIT / ...), not V4.4b's enum.     |
//|                                                                  |
//|  WebRequest is called ONLY from OnTimer -> TelemetryFlush and    |
//|  ONLY while fully flat (ActiveSlots() == 0). OnTick never touches|
//|  the network (telemetry side) — it only enqueues.               |
//+------------------------------------------------------------------+
