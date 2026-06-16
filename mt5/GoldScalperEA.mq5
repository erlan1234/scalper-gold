//+------------------------------------------------------------------+
//|                                              GoldScalperEA.mq5     |
//|   Gold (XAUUSD) intraday scalper                                  |
//|   Strategy : higher-TF EMA trend filter + EMA cross + RSI         |
//|             pullback, ATR-based SL/TP                             |
//|   Safety  : % risk sizing, daily loss kill-switch, daily profit   |
//|             lock, max-hold auto-close, session + spread filters    |
//|                                                                   |
//|   ⚠️  RUN ON A DEMO ACCOUNT FIRST. Trading risks real money.      |
//|       This is a tool you operate; you own every trade it makes.    |
//+------------------------------------------------------------------+
#property copyright "Built with Claude — for educational use. Not financial advice."
#property version   "1.00"
#property description "Gold intraday scalper: EMA trend + RSI pullback, ATR SL/TP, daily kill-switch. TEST ON DEMO FIRST."

#include <Trade/Trade.mqh>
CTrade trade;

//============================ INPUTS ===============================
input group "=== Strategy ==="
input ENUM_TIMEFRAMES TradeTF       = PERIOD_M5;   // Trading timeframe (the scalp TF)
input ENUM_TIMEFRAMES TrendTF       = PERIOD_M15;  // Higher TF for trend filter
input int             FastEMA       = 21;          // Fast EMA (trade TF)
input int             SlowEMA       = 50;          // Slow EMA (trade TF)
input int             TrendEMA      = 200;         // Trend EMA (on TrendTF)
input bool            UseHigherTFBias = true;       // only trade WITH the macro (higher-TF) trend
input ENUM_TIMEFRAMES BiasTF          = PERIOD_H4;  // macro trend timeframe
input int             BiasEMA         = 200;        // EMA length on BiasTF
input int             RSIPeriod     = 14;          // RSI period
input double          RSILongLevel  = 50.0;        // Long: RSI crosses UP through this (50=midline; lower=stricter/rarer)
input double          RSIShortLevel = 50.0;        // Short: RSI crosses DOWN through this (50=midline; higher=stricter/rarer)
input int             ATRPeriod     = 14;          // ATR period (for SL/TP distance)

input group "=== Risk / Exits ==="
input double SL_ATR_Mult    = 1.5;    // Stop-loss distance = ATR x this
input double RewardRisk     = 2.0;    // Take-profit = SL distance x this (2.0 = R:R 1:2)
input bool   UseRiskSizing = true;   // true = risk % of balance per trade (aggressive); false = fixed lot
input double FixedLot       = 0.01;   // Lot used when UseRiskSizing = false
input double RiskPercent    = 2.0;    // % of balance risked per trade (when UseRiskSizing = true)
input double MaxLot         = 1.0;    // Hard cap on lot size (safety)
input int    MaxHoldHours   = 24;     // Force-close a position after N hours (0 = off)

input group "=== Swing structure (SL/TP) ==="
input bool   UseSwingStops  = true;   // place SL/TP at swing low/high instead of pure ATR
input int    SwingLookback  = 5;      // bars on each side to confirm a swing (pivot strength)
input int    SwingScanBars  = 60;     // how far back to search for the latest swing
input double SwingBufferATR = 0.3;    // buffer beyond the swing, as a fraction of ATR
input double SwingSLCapATR  = 3.0;    // max SL distance in ATR (risk cap if the swing is far)

input group "=== Trailing stop (profit lock) ==="
input bool   UseTrailing   = false;   // OFF by default: A/B test showed it cut winners & turned +$239 into -$108
input double TrailActivate = 3.0;     // arm trailing once floating profit reaches this ($)
input double TrailGiveback = 2.0;     // close if profit drops this much ($) from its peak

input group "=== Breakeven stop ==="
input bool   UseBreakeven      = true; // move SL to ~entry once in decent profit (upside stays open)
input double BreakevenActivate = 3.0;  // arm once floating profit reaches this ($) — A/B best
input double BreakevenLock     = 1.0;  // new SL = entry +/- this (price): locks a bit + covers spread

input group "=== Daily guards (kill-switch) ==="
input double MaxDailyLossPct   = 5.0;  // Halt trading if down this % on the day
input double DailyProfitTarget = 5.0;  // Halt trading if up this % on the day (0 = off)
input int    MaxTradesPerDay   = 10;   // Max entries per day (0 = unlimited)
input int    MaxOpenPositions  = 1;    // Simultaneous positions this EA may hold

input group "=== Filters ==="
input int TradeStartHour = 7;    // Server hour to START trading (set =EndHour for 24h)
input int TradeEndHour   = 20;   // Server hour to STOP trading
input int MaxSpreadPoints = 50;  // Skip entry if spread wider than this (points)

