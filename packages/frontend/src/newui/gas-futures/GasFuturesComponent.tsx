import { useEffect, useMemo, useRef, useState } from 'react';
import styles from '../../components/derivatives/DerivativesScreen.module.css';
import { createChart, CandlestickSeries, LineSeries, BarSeries, type IChartApi } from 'lightweight-charts';
import { BarChart3, CandlestickChart, LineChart, Eye, Clock } from 'lucide-react';
import type { GasFuturesComponentProps, Candle } from './types';

function useChart(ohlc?: { candles: Candle[]; volumes?: { time: number; value: number }[] }, chartType: 'candles' | 'bars' | 'line' = 'candles') {
  const chartRef = useRef<HTMLDivElement | null>(null);
  const chartApi = useRef<IChartApi | null>(null);
  useEffect(() => {
    if (!chartRef.current) return;
    const chart = createChart(chartRef.current, {
      layout: { background: { color: '#0a0c12' }, textColor: '#e5e7eb' },
      rightPriceScale: { borderColor: '#1b1e27' },
      timeScale: { borderColor: '#1b1e27' },
      grid: { horzLines: { color: '#12141a' }, vertLines: { color: '#12141a' } },
    });
    let priceSeries: any;
    if (chartType === 'candles') priceSeries = chart.addSeries(CandlestickSeries, { upColor: '#10b981', downColor: '#ef4444', borderVisible: false, wickUpColor: '#10b981', wickDownColor: '#ef4444' });
    else if (chartType === 'bars') priceSeries = chart.addSeries(BarSeries, { upColor: '#10b981', downColor: '#ef4444', thinBars: true });
    else priceSeries = chart.addSeries(LineSeries, { color: '#10b981', lineWidth: 2 });
    const resize = () => { if (!chartRef.current) return; const rect = chartRef.current.getBoundingClientRect(); chart.applyOptions({ width: rect.width, height: rect.height }); };
    resize(); window.addEventListener('resize', resize);
    try {
      const c = ohlc?.candles || [];
      if (chartType === 'line') priceSeries.setData(c.map(d => ({ time: d.time as any, value: d.close })));
      else priceSeries.setData(c.map(d => ({ time: d.time as any, open: d.open, high: d.high, low: d.low, close: d.close })));
      chart.timeScale().fitContent();
    } catch {}
    chartApi.current = chart; return () => { chart.remove(); window.removeEventListener('resize', resize); };
  }, [JSON.stringify(ohlc?.candles || []), chartType]);
  return { chartRef, chartApi };
}

