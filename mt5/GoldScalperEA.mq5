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
input int             RSIPeriod     = 14;          // RSI period
input double          RSILongLevel  = 50.0;        // Long: RSI crosses UP through this (50=midline; lower=stricter/rarer)
input double          RSIShortLevel = 50.0;        // Short: RSI crosses DOWN through this (50=midline; higher=stricter/rarer)
input int             ATRPeriod     = 14;          // ATR period (for SL/TP distance)

input group "=== Risk / Exits ==="
input double SL_ATR_Mult    = 1.5;    // Stop-loss distance = ATR x this
input double TP_ATR_Mult    = 2.0;    // Take-profit distance = ATR x this (R:R = TP/SL)
input bool   UseRiskPercent = false;  // false = fixed lot (safe default); true = % risk sizing
input double FixedLot       = 0.01;   // Lot used when UseRiskPercent = false
input double RiskPercent    = 2.0;    // % of balance risked per trade (when UseRiskPercent = true)
input double MaxLot         = 1.0;    // Hard cap on lot size (safety)
input int    MaxHoldHours   = 24;     // Force-close a position after N hours (0 = off)

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

//============================ GLOBALS ==============================
int      hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE;
int      hEmaTrend = INVALID_HANDLE, hRSI = INVALID_HANDLE, hATR = INVALID_HANDLE;
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

//============================ INIT =================================
int OnInit()
{
   hEmaFast  = iMA(_Symbol, TradeTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, TradeTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol, TrendTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(_Symbol, TradeTF, RSIPeriod, PRICE_CLOSE);
   hATR      = iATR(_Symbol, TradeTF, ATRPeriod);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hEmaTrend==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
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
               UseRiskPercent ? StringFormat("risk %.1f%%", RiskPercent)
                              : StringFormat("fixed %.2f lot", FixedLot));
   QueueTelegram(StringFormat("GoldScalperEA online di %s %s — siap berburu sinyal.",
                              _Symbol, EnumToString(TradeTF)));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hEmaFast!=INVALID_HANDLE)  IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE)  IndicatorRelease(hEmaSlow);
   if(hEmaTrend!=INVALID_HANDLE) IndicatorRelease(hEmaTrend);
   if(hRSI!=INVALID_HANDLE)      IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE)      IndicatorRelease(hATR);
   Comment("");
}

//============================ MAIN LOOP ============================
void OnTick()
{
   FlushTelegram();           // send any queued Telegram alerts
   ManageDailyState();        // reset on new day + evaluate kill-switch
   ManageOpenPositions();     // max-hold auto-close
   UpdateDashboard();

   if(haltedToday)            return;   // daily limit hit
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

   bool bull = (closePrev > et) && (ef > es);   // uptrend regime
   bool bear = (closePrev < et) && (ef < es);   // downtrend regime

   // Pullback reset: RSI crosses back up (long) / down (short) through the reset level
   bool longSig  = bull && (r2 <  RSILongLevel)  && (r1 >= RSILongLevel);
   bool shortSig = bear && (r2 >  RSIShortLevel) && (r1 <= RSIShortLevel);

   // --- diagnostics: record WHY we do / don't enter this bar ---
   g_rsiNow = r1;
   g_regime = bull ? "BULL (cari LONG)" : bear ? "BEAR (cari SHORT)" : "MIXED (no-trade)";
   if(!bull && !bear)
      g_waiting = "tren M15 & micro M5 belum sepakat";
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

   if(longSig)       OpenTrade(true,  a);
   else if(shortSig) OpenTrade(false, a);
}

//============================ ORDER ===============================
void OpenTrade(bool isLong, double atr)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = isLong ? ask : bid;

   double slDist = atr * SL_ATR_Mult;
   double tpDist = atr * TP_ATR_Mult;

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
   }
   else
      PrintFormat("Order FAILED: retcode=%d (%s)",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//============================ LOT SIZING ==========================
double CalcLot(double slDist)
{
   double lot = FixedLot;

   if(UseRiskPercent && slDist > 0)
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
   s += "Mode        : " + (UseRiskPercent ? StringFormat("Risk %.1f%%", RiskPercent)
                                            : StringFormat("Fixed %.2f lot", FixedLot)) + "\n";
   s += "Open (EA)   : " + (string)CountMyPositions() + " / " + (string)MaxOpenPositions + "\n";
   s += "Trades today: " + (string)tradesToday + (MaxTradesPerDay>0 ? " / "+(string)MaxTradesPerDay : "") + "\n";
   s += "Daily P/L   : " + DoubleToString(pnlPct,2) + "%   (kill -"+DoubleToString(MaxDailyLossPct,1)+"% / target +"+DoubleToString(DailyProfitTarget,1)+"%)\n";
   s += "Session     : " + (IsTradeSession() ? "ACTIVE" : "closed") + "   Spread: " + (string)CurrentSpreadPoints() + " pts\n";
   s += "Regime      : " + g_regime + "   RSI: " + DoubleToString(g_rsiNow,1) + "\n";
   s += "Menunggu    : " + g_waiting + "\n";
   s += "STATUS      : " + (haltedToday ? "HALTED (daily limit)" : "running") + "\n";
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
}
//+------------------------------------------------------------------+