input group "=== Misc ==="
input long   MagicNumber  = 990013;          // Unique ID for this EA's trades
input string TradeComment = "GoldScalperEA"; // Order comment

input group "=== Telegram alerts ==="
input bool   EnableTelegram = false; // turn ON to send Telegram notifications
input string TelegramToken  = "";    // bot token from @BotFather
input string TelegramChatID = "";    // your chat id (get it from @userinfobot)
input int    TelegramPollSec = 5;    // check for incoming Telegram commands every N seconds

input group "=== Trade logging (learning data) ==="
input bool   EnableTradeLog = true;                       // log each closed trade + features to CSV
input string TradeLogFile   = "GoldScalperEA_trades.csv"; // in MQL5/Files (tester: its own Files)

//============================ GLOBALS ==============================
int      hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE;
int      hEmaTrend = INVALID_HANDLE, hRSI = INVALID_HANDLE, hATR = INVALID_HANDLE;
int      hEmaBias = INVALID_HANDLE;  // macro trend filter (higher TF)
datetime lastBarTime    = 0;
double   dailyStartEquity = 0.0;
int      dayOfTracking  = -1;
int      tradesToday    = 0;
bool     haltedToday    = false;

// --- live diagnostics (shown on dashboard + logged each bar) ---
string   g_regime  = "warming up";
double   g_rsiNow  = 0.0;
string   g_waiting = "menunggu data candle...";
string   g_tgQueue[];   // pending Telegram messages, flushed in OnTick
bool     g_paused      = false;  // paused via Telegram /pause
long     g_lastUpdateId = 0;     // last processed Telegram update_id

// --- entry-feature snapshot, held until the trade closes (learning log) ---
double   g_featEmaGap = 0, g_featTrendDist = 0;   // latest values, refreshed each bar
bool     g_eHasOpen = false;
// --- trailing-stop state (MaxOpenPositions=1, tracked by ticket) ---
ulong    g_trailTicket = 0;
double   g_peakProfit  = 0;
bool     g_trailArmed  = false;
bool     g_trailClosing = false;   // set right before a trailing close (for log labelling)
datetime g_eTime = 0;
string   g_eDir = "", g_eRegime = "";
double   g_ePrice=0, g_eSL=0, g_eTP=0, g_eLot=0, g_eRSI=0, g_eATR=0;
double   g_eSwingDist=0, g_eEmaGap=0, g_eTrendDist=0;
int      g_eHour=0, g_eDow=0, g_eSpread=0;

