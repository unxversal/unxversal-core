import { useEffect, useMemo, useRef, useState } from 'react';
import styles from './FuturesComponent.module.css';
import type { FuturesComponentProps, UTCTimestamp } from './types';
import { createChart, type IChartApi, CandlestickSeries, LineSeries, BarSeries, type CandlestickData } from 'lightweight-charts';

export function FuturesComponent(props: FuturesComponentProps) {
  const {
    selectedSymbol,
    allSymbols,
    onSelectSymbol,
    symbolIconMap,
    selectedExpiryMs,
    availableExpiriesMs,
    onSelectExpiry,

    marketId,
    summary,
    orderBook,
    recentTrades,

    initialMarginBps,
    maintenanceMarginBps,
    maxLeverage,

    positions,
    openOrders,
    tradeHistory,
    orderHistory,
    leaderboardRank,
    leaderboardPoints,
  } = props;

  const [tf, setTf] = useState<'1m' | '5m' | '15m' | '1h' | '1d' | '7d'>('1m');
  const [chartType, setChartType] = useState<'candles' | 'bars' | 'line'>('candles');
  const [showSymbolDropdown, setShowSymbolDropdown] = useState(false);

  const chartRef = useRef<HTMLDivElement | null>(null);
  const chartApi = useRef<IChartApi | null>(null);
  const [ohlc, setOhlc] = useState<{ o: number; h: number; l: number; c: number; v: number } | null>(null);

  const uniqueSymbols = useMemo(() => Array.from(new Set(allSymbols)), [allSymbols]);

  useEffect(() => {
    let disposed = false;
    if (!chartRef.current) return;
    const chart = createChart(chartRef.current, {
      layout: { background: { color: '#0a0c12' }, textColor: '#e5e7eb' },
      rightPriceScale: { borderColor: '#1b1e27' },
      timeScale: { borderColor: '#1b1e27' },
      grid: { horzLines: { color: '#12141a' }, vertLines: { color: '#12141a' } },
    });

    let priceSeries: any;
    if (chartType === 'candles') priceSeries = chart.addSeries(CandlestickSeries, { upColor: '#10b981', downColor: '#ef4444', borderVisible: false, wickUpColor: '#10b981', wickDownColor: '#ef4444' });
    else if (chartType === 'bars') priceSeries = chart.addSeries(BarSeries, { upColor: '#10b981', downColor: '#ef4444', thinBars: true } as any);
    else priceSeries = chart.addSeries(LineSeries, { color: '#10b981', lineWidth: 2 });

    if (summary.last) {
      const now = Math.floor(Date.now() / 1000);
      const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
      const targetPrice = summary.last;
      const candles: CandlestickData<UTCTimestamp>[] = [];
      let base = Math.max(0.000001, targetPrice * 0.95);
      for (let i = 300; i >= 0; i--) {
        const time = (now - i * step) as UTCTimestamp;
        const progress = (300 - i) / 300;
        const trend = base + (targetPrice - base) * progress * 0.1;
        const noise = (Math.sin(i / 12) + Math.random() * 0.3 - 0.15) * 0.05;
        const open = base;
        const close = Math.max(0.000001, trend + noise);
        const high = Math.max(open, close) + Math.random() * 0.03;
        const low = Math.max(0.000001, Math.min(open, close) - Math.random() * 0.03);
        base = close;
        candles.push({ time, open, high, low, close });
      }
      if (candles.length > 0) candles[candles.length - 1].close = targetPrice;

      if (chartType === 'line') priceSeries.setData(candles.map(d => ({ time: d.time as UTCTimestamp, value: d.close })) as { time: UTCTimestamp; value: number }[]);
      else priceSeries.setData(candles);

      if (candles.length > 0) {
        const latest = candles[candles.length - 1];
        const vol24h = candles.slice(-24).reduce((sum, d) => sum + ((d as any).volume || 0), 0);
        setOhlc({ o: latest.open, h: latest.high, l: latest.low, c: latest.close, v: vol24h });
      }
    } else {
      priceSeries.setData([]);
      setOhlc(null);
    }

    chart.timeScale().fitContent();
    chartApi.current = chart;
    const resize = () => {
      if (!chartRef.current) return;
      const rect = chartRef.current.getBoundingClientRect();
      chart.applyOptions({ width: rect.width, height: rect.height });
    };
    resize();
    window.addEventListener('resize', resize);
    return () => { if (!disposed) { chart.remove(); } disposed = true; window.removeEventListener('resize', resize); };
  }, [tf, chartType, summary.last]);

  const timeToExpiry = useMemo(() => {
    if (!selectedExpiryMs) return '-';
    const ms = Math.max(0, selectedExpiryMs - Date.now());
    const d = Math.floor(ms / (24 * 3600 * 1000));
    const h = Math.floor((ms % (24 * 3600 * 1000)) / (3600 * 1000));
    return `${d}d ${h}h`;
  }, [selectedExpiryMs]);

  const priceColor = (summary.change24h ?? 0) >= 0 ? styles.positive : styles.negative;

  return (
    <div className={styles.root} onClick={(e) => { if (showSymbolDropdown && !(e.target as Element).closest(`.${styles.pair}`)) setShowSymbolDropdown(false); }}>
      <div className={styles.priceCard}>
        <div className={styles.pairBar}>
          <div className={styles.pair} style={{ position: 'relative' }}>
            {symbolIconMap?.[selectedSymbol] && (
              <img className={styles.pairIcon} src={symbolIconMap[selectedSymbol]} alt={selectedSymbol} />
            )}
            <span style={{ color: '#e5e7eb', fontWeight: 600, fontSize: '18px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: '4px' }} onClick={() => setShowSymbolDropdown(v => !v)}>
              {selectedSymbol}
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" style={{ color: '#9ca3af' }}>
                <path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </span>
            {showSymbolDropdown && (
              <div className={styles.symbolDropdown}>
                {uniqueSymbols.map(sym => (
                  <div key={sym} className={styles.symbolOption} onClick={() => { onSelectSymbol(sym); setShowSymbolDropdown(false); }}>
                    {symbolIconMap?.[sym] && (<img className={styles.symbolOptionIcon} src={symbolIconMap[sym]} alt={sym} />)}
                    <span>{sym}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.last?.toFixed(4) ?? '-'}</div>
              <div className={styles.metricLabel}>Price</div>
            </div>
            <div className={styles.metricItem}>
              <div className={`${styles.metricValue} ${priceColor}`}>{summary.change24h !== undefined ? `${summary.change24h.toFixed(2)}%` : '-'}</div>
              <div className={styles.metricLabel}>Change</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.vol24h?.toLocaleString() ?? '-'}</div>
              <div className={styles.metricLabel}>24h Vol</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.openInterest?.toLocaleString() ?? '-'}</div>
              <div className={styles.metricLabel}>OI</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{selectedExpiryMs ? timeToExpiry : '-'}</div>
              <div className={styles.metricLabel}>Time to Expiry</div>
            </div>
          </div>
        </div>
      </div>

      <div className={styles.toolbarCard}>
        <div className={styles.toolbar}>
          {(['1m','5m','15m','1h','1d','7d'] as const).map(t => (
            <button key={t} className={tf === t ? styles.active : ''} onClick={() => setTf(t)}>{t}</button>
          ))}
          <button className={chartType === 'candles' ? styles.active : ''} onClick={() => setChartType('candles')}>Candles</button>
          <button className={chartType === 'bars' ? styles.active : ''} onClick={() => setChartType('bars')}>Bars</button>
          <button className={chartType === 'line' ? styles.active : ''} onClick={() => setChartType('line')}>Line</button>
          <div style={{ flex: 1 }} />
          {initialMarginBps != null && maintenanceMarginBps != null && (
            <div className={styles.riskPill}>
              <span>IM {initialMarginBps/100}% · MM {maintenanceMarginBps/100}% · Max Lev {maxLeverage?.toFixed(1) ?? '-' }x</span>
            </div>
          )}
          {marketId && (
            <div className={styles.riskPill} title={marketId}>
              <span>Market {marketId.slice(0,6)}…{marketId.slice(-4)}</span>
            </div>
          )}
          <select value={selectedExpiryMs ?? ''} onChange={(e) => onSelectExpiry(Number(e.target.value))}>
            <option value="" disabled>Select expiry</option>
            {availableExpiriesMs.map(ms => (
              <option key={ms} value={ms}>{new Date(ms).toLocaleString()}</option>
            ))}
          </select>
        </div>
      </div>

      <div className={styles.chartCard}>
        <div className={styles.chartContainer}>
          <div style={{ padding: '8px 10px', color: '#cbd5e1' }}>
            {ohlc && (
              <>
                <span style={{ marginRight: 12 }}>{selectedSymbol}</span>
                <span style={{ marginRight: 12 }}>O {ohlc.o.toFixed(4)}</span>
                <span style={{ marginRight: 12 }}>H {ohlc.h.toFixed(4)}</span>
                <span style={{ marginRight: 12 }}>L {ohlc.l.toFixed(4)}</span>
                <span style={{ marginRight: 12 }}>C {ohlc.c.toFixed(4)}</span>
              </>
            )}
          </div>
          <div ref={chartRef} className={styles.chart} />
        </div>
      </div>

      <div className={styles.bottomSection}>
        <div className={styles.activityCard}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
            <div>
              <div style={{ color: '#9ca3af', marginBottom: 6 }}>Recent Trades</div>
              <table className={styles.ordersTable}>
                <thead><tr><th>Time</th><th>Maker</th><th>Taker</th><th>Price</th><th>Qty</th></tr></thead>
                <tbody>
                  {recentTrades.map((t, i) => (
                    <tr key={`${t.tsMs}-${i}`}>
                      <td>{new Date(t.tsMs).toLocaleTimeString()}</td>
                      <td>{t.maker.slice(0,6)}…</td>
                      <td>{t.taker.slice(0,6)}…</td>
                      <td>{t.priceQuote.toFixed(4)}</td>
                      <td>{t.baseQty}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div>
              <div style={{ color: '#9ca3af', marginBottom: 6 }}>Order Book</div>
              <table className={styles.ordersTable}>
                <thead><tr><th style={{ textAlign: 'left' }}>Bid Px</th><th>Bid Qty</th><th>Ask Px</th><th>Ask Qty</th></tr></thead>
                <tbody>
                  {Array.from({ length: Math.max(orderBook.bids.length, orderBook.asks.length) }).map((_, i) => {
                    const b = orderBook.bids[i];
                    const a = orderBook.asks[i];
                    return (
                      <tr key={`lvl-${i}`}>
                        <td style={{ color: '#10b981', textAlign: 'left' }}>{b ? b.price.toFixed(4) : ''}</td>
                        <td>{b ? b.qty.toLocaleString() : ''}</td>
                        <td style={{ color: '#ef4444' }}>{a ? a.price.toFixed(4) : ''}</td>
                        <td>{a ? a.qty.toLocaleString() : ''}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <div className={styles.sideCard}>
          <div style={{ color: '#9ca3af', marginBottom: 6 }}>Your Rank</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
            <div><span style={{ color: '#9ca3af' }}>Rank:</span> <span style={{ color: '#e5e7eb' }}>{leaderboardRank ?? '-'}</span></div>
            <div><span style={{ color: '#9ca3af' }}>Points:</span> <span style={{ color: '#e5e7eb' }}>{leaderboardPoints ?? '-'}</span></div>
          </div>
        </div>
      </div>

      <div className={styles.activityCard}>
        <div className={styles.activityTabs}>
          {/* The parent wrapper can manage active tabs; for now we render all blocks for simplicity */}
          <button className={styles.active}>Positions</button>
          <button>Open Orders</button>
          <button>Trade History</button>
          <button>Order History</button>
        </div>
        <div style={{ marginTop: 10 }}>
          <div style={{ color: '#9ca3af', marginBottom: 6 }}>Positions (All Futures)</div>
          <table className={styles.ordersTable}>
            <thead>
              <tr>
                <th>Market</th>
                <th>Expiry</th>
                <th>Long</th>
                <th>Short</th>
                <th>Avg Long</th>
                <th>Avg Short</th>
                <th>Mark</th>
                <th>PnL</th>
                <th>Health</th>
              </tr>
            </thead>
            <tbody>
              {positions.map((p, i) => (
                <tr key={`${p.marketId}-${i}`}>
                  <td>{p.symbol}</td>
                  <td>{p.expiryMs ? new Date(p.expiryMs).toLocaleDateString() : '-'}</td>
                  <td>{p.longQty}</td>
                  <td>{p.shortQty}</td>
                  <td>{(p.avgLong1e6/1e6).toFixed(4)}</td>
                  <td>{(p.avgShort1e6/1e6).toFixed(4)}</td>
                  <td>{p.markPrice1e6 != null ? (p.markPrice1e6/1e6).toFixed(4) : '-'}</td>
                  <td className={(p.pnlQuote ?? 0) >= 0 ? styles.positive : styles.negative}>{p.pnlQuote != null ? (p.pnlQuote >= 0 ? `+$${p.pnlQuote.toFixed(2)}` : `-$${Math.abs(p.pnlQuote).toFixed(2)}`) : '-'}</td>
                  <td>{p.health?.healthRatio != null ? `${(p.health.healthRatio*100).toFixed(1)}%` : '-'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ marginTop: 16 }}>
          <div style={{ color: '#9ca3af', marginBottom: 6 }}>Open Orders</div>
          <table className={styles.ordersTable}>
            <thead><tr><th>Market</th><th>Side</th><th>Qty</th><th>Price</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>
              {openOrders.map((o) => (
                <tr key={o.orderId}>
                  <td>{selectedSymbol}</td>
                  <td className={o.isBid ? styles.positive : styles.negative}>{o.isBid ? 'Buy' : 'Sell'}</td>
                  <td>{o.qtyRemaining}</td>
                  <td>{o.priceQuote.toFixed(4)}</td>
                  <td><span className={styles.pendingBadge}>{o.status ?? 'Open'}</span></td>
                  <td><button className={styles.cancelButton} onClick={() => props.onCancelOrder(o.orderId)}>Cancel</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ marginTop: 16 }}>
          <div style={{ color: '#9ca3af', marginBottom: 6 }}>Trade History</div>
          <table className={styles.ordersTable}>
            <thead><tr><th>Time</th><th>Maker</th><th>Taker</th><th>Price</th><th>Qty</th></tr></thead>
            <tbody>
              {tradeHistory.map((t, idx) => (
                <tr key={`${t.tsMs}-${idx}`}>
                  <td>{new Date(t.tsMs).toLocaleTimeString()}</td>
                  <td>{t.maker.slice(0,6)}…</td>
                  <td>{t.taker.slice(0,6)}…</td>
                  <td>{t.priceQuote.toFixed(4)}</td>
                  <td>{t.baseQty}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ marginTop: 16 }}>
          <div style={{ color: '#9ca3af', marginBottom: 6 }}>Order History</div>
          <table className={styles.ordersTable}>
            <thead><tr><th>Time</th><th>Action</th><th>Order</th></tr></thead>
            <tbody>
              {orderHistory.map((h, idx) => (
                <tr key={`${h.orderId}-${idx}`}>
                  <td>{new Date(h.tsMs).toLocaleTimeString()}</td>
                  <td>{h.kind}</td>
                  <td>{h.orderId.slice(0,8)}…</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}