export function GasFuturesComponent(props: GasFuturesComponentProps) {
  const { address, network, protocolStatus, marketLabel, symbol, quoteSymbol = 'USDC', expiries = [], onExpiryChange, summary = {}, ohlc, orderbook, recentTrades = [], positions = [], openOrders = [], twap = [], TradePanelComponent } = props;
  const [tf, setTf] = useState<'1m' | '5m' | '15m' | '1h' | '1d' | '7d'>('1m');
  const [chartType, setChartType] = useState<'candles' | 'bars' | 'line'>('candles');
  const { chartRef, chartApi } = useChart(ohlc, chartType);
  const mid = useMemo(() => summary.last ?? (ohlc?.candles.at(-1)?.close ?? 0), [summary.last, ohlc]);

  useEffect(() => {
    const price = summary.last;
    if (price != null) document.title = `${price.toFixed(4)} | ${marketLabel} | Unxversal`;
    else document.title = `${marketLabel} | Unxversal`;
  }, [summary.last, marketLabel]);

  const formatExpiryDate = (timestamp?: number) => timestamp ? new Date(timestamp).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : '-';
  const formatExpiryCountdown = (ms?: number) => {
    if (ms == null || ms <= 0) return 'EXPIRED';
    const days = Math.floor(ms / 86_400_000);
    const hours = Math.floor((ms % 86_400_000) / 3_600_000);
    const minutes = Math.floor((ms % 3_600_000) / 60_000);
    if (days > 0) return `${days}d ${hours}h ${minutes}m`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  };

  return (
    <div className={styles.root}>
      <div className={styles.priceCard}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>
            {marketLabel}
            {expiries.length > 0 && (
              <select className={styles.expirySelector} value={expiries.find(e => e.isActive)?.id || expiries[0]?.id || ''} onChange={(e) => onExpiryChange?.(e.target.value)}>
                {expiries.map(e => <option key={e.id} value={e.id}>{e.label}</option>)}
              </select>
            )}
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}><div className={styles.metricValue}>{summary.last?.toFixed(0) ?? '-'}</div><div className={styles.metricLabel}>Gas Price</div></div>
            <div className={styles.metricItem}><div className={`${styles.metricValue} ${(summary.change24h ?? 0) >= 0 ? styles.positive : styles.negative}`}>{summary.change24h?.toFixed(2) ?? '-'}%</div><div className={styles.metricLabel}>Change</div></div>
            <div className={styles.metricItem}><div className={styles.metricValue}>{summary.vol24h?.toLocaleString() ?? '-'}</div><div className={styles.metricLabel}>24h Vol</div></div>
            <div className={styles.metricItem}><div className={styles.metricValue}>{summary.openInterest?.toLocaleString() ?? '-'}</div><div className={styles.metricLabel}>OI</div></div>
            {summary.expiryDate != null && (
              <>
                <div className={styles.metricItem}><div className={styles.metricValue}>{formatExpiryDate(summary.expiryDate)}</div><div className={styles.metricLabel}>Expiry</div></div>
                <div className={`${styles.metricItem} ${styles.fundingItem}`}><div className={styles.metricValue}><Clock size={10} />{formatExpiryCountdown(summary.timeToExpiry)}</div><div className={styles.metricLabel}>Time to Expiry</div></div>
              </>
            )}
          </div>
        </div>
      </div>

      <div className={styles.toolboxCard}>
        <div className={styles.toolbox}>
          {(['1m','5m','15m','1h','1d','7d'] as const).map(t => (
            <button key={t} className={tf === t ? styles.active : ''} onClick={() => setTf(t)}>{t}</button>
          ))}
          <div className={styles.toolboxDivider}></div>
          <button className={chartType === 'candles' ? styles.active : ''} onClick={() => setChartType('candles')}><CandlestickChart size={16} /></button>
          <button className={chartType === 'bars' ? styles.active : ''} onClick={() => setChartType('bars')}><BarChart3 size={16} /></button>
          <button className={chartType === 'line' ? styles.active : ''} onClick={() => setChartType('line')}><LineChart size={16} /></button>
          <div className={styles.toolboxDivider}></div>
          <button onClick={() => chartApi.current?.timeScale().fitContent()}><Eye size={16} /></button>
        </div>
      </div>

      <div className={styles.chartCard}>
        <div className={styles.chartContainer}>
          <div className={styles.chartArea}>
            {ohlc?.candles?.length ? (
              <div className={styles.ohlcDisplay}>
                <span className={styles.pair}>{symbol}</span>
                {(() => { const c = ohlc.candles.at(-1)!; return (
                  <>
                    <span className={styles.ohlcValue}>O {c.open.toFixed(0)}</span>
                    <span className={styles.ohlcValue}>H {c.high.toFixed(0)}</span>
                    <span className={styles.ohlcValue}>L {c.low.toFixed(0)}</span>
                    <span className={styles.ohlcValue}>C {c.close.toFixed(0)}</span>
                  </>
                ); })()}
              </div>
            ) : null}
            <div ref={chartRef} className={styles.chart} />
          </div>
        </div>
      </div>

      <div className={styles.center}>
        <div className={styles.centerTabs}>
          <button className={styles.active}>Orderbook</button>
          <button>Trades</button>
        </div>
        <div className={styles.orderbook}>
          <div className={styles.orderbookSide}>
            <table className={styles.ordersTable}>
              <thead><tr><th>Bid Price</th><th>Qty</th></tr></thead>
              <tbody>
                {(orderbook?.bids || []).slice(0, 20).map(([p, q], i) => (
                  <tr key={`b-${i}`}><td className={styles.longText}>{p.toFixed(0)}</td><td>{q}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className={styles.orderbookSide}>
            <table className={styles.ordersTable}>
              <thead><tr><th>Ask Price</th><th>Qty</th></tr></thead>
              <tbody>
                {(orderbook?.asks || []).slice(0, 20).map(([p, q], i) => (
                  <tr key={`a-${i}`}><td className={styles.shortText}>{p.toFixed(0)}</td><td>{q}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div className={styles.right}>
        {TradePanelComponent ? (
          <TradePanelComponent baseSymbol={symbol} quoteSymbol={quoteSymbol} mid={mid} />
        ) : null}
      </div>

      <div className={styles.bottomSection}>
        <div className={styles.activityCard}>
          <div className={styles.activityTabs}>
            <button className={styles.active}>Positions</button>
            <button>Open Orders</button>
            <button>TWAP</button>
            <button>Trade History</button>
            <button>Order History</button>
          </div>
          <div className={styles.activityContent}>
            <table className={styles.ordersTable}>
              <thead>
                <tr>
                  <th>Side</th>
                  <th>Size</th>
                  <th>Entry</th>
                  <th>Mark</th>
                  <th>PnL</th>
                  <th>Margin</th>
                  <th>Lev</th>
                </tr>
              </thead>
              <tbody>
                {(positions || []).map((p, i) => (
                  <tr key={p.id || i}>
                    <td className={p.side === 'Long' ? styles.longText : styles.shortText}>{p.side}</td>
                    <td>{p.size}</td>
                    <td>{p.entryPrice}</td>
                    <td>{p.markPrice}</td>
                    <td className={typeof p.pnl === 'string' ? (p.pnl.startsWith('+') ? styles.positive : styles.negative) : (Number(p.pnl) >= 0 ? styles.positive : styles.negative)}>{p.pnl}</td>
                    <td>{p.margin}</td>
                    <td>{p.leverage}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
        <div className={styles.pointsCard}>
          <div className={styles.pointsHeader}>Your Rank</div>
          <div className={styles.pointsStats}>
            <div className={styles.pointsStat}><span>Rank:</span><span>-</span></div>
            <div className={styles.pointsStat}><span>Points:</span><span>-</span></div>
          </div>
          <div className={styles.pointsMessage}>Connect your wallet to see your position</div>
        </div>
      </div>

      <footer className={styles.footer}>
        <div className={styles.statusBadges}>
          <div className={`${styles.badge} ${protocolStatus?.options ? styles.connected : styles.disconnected}`}><div className={`${styles.dot} ${protocolStatus?.options ? styles.dotConnected : styles.dotDisconnected}`}></div><span>Options</span></div>
          <div className={`${styles.badge} ${protocolStatus?.futures ? styles.connected : styles.disconnected}`}><div className={`${styles.dot} ${protocolStatus?.futures ? styles.dotConnected : styles.dotDisconnected}`}></div><span>Futures</span></div>
          <div className={`${styles.badge} ${protocolStatus?.perps ? styles.connected : styles.disconnected}`}><div className={`${styles.dot} ${protocolStatus?.perps ? styles.dotConnected : styles.dotDisconnected}`}></div><span>Perps</span></div>
          <div className={`${styles.badge} ${protocolStatus?.lending ? styles.connected : styles.disconnected}`}><div className={`${styles.dot} ${protocolStatus?.lending ? styles.dotConnected : styles.dotDisconnected}`}></div><span>Lending</span></div>
          <div className={`${styles.badge} ${protocolStatus?.staking ? styles.connected : styles.disconnected}`}><div className={`${styles.dot} ${protocolStatus?.staking ? styles.dotConnected : styles.dotDisconnected}`}></div><span>Staking</span></div>
          <div className={`${styles.badge} ${protocolStatus?.dex ? styles.connected : styles.disconnected}`}><div className={`${styles.dot} ${protocolStatus?.dex ? styles.dotConnected : styles.dotDisconnected}`}></div><span>DEX</span></div>
        </div>
        <div className={styles.networkBadge}><span>{(network || 'testnet').toUpperCase()}</span></div>
      </footer>
    </div>
  );
}

export default GasFuturesComponent;