//============================ INIT =================================
int OnInit()
{
   hEmaFast  = iMA(_Symbol, TradeTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, TradeTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol, TrendTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(_Symbol, TradeTF, RSIPeriod, PRICE_CLOSE);
   hATR      = iATR(_Symbol, TradeTF, ATRPeriod);
   hEmaBias  = iMA(_Symbol, BiasTF, BiasEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hEmaTrend==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE || hEmaBias==INVALID_HANDLE)
   {
      Print("ERROR: failed to create indicator handles.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   ResetDaily();
   PrintFormat("GoldScalperEA started on %s %s  (mode: %s)",
               _Symbol, EnumToString(TradeTF),
               UseRiskSizing ? StringFormat("risk %.1f%%", RiskPercent)
                              : StringFormat("fixed %.2f lot", FixedLot));
   QueueTelegram(StringFormat("GoldScalperEA online di %s %s — siap berburu sinyal. Ketik /help untuk perintah.",
                              _Symbol, EnumToString(TradeTF)));
   if(EnableTelegram)
   {
      PollTelegram(false);                              // drain old messages, don't run them
      EventSetTimer(TelegramPollSec < 2 ? 2 : TelegramPollSec);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hEmaFast!=INVALID_HANDLE)  IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE)  IndicatorRelease(hEmaSlow);
   if(hEmaTrend!=INVALID_HANDLE) IndicatorRelease(hEmaTrend);
   if(hRSI!=INVALID_HANDLE)      IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE)      IndicatorRelease(hATR);
   if(hEmaBias!=INVALID_HANDLE)  IndicatorRelease(hEmaBias);
   EventKillTimer();
   Comment("");
}

//============================ MAIN LOOP ============================
void OnTick()
{
   FlushTelegram();           // send any queued Telegram alerts
   ManageDailyState();        // reset on new day + evaluate kill-switch
   ManageOpenPositions();     // max-hold auto-close
   ManageTrailing();          // lock profit if it retraces from the peak
   ManageBreakeven();         // move SL to entry once comfortably in profit
   UpdateDashboard();

   if(haltedToday || g_paused) return;  // daily limit hit, or paused via Telegram /pause
   if(!IsTradeSession())      return;   // outside trading window

   // Act once per closed bar (no repaint, no tick spam)
   datetime t = iTime(_Symbol, TradeTF, 0);
   if(t == lastBarTime)       return;
   lastBarTime = t;

   if(CountMyPositions() >= MaxOpenPositions)                 return;
   if(MaxTradesPerDay>0 && tradesToday >= MaxTradesPerDay)    return;
   if(CurrentSpreadPoints() > MaxSpreadPoints)                return;

   CheckSignals();
}

//============================ SIGNALS =============================
void CheckSignals()
{
   double emaFast[], emaSlow[], emaTrend[], rsi[], atr[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(emaTrend,true);
   ArraySetAsSeries(rsi,     true);
   ArraySetAsSeries(atr,     true);

   if(CopyBuffer(hEmaFast, 0,0,3,emaFast) < 3) return;
   if(CopyBuffer(hEmaSlow, 0,0,3,emaSlow) < 3) return;
   if(CopyBuffer(hEmaTrend,0,0,2,emaTrend)< 2) return;
   if(CopyBuffer(hRSI,     0,0,3,rsi)     < 3) return;
   if(CopyBuffer(hATR,     0,0,3,atr)     < 3) return;

   double closePrev = iClose(_Symbol, TradeTF, 1);  // last closed bar
   double ef = emaFast[1];      // fast EMA, last closed bar
   double es = emaSlow[1];      // slow EMA, last closed bar
   double et = emaTrend[1];     // trend EMA (higher TF), last closed bar
   double r1 = rsi[1];          // RSI, last closed bar
   double r2 = rsi[2];          // RSI, bar before
   double a  = atr[1];          // ATR, last closed bar

   if(a <= 0) return;

   bool bull = (closePrev > et) && (ef > es);   // uptrend regime (M15 + M5)
   bool bear = (closePrev < et) && (ef < es);   // downtrend regime

   // Macro bias: only allow trades WITH the higher-TF trend (fixes counter-trend longs)
   bool bullBias = true, bearBias = true;
   if(UseHigherTFBias)
   {
      double bias[]; ArraySetAsSeries(bias, true);
      if(CopyBuffer(hEmaBias, 0, 0, 2, bias) >= 1)
      {
         bullBias = closePrev > bias[0];
         bearBias = closePrev < bias[0];
      }
   }

   // Pullback reset: RSI crosses back up (long) / down (short) through the reset level
   bool longSig  = bull && bullBias && (r2 <  RSILongLevel)  && (r1 >= RSILongLevel);
   bool shortSig = bear && bearBias && (r2 >  RSIShortLevel) && (r1 <= RSIShortLevel);

   // --- diagnostics: record WHY we do / don't enter this bar ---
   g_rsiNow = r1;
   g_regime = bull ? "BULL (cari LONG)" : bear ? "BEAR (cari SHORT)" : "MIXED (no-trade)";
   if(!bull && !bear)
      g_waiting = "tren M15 & micro M5 belum sepakat";
   else if(bull && !bullBias)
      g_waiting = "uptrend kecil tapi tren H4 turun -> long diblokir";
   else if(bear && !bearBias)
      g_waiting = "downtrend kecil tapi tren H4 naik -> short diblokir";
   else if(bull)
      g_waiting = longSig ? "SINYAL LONG!"
                          : StringFormat("perlu RSI cross naik %.0f (kini %.0f, %s)",
                                         RSILongLevel, r1, r1 < RSILongLevel ? "siap" : "blm pullback");
   else
      g_waiting = shortSig ? "SINYAL SHORT!"
                           : StringFormat("perlu RSI cross turun %.0f (kini %.0f, %s)",
                                          RSIShortLevel, r1, r1 > RSIShortLevel ? "siap" : "blm bounce");

   PrintFormat("bar %s | regime=%s | RSI=%.1f | %s",
               TimeToString(iTime(_Symbol,TradeTF,0), TIME_MINUTES), g_regime, r1, g_waiting);

   g_featEmaGap   = ef - es;          // momentum of fast vs slow EMA
   g_featTrendDist = closePrev - et;  // distance above/below the trend EMA

   if(longSig)       OpenTrade(true,  a);
   else if(shortSig) OpenTrade(false, a);
}

//============================ ORDER ===============================
void OpenTrade(bool isLong, double atr)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = isLong ? ask : bid;

   double slDist, tpDist;
   ComputeStops(isLong, price, atr, slDist, tpDist);

   // Respect broker minimum stop distance
   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < stopsLevel) slDist = stopsLevel + _Point*5;
   if(tpDist < stopsLevel) tpDist = stopsLevel + _Point*5;

   double sl = NormalizeDouble(isLong ? price - slDist : price + slDist, _Digits);
   double tp = NormalizeDouble(isLong ? price + tpDist : price - tpDist, _Digits);

   double lot = CalcLot(slDist);
   if(lot <= 0) { Print("Lot size computed <= 0 — entry skipped."); return; }

   bool ok = isLong ? trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment)
                    : trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment);

   if(ok)
   {
      tradesToday++;
      PrintFormat("%s %s  lot=%.2f  entry=%.2f  SL=%.2f  TP=%.2f  (trade %d today)",
                  isLong ? "BUY" : "SELL", _Symbol, lot, price, sl, tp, tradesToday);
      QueueTelegram(StringFormat("ENTRY %s %s %.2f lot @ %.2f | SL %.2f | TP %.2f (trade %d)",
                  isLong ? "BUY" : "SELL", _Symbol, lot, price, sl, tp, tradesToday));

      // snapshot entry features; written to the learning log when the trade closes
      MqlDateTime edt; TimeToStruct(TimeCurrent(), edt);
      g_eHasOpen = true; g_eTime = TimeCurrent(); g_eDir = isLong ? "BUY" : "SELL";
      g_ePrice = price; g_eSL = sl; g_eTP = tp; g_eLot = lot;
      g_eRSI = g_rsiNow; g_eATR = atr; g_eSwingDist = slDist;
      g_eEmaGap = g_featEmaGap; g_eTrendDist = g_featTrendDist;
      g_eRegime = isLong ? "BULL" : "BEAR";
      g_eHour = edt.hour; g_eDow = edt.day_of_week; g_eSpread = CurrentSpreadPoints();
   }
   else
      PrintFormat("Order FAILED: retcode=%d (%s)",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//============================ LOT SIZING ==========================
double CalcLot(double slDist)
{
   double lot = FixedLot;

   if(UseRiskSizing && slDist > 0)
   {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = balance * RiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize > 0 && tickValue > 0)
      {
         double lossPerLot = (slDist / tickSize) * tickValue;   // money lost per 1.0 lot if SL hit
         if(lossPerLot > 0) lot = riskMoney / lossPerLot;
      }
   }

   // Normalize to the symbol's volume rules + safety cap
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot > MaxLot) lot = MaxLot;
   if(step > 0)     lot = MathFloor(lot/step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

//============================ SWING STRUCTURE ======================
// Most recent CONFIRMED swing low within the scan window (0 if none).
double FindSwingLow(int lr, int maxBars)
{
   if(lr < 1) return 0.0;
   double low[];
   ArraySetAsSeries(low, true);
   int copied = CopyLow(_Symbol, TradeTF, 0, maxBars + lr + 2, low);
   if(copied < lr*2 + 1) return 0.0;
   for(int i = lr; i <= maxBars && i + lr < copied; i++)
   {
      bool ok = true;
      for(int j = 1; j <= lr; j++)
         if(!(low[i] < low[i-j] && low[i] < low[i+j])) { ok = false; break; }
      if(ok) return low[i];
   }
   return 0.0;
}

// Most recent CONFIRMED swing high within the scan window (0 if none).
double FindSwingHigh(int lr, int maxBars)
{
   if(lr < 1) return 0.0;
   double high[];
   ArraySetAsSeries(high, true);
   int copied = CopyHigh(_Symbol, TradeTF, 0, maxBars + lr + 2, high);
   if(copied < lr*2 + 1) return 0.0;
   for(int i = lr; i <= maxBars && i + lr < copied; i++)
   {
      bool ok = true;
      for(int j = 1; j <= lr; j++)
         if(!(high[i] > high[i-j] && high[i] > high[i+j])) { ok = false; break; }
      if(ok) return high[i];
   }
   return 0.0;
}

// Structural SL/TP: SL beyond the last swing (buffered + ATR-capped),
// TP keeps the ATR reward:risk but extends to the swing target if it is further.
void ComputeStops(bool isLong, double price, double atr, double &slDist, double &tpDist)
{
   double rr  = RewardRisk;          // reward : risk (2.0 = 1:2)
   double buf = SwingBufferATR * atr;

   // --- Stop-loss ---
   slDist = atr * SL_ATR_Mult;   // ATR fallback
   if(UseSwingStops)
   {
      double sw = isLong ? FindSwingLow(SwingLookback, SwingScanBars)
                         : FindSwingHigh(SwingLookback, SwingScanBars);
      if(sw > 0)
      {
         double d = isLong ? (price - sw) + buf : (sw - price) + buf;
         if(d > 0) slDist = d;
      }
   }
   double slFloor = atr * SL_ATR_Mult * 0.6;   // never absurdly tight
   double slCap   = atr * SwingSLCapATR;        // never beyond the risk cap
   if(slDist < slFloor) slDist = slFloor;
   if(slDist > slCap)   slDist = slCap;

   // --- Take-profit: fixed reward:risk off the (structural) SL distance ---
   tpDist = slDist * rr;             // e.g. SL $8 -> TP $16 (1:2)
}

//============================ POSITION MGMT ========================
void ManageOpenPositions()
{
   if(MaxHoldHours <= 0) return;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)    continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - openTime >= (long)MaxHoldHours*3600)
      {
         if(trade.PositionClose(ticket))
            Print("Max-hold reached (", MaxHoldHours, "h) — closed ticket ", (string)ticket);
      }
   }
}

