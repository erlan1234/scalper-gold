# GoldScalperEA — MetaTrader 5 gold scalping bot

Automated **entry + exit** for XAUUSD on MetaTrader 5. Built for an intraday scalper
who can't watch the screen all day. It enters on its own, always with a stop-loss, and
**stops itself** when daily limits are hit.

> ⚠️ **Run it on a DEMO account first.** This is software *you* operate — every trade it
> places is your responsibility. No bot is guaranteed to be profitable. Targeting a fixed
> "% per day" tends to cause overtrading; treat the demo phase as a real test, not a formality.

---

## What the strategy does

Intraday **trend-pullback scalp** (no indicators-soup, no martingale, no grid):

1. **Trend filter** — on a higher timeframe (default M15), price must be above EMA200 to
   look for buys, below it to look for sells. Trade *with* the bigger move only.
2. **Micro-trend** — on the trade timeframe (default M5), fast EMA(21) vs slow EMA(50)
   must agree with the trend.
3. **Entry trigger** — RSI(14) must pull back and then **cross back** through a reset level
   (up through 45 for longs, down through 55 for shorts). That's the "dip in an uptrend /
   bounce in a downtrend" entry — it acts once per closed bar, so **no repainting**.
4. **Exit** — every trade gets an **ATR-based stop-loss and take-profit** (default SL = 1.5×ATR,
   TP = 2.0×ATR → ~1:1.3 reward:risk). Positions are also force-closed after `MaxHoldHours`
   (default 24h — matches your "hold max a day" style).

## Built-in safety rails

| Guard | Default | What it does |
|-------|---------|--------------|
| Stop-loss on every trade | 1.5×ATR | No naked positions, ever |
| **Daily loss kill-switch** | −5% | Halts all new trades for the rest of the day |
| Daily profit lock | +5% | Stops trading once you're up 5% (don't give it back) |
| Max trades/day | 10 | Caps overtrading |
| Max open positions | 1 | One scalp at a time |
| Session filter | 07:00–20:00 server | Trades London/NY only, skips thin Asian whipsaw |
| Spread filter | 50 pts | Skips entries when the spread blows out |
| Lot sizing | Fixed 0.01 | Predictable; switch to `UseRiskPercent` for 2%/trade later |

The bot draws a live status box on the chart (mode, open trades, daily P/L, halted yes/no).

---

## Install & test (demo first)

1. **Open MetaEditor** (in MT5: `Tools → MetaQuotes Language Editor`, or press `F4`).
2. Copy `GoldScalperEA.mq5` into your terminal's `MQL5/Experts/` folder.
   - Find it via MT5: `File → Open Data Folder → MQL5 → Experts`.
3. In MetaEditor, open the file and click **Compile** (`F7`). Expect `0 errors`.
   *(If MetaEditor reports anything, paste it back to me and I'll fix it.)*
4. In MT5, open a **DEMO** account gold chart (your broker's gold symbol — often `XAUUSD`,
   but some use `GOLD`, `XAUUSDm`, `XAUUSD.`, etc. The EA trades whatever symbol's chart it's on).
5. Set the chart timeframe to **M5**, drag **GoldScalperEA** from the Navigator onto the chart.
6. In the dialog: tick **Allow Algo Trading**, then OK. Make sure the toolbar
   **Algo Trading** button is green.
7. Watch the status box + the `Experts`/`Journal` tabs. Let it run on demo for a couple of
   weeks before you even think about live.

### Going live (only after demo proves out)
Same EA, just attach it to your **live** account chart. Start with `FixedLot = 0.01`.
Only switch `UseRiskPercent = true` once you trust it.

---

## Key inputs (set in the EA dialog → Inputs tab)

- `TradeTF` / `TrendTF` — scalp TF (M5) and trend-filter TF (M15). Try M1/M5 for faster scalps.
- `SL_ATR_Mult` / `TP_ATR_Mult` — risk:reward. Raise TP for bigger targets, fewer wins.
- `UseRiskPercent` + `RiskPercent` — turn on % risk sizing (computes lot from the SL distance).
- `MaxDailyLossPct` / `DailyProfitTarget` — your daily kill-switch and lock-in (set to your "Sedang": −5% / +5%).
- `MaxHoldHours` — auto-close age (24 = your max hold).
- `TradeStartHour` / `TradeEndHour` — **server time**, not your local time. Check your broker's
  server clock and adjust to cover London open → NY (gold's liveliest hours).

## Notes & limits

- This EA is **independent of TradingView** — it uses MetaTrader's own price/indicators.
  TradingView stays your analysis screen; the EA does execution.
- It only manages trades it opened (tagged by `MagicNumber`). Your manual trades are untouched.
- Backtest it in MT5's **Strategy Tester** (`Ctrl+R`) across a few months before demo, to sanity-check.
- Not financial advice. Markets can gap through stops (news, weekend). Keep size small.
