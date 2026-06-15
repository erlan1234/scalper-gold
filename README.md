# Gold Scalper Bot (XAUUSD)

An automated **intraday gold scalping** toolkit: a MetaTrader 5 Expert Advisor that
enters and exits trades on its own, plus a matching TradingView indicator for eyeballing
the same setups. Built for a trader who can't watch the screen all day.

> ⚠️ **Trading risks real money. Run everything on a DEMO account first.**
> This is software *you* operate — every trade it places is your responsibility.
> No bot is guaranteed to be profitable. Not financial advice.

## What's inside

| Path | What it is |
|------|-----------|
| [`mt5/GoldScalperEA.mq5`](mt5/GoldScalperEA.mq5) | The MT5 Expert Advisor — automated entry + exit |
| [`mt5/README.md`](mt5/README.md) | Install, compile, and demo-test guide for the EA |
| [`tradingview/gold_swing_pro.pine`](tradingview/gold_swing_pro.pine) | TradingView Pine indicator: EMA 21/50/200 ribbon + BUY/SELL labels |
| [`rules.json`](rules.json) | Human-readable strategy + risk rules (bias criteria, entry checklist, position sizing) |

## The strategy (trend-pullback scalp)

Enter **with the trend, on a pullback** — never chase. Three layers must all agree before a trade:

1. **Trend filter** — higher-TF EMA 200 sets direction (above = longs only, below = shorts only).
2. **Micro-trend** — fast EMA 21 vs slow EMA 50 must agree on the trade timeframe.
3. **Trigger** — RSI dips toward its reset level then crosses back through it (momentum resuming).

Every trade gets an **ATR-based stop-loss and take-profit** the moment it opens, stored
server-side (they execute even if the laptop is off).

## Safety rails (built into the EA)

- Stop-loss + take-profit on **every** trade (1.5×ATR / 2.0×ATR)
- **Daily loss kill-switch** (default −5%) — halts new trades for the day
- Daily profit lock (default +5%)
- Max trades/day, max 1 open position, session + spread filters
- Auto-close positions older than 24h
- Fixed 0.01 lot by default; optional % risk sizing

See [`mt5/README.md`](mt5/README.md) for full input docs and the install/demo workflow.

## Quick start

1. Compile `mt5/GoldScalperEA.mq5` in MetaEditor (`F7`) → 0 errors.
2. Attach it to a **demo** XAUUSD M5 chart, enable Algo Trading.
3. Let it run on demo for at least two weeks before considering live.

---
*Disclaimer: for educational use. Markets can gap through stops. Keep size small while learning.*