// Lock profit: once floating P/L hits TrailActivate, close if it falls
// TrailGiveback below its peak. SL/TP stay as the hard backstops.
void ManageTrailing()
{
   if(!UseTrailing) return;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;

      double pf = PositionGetDouble(POSITION_PROFIT);   // floating money

      if(tk != g_trailTicket)            // new position -> reset peak tracking
      {
         g_trailTicket = tk; g_peakProfit = pf; g_trailArmed = false;
      }
      if(pf > g_peakProfit) g_peakProfit = pf;
      if(!g_trailArmed && g_peakProfit >= TrailActivate) g_trailArmed = true;

      if(g_trailArmed && pf <= g_peakProfit - TrailGiveback)
      {
         g_trailClosing = true;
         if(trade.PositionClose(tk))
            Print("Trailing close: peak ", DoubleToString(g_peakProfit,2),
                  " -> ", DoubleToString(pf,2));
         else
            g_trailClosing = false;        // close failed; keep managing
      }
      return;                              // only one EA position (MaxOpenPositions=1)
   }
}

// Once a trade is comfortably in profit, move its SL to (just past) entry so it
// can no longer become a loss. Upside stays uncapped (unlike trailing).
void ManageBreakeven()
{
   if(!UseBreakeven) return;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;

      if(PositionGetDouble(POSITION_PROFIT) < BreakevenActivate) return;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double newSL = NormalizeDouble(isBuy ? entry + BreakevenLock : entry - BreakevenLock, _Digits);

      bool improves = isBuy ? (curSL < newSL - _Point)
                            : (curSL == 0 || curSL > newSL + _Point);
      if(improves)
         if(trade.PositionModify(tk, newSL, tp))
            Print("Breakeven: SL -> ", DoubleToString(newSL, _Digits));
      return;   // MaxOpenPositions = 1
   }
}

int CountMyPositions()
{
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         c++;
   }
   return c;
}

//============================ DAILY STATE ==========================
void ManageDailyState()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != dayOfTracking)
      ResetDaily();

   if(dailyStartEquity <= 0) return;
   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnlPct = (eq - dailyStartEquity) / dailyStartEquity * 100.0;

   if(MaxDailyLossPct > 0 && pnlPct <= -MaxDailyLossPct)
   {
      if(!haltedToday)
      {
         PrintFormat("KILL-SWITCH: daily P/L %.2f%% <= -%.1f%% — no more trades today.",
                     pnlPct, MaxDailyLossPct);
         QueueTelegram(StringFormat("KILL-SWITCH: rugi harian %.2f%% — bot STOP entry hari ini.", pnlPct));
      }
      haltedToday = true;
   }
   if(DailyProfitTarget > 0 && pnlPct >= DailyProfitTarget)
   {
      if(!haltedToday)
      {
         PrintFormat("TARGET HIT: daily P/L %.2f%% >= %.1f%% — locking in, no more trades today.",
                     pnlPct, DailyProfitTarget);
         QueueTelegram(StringFormat("TARGET +%.1f%% tercapai (%.2f%%) — bot kunci profit, stop hari ini.",
                                    DailyProfitTarget, pnlPct));
      }
      haltedToday = true;
   }
}

void ResetDaily()
{
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dailyStartEquity <= 0) dailyStartEquity = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dayOfTracking = dt.day_of_year;
   tradesToday   = 0;
   haltedToday   = false;
}

//============================ FILTERS / HELPERS ====================
bool IsTradeSession()
{
   if(TradeStartHour == TradeEndHour) return true;  // 24h
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(TradeStartHour < TradeEndHour)
      return (h >= TradeStartHour && h < TradeEndHour);
   return (h >= TradeStartHour || h < TradeEndHour); // window wraps midnight
}

int CurrentSpreadPoints()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

//============================ DASHBOARD ============================
void UpdateDashboard()
{
   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnlPct = dailyStartEquity > 0 ? (eq - dailyStartEquity)/dailyStartEquity*100.0 : 0.0;

   string s  = "════ GoldScalperEA ════\n";
   s += "Symbol      : " + _Symbol + "   TF: " + EnumToString(TradeTF) + "\n";
   s += "Mode        : " + (UseRiskSizing ? StringFormat("Risk %.1f%%", RiskPercent)
                                            : StringFormat("Fixed %.2f lot", FixedLot)) + "\n";
   s += "Open (EA)   : " + (string)CountMyPositions() + " / " + (string)MaxOpenPositions + "\n";
   s += "Trades today: " + (string)tradesToday + (MaxTradesPerDay>0 ? " / "+(string)MaxTradesPerDay : "") + "\n";
   s += "Daily P/L   : " + DoubleToString(pnlPct,2) + "%   (kill -"+DoubleToString(MaxDailyLossPct,1)+"% / target +"+DoubleToString(DailyProfitTarget,1)+"%)\n";
   s += "Session     : " + (IsTradeSession() ? "ACTIVE" : "closed") + "   Spread: " + (string)CurrentSpreadPoints() + " pts\n";
   s += "Regime      : " + g_regime + "   RSI: " + DoubleToString(g_rsiNow,1) + "\n";
   s += "Menunggu    : " + g_waiting + "\n";
   s += "STATUS      : " + (haltedToday ? "HALTED (daily limit)" : (g_paused ? "PAUSED (Telegram)" : "running")) + "\n";
   s += "──────────────────────\n";
   s += "DEMO-FIRST. You own every trade this bot makes.";
   Comment(s);
}

//============================ TELEGRAM =============================
string UrlEncode(string s)
{
   string out = "";
   uchar b[];
   int n = StringToCharArray(s, b, 0, -1, CP_UTF8);   // includes trailing 0
   for(int i = 0; i < n; i++)
   {
      uchar c = b[i];
      if(c == 0) break;
      if((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~')
         out += CharToString(c);
      else
         out += StringFormat("%%%02X", c);
   }
   return out;
}

void SendTelegram(string text)
{
   if(!EnableTelegram || TelegramToken == "" || TelegramChatID == "") return;
   string url  = "https://api.telegram.org/bot" + TelegramToken + "/sendMessage";
   string body = "chat_id=" + TelegramChatID + "&text=" + UrlEncode(text);
   uchar post[], result[];
   int written = StringToCharArray(body, post, 0, -1, CP_UTF8);
   if(written > 0) ArrayResize(post, written - 1);    // drop trailing '\0' from POST body
   string resHeaders;
   ResetLastError();
   int code = WebRequest("POST", url, "Content-Type: application/x-www-form-urlencoded\r\n",
                         5000, post, result, resHeaders);
   if(code == -1)
      PrintFormat("Telegram gagal (err %d) — tambahkan https://api.telegram.org di Tools > Options > Expert Advisors > Allow WebRequest.",
                  GetLastError());
   else if(code != 200)
      PrintFormat("Telegram HTTP %d: %s", code, CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
}

void QueueTelegram(string msg)
{
   if(!EnableTelegram) return;
   int n = ArraySize(g_tgQueue);
   ArrayResize(g_tgQueue, n + 1);
   g_tgQueue[n] = msg;
}

void FlushTelegram()
{
   int n = ArraySize(g_tgQueue);
   if(n == 0) return;
   for(int i = 0; i < n; i++) SendTelegram(g_tgQueue[i]);
   ArrayResize(g_tgQueue, 0);
}

//============================ LEARNING LOG =========================
// One row per closed trade: entry features + outcome. This is the data
// a feedback loop (or an ML model) learns from later.
void WriteTradeLog(double exitPrice, double profit, long durMin, string reason)
{
   bool existed = FileIsExist(TradeLogFile);
   int h = FileOpen(TradeLogFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("Trade log open failed: ", GetLastError()); return; }
   FileSeek(h, 0, SEEK_END);
   if(!existed)
      FileWrite(h, "close_time","dir","outcome","reason","entry","exit","sl","tp",
                   "lot","profit","dur_min","regime","rsi","atr","ema_gap",
                   "trend_dist","sl_dist","hour","dow","spread_pts");
   FileWrite(h,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
      g_eDir, (profit >= 0 ? "WIN" : "LOSS"), reason,
      DoubleToString(g_ePrice,2), DoubleToString(exitPrice,2),
      DoubleToString(g_eSL,2), DoubleToString(g_eTP,2), DoubleToString(g_eLot,2),
      DoubleToString(profit,2), (string)durMin, g_eRegime,
      DoubleToString(g_eRSI,1), DoubleToString(g_eATR,2), DoubleToString(g_eEmaGap,2),
      DoubleToString(g_eTrendDist,2), DoubleToString(g_eSwingDist,2),
      (string)g_eHour, (string)g_eDow, (string)g_eSpread);
   FileClose(h);
}

// Report position closes (TP / SL / manual) for EA-owned trades
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != MagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL)  != _Symbol)     return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT) return;
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double dpnl   = dailyStartEquity > 0
                   ? (AccountInfoDouble(ACCOUNT_EQUITY) - dailyStartEquity) / dailyStartEquity * 100.0 : 0.0;
   QueueTelegram(StringFormat("%s %s ditutup @ %.2f | P/L %.2f %s | harian %.2f%%",
                 profit >= 0 ? "WIN +" : "LOSS", _Symbol, price, profit,
                 AccountInfoString(ACCOUNT_CURRENCY), dpnl));

   if(EnableTradeLog && g_eHasOpen)
   {
      long   durMin = (long)((TimeCurrent() - g_eTime) / 60);
      double tol    = g_eATR * 0.25 + _Point * 10;
      string reason = "OTHER";
      if(g_trailClosing)                     { reason = "TRAIL"; g_trailClosing = false; }
      else if(MathAbs(price - g_eTP) <= tol) reason = "TP";
      else if(MathAbs(price - g_eSL) <= tol) reason = "SL";
      WriteTradeLog(price, profit, durMin, reason);
      g_eHasOpen = false;
   }
}

//==================== TELEGRAM TWO-WAY (commands) =================
void OnTimer()
{
   PollTelegram(true);
}

// Minimal JSON helpers (no native JSON in MQL5)
string ExtractJsonString(string js, string key)
{
   string pat = "\"" + key + "\":\"";
   int p = StringFind(js, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   int e = StringFind(js, "\"", p);
   while(e > 0 && StringGetCharacter(js, e-1) == '\\')
      e = StringFind(js, "\"", e+1);
   if(e < 0) return "";
   return StringSubstr(js, p, e - p);
}

string ExtractChatId(string seg)
{
   int c = StringFind(seg, "\"chat\":");
   if(c < 0) return "";
   int idp = StringFind(seg, "\"id\":", c);
   if(idp < 0) return "";
   idp += 5;
   string out = "";
   for(int i = idp; i < StringLen(seg); i++)
   {
      ushort ch = StringGetCharacter(seg, i);
      if((ch >= '0' && ch <= '9') || ch == '-') out += ShortToString(ch);
      else break;
   }
   return out;
}

void PollTelegram(bool execute)
{
   if(!EnableTelegram || TelegramToken == "" || TelegramChatID == "") return;
   string url = "https://api.telegram.org/bot" + TelegramToken +
                "/getUpdates?timeout=0&offset=" + IntegerToString(g_lastUpdateId + 1);
   uchar data[], result[];
   string resHeaders;
   ResetLastError();
   int code = WebRequest("GET", url, "", 4000, data, result, resHeaders);
   if(code != 200) return;
   string js = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   int pos = 0;
   while(true)
   {
      int u = StringFind(js, "\"update_id\":", pos);
      if(u < 0) break;
      int idStart = u + StringLen("\"update_id\":");
      long uid = (long)StringToInteger(StringSubstr(js, idStart, 20));
      int nextU  = StringFind(js, "\"update_id\":", idStart);
      int segEnd = (nextU < 0) ? StringLen(js) : nextU;
      string seg = StringSubstr(js, idStart, segEnd - idStart);

      if(uid > g_lastUpdateId)
      {
         g_lastUpdateId = uid;
         if(execute)
         {
            string chatId = ExtractChatId(seg);
            string text   = ExtractJsonString(seg, "text");
            if(chatId == TelegramChatID && StringLen(text) > 0)
               HandleCommand(text);
         }
      }
      if(nextU < 0) break;
      pos = segEnd;
   }
}

void HandleCommand(string text)
{
   StringTrimLeft(text);
   StringTrimRight(text);
   string cmd = text;
   int sp = StringFind(cmd, " ");
   if(sp > 0) cmd = StringSubstr(cmd, 0, sp);
   int at = StringFind(cmd, "@");          // strip /cmd@BotName
   if(at > 0) cmd = StringSubstr(cmd, 0, at);
   StringToLower(cmd);

   if(cmd == "/status")       SendTelegram(BuildStatus());
   else if(cmd == "/report")  SendTelegram(BuildReport());
   else if(cmd == "/pause")   { g_paused = true;  SendTelegram("Bot di-PAUSE. Entry baru distop; posisi terbuka tetap dijaga SL/TP. Kirim /resume untuk lanjut."); }
   else if(cmd == "/resume")  { g_paused = false; SendTelegram("Bot LANJUT — kembali mencari sinyal."); }
   else if(cmd == "/close")   CloseAllAndReport();
   else if(cmd == "/settings" || cmd == "/config") SendTelegram(BuildSettings());
   else if(cmd == "/help" || cmd == "/start") SendTelegram(BuildHelp());
   else SendTelegram("Perintah tidak dikenal: " + cmd + "\nKetik /help.");
}

// List every open EA position with its live floating P/L (+/-) and a total.
string BuildOpenList()
{
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string s = ""; double tot = 0; int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;
      n++;
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double cp  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double pf  = PositionGetDouble(POSITION_PROFIT);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      tot += pf;
      s += StringFormat("\n%d) %s %.2f @ %.2f -> %.2f | %s%.2f %s | SL %.2f / TP %.2f",
                        n, isBuy ? "BUY" : "SELL", vol, op, cp,
                        pf >= 0 ? "+" : "", pf, cur, sl, tp);
   }
   if(n == 0) return "\n(tidak ada posisi terbuka)";
   s += StringFormat("\nTotal floating: %s%.2f %s", tot >= 0 ? "+" : "", tot, cur);
   return s;
}

string BuildStatus()
{
   double dpnl = dailyStartEquity > 0
                 ? (AccountInfoDouble(ACCOUNT_EQUITY) - dailyStartEquity) / dailyStartEquity * 100.0 : 0.0;
   string s = StringFormat("STATUS %s %s\nRegime: %s\nRSI: %.1f\n%s\nPosisi EA: %d/%d | Trade hari ini: %d\nP/L harian: %.2f%%\nEquity: %.2f %s\nState: %s",
          _Symbol, EnumToString(TradeTF), g_regime, g_rsiNow, g_waiting,
          CountMyPositions(), MaxOpenPositions, tradesToday, dpnl,
          AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoString(ACCOUNT_CURRENCY),
          haltedToday ? "HALTED (limit)" : (g_paused ? "PAUSED" : "running"));
   s += "\n--- Posisi terbuka ---";
   s += BuildOpenList();
   return s;
}

string BuildReport()
{
   datetime from = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));   // midnight server time
   HistorySelect(from, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0, closed = 0;
   double net = 0.0;
   for(int i = 0; i < total; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC)  != MagicNumber) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL)  != _Symbol)     continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;
      double p = HistoryDealGetDouble(t, DEAL_PROFIT);
      net += p; closed++;
      if(p >= 0) wins++; else losses++;
   }
   double dpnl = dailyStartEquity > 0
                 ? (AccountInfoDouble(ACCOUNT_EQUITY) - dailyStartEquity) / dailyStartEquity * 100.0 : 0.0;
   return StringFormat("LAPORAN hari ini\nTrade selesai: %d (W:%d L:%d)\nNet: %.2f %s\nP/L harian: %.2f%%\nPosisi terbuka: %d",
          closed, wins, losses, net, AccountInfoString(ACCOUNT_CURRENCY), dpnl, CountMyPositions());
}

string BuildHelp()
{
   return "Perintah GoldScalperEA:\n/status - kondisi, posisi & floating P/L\n/report - rekap trade hari ini\n/settings - semua parameter bot\n/pause - stop entry baru\n/resume - lanjutkan\n/close - tutup posisi EA yang terbuka\n/help - tampilkan ini";
}

// Dump every key parameter so you can audit the bot's config from Telegram.
// (Token deliberately NOT included — it's a secret.)
string BuildSettings()
{
   string s = "PARAMETER GoldScalperEA";
   s += "\n[TF] trade " + EnumToString(TradeTF) + " / trend " + EnumToString(TrendTF);
   s += "\n[EMA] " + (string)FastEMA + "/" + (string)SlowEMA + "/" + (string)TrendEMA
        + " | RSI" + (string)RSIPeriod + " L" + DoubleToString(RSILongLevel,0) + "/S" + DoubleToString(RSIShortLevel,0);
   s += "\n[Bias H-TF] " + (UseHigherTFBias ? "ON " : "OFF ") + EnumToString(BiasTF) + " EMA" + (string)BiasEMA;
   s += "\n[Sizing] " + (UseRiskSizing ? ("Risk " + DoubleToString(RiskPercent,1) + "%")
                                       : ("Fixed " + DoubleToString(FixedLot,2) + " lot"))
        + " | MaxLot " + DoubleToString(MaxLot,2);
   s += "\n[SL] " + DoubleToString(SL_ATR_Mult,1) + "xATR | TP RR 1:" + DoubleToString(RewardRisk,1);
   s += "\n[Swing SL] " + (UseSwingStops ? "ON" : "OFF") + " LB" + (string)SwingLookback
        + " buf" + DoubleToString(SwingBufferATR,1) + " cap" + DoubleToString(SwingSLCapATR,1) + "ATR";
   s += "\n[Breakeven] " + (UseBreakeven ? "ON" : "OFF") + " arm $" + DoubleToString(BreakevenActivate,1)
        + " lock $" + DoubleToString(BreakevenLock,1);
   s += "\n[Trailing] " + (UseTrailing ? "ON" : "OFF") + " arm $" + DoubleToString(TrailActivate,1)
        + " give $" + DoubleToString(TrailGiveback,1);
   s += "\n[Exits] hold " + (string)MaxHoldHours + "h | maxTrades/day " + (string)MaxTradesPerDay
        + " | maxOpen " + (string)MaxOpenPositions;
   s += "\n[Guards] kill -" + DoubleToString(MaxDailyLossPct,1) + "% | target +" + DoubleToString(DailyProfitTarget,1) + "%";
   s += "\n[Filters] sesi " + (string)TradeStartHour + "-" + (string)TradeEndHour
        + " | maxSpread " + (string)MaxSpreadPoints + "pts";
   s += "\n[Telegram] " + (EnableTelegram ? "ON" : "OFF") + " poll " + (string)TelegramPollSec + "s";
   s += "\n[Magic] " + (string)MagicNumber;
   return s;
}

void CloseAllAndReport()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         if(trade.PositionClose(tk)) n++;
   }
   SendTelegram(StringFormat("/close: %d posisi EA ditutup.", n));
}
//+------------------------------------------------------------------+
