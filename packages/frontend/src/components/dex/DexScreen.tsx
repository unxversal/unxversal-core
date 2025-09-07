import { useEffect, useMemo, useRef, useState } from 'react';
import styles from './DexScreen.module.css';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { createChart, type IChartApi, type CandlestickData, type UTCTimestamp, CandlestickSeries, LineSeries, BarSeries } from 'lightweight-charts';
import { Orderbook } from './Orderbook';
import { Trades } from './Trades';
import { TradePanel } from './TradePanel';
import { Tooltip } from './Tooltip';
import { loadSettings } from '../../lib/settings.config';
import { useCurrentAccount } from '@mysten/dapp-kit';
import { Wifi, WifiOff, Activity, Pause, TrendingUp, Minus, BarChart3, Crosshair, Square, LineChart, CandlestickChart, Waves, Eye } from 'lucide-react';

export function DexScreen({ started, surgeReady, network }: { started?: boolean; surgeReady?: boolean; network?: string }) {
  const s = loadSettings();
  const deepbookIndexerUrl = s.dex.deepbookIndexerUrl;
  const pool = s.dex.poolId.replace(/[\/-]/g, '_').toUpperCase();
  const displayPair = s.dex.poolId.replace(/[\/_]/g, '-').toUpperCase();
  const db = useMemo(() => buildDeepbookPublicIndexer(deepbookIndexerUrl), [deepbookIndexerUrl]);
  const account = useCurrentAccount();

  const [summary, setSummary] = useState<{ last?: number; vol24h?: number; high24h?: number; low24h?: number; change24h?: number }>({});
  const [mid, setMid] = useState<number>(0);
  const [centerTab, setCenterTab] = useState<'orderbook' | 'trades'>('orderbook');
  const [activityTab, setActivityTab] = useState<'orders' | 'history' | 'trades'>('orders');
  const chartRef = useRef<HTMLDivElement | null>(null);
  const chartApi = useRef<IChartApi | null>(null);
  const [tf, setTf] = useState<'1m' | '5m' | '15m' | '1h' | '1d' | '7d'>('1m');
  const [chartType, setChartType] = useState<'candles' | 'bars' | 'line'>('candles');
  const [showVolume, setShowVolume] = useState<boolean>(false);
  const [activeTool, setActiveTool] = useState<'none' | 'crosshair' | 'trend' | 'hline' | 'vline' | 'rect'>('none');
  const [showSMA, setShowSMA] = useState<boolean>(false);
  const [showEMA, setShowEMA] = useState<boolean>(false);
  const [showBB, setShowBB] = useState<boolean>(false);
  const [ohlc, setOhlc] = useState<{o: number, h: number, l: number, c: number, v: number} | null>(null);
  const dataRef = useRef<CandlestickData<UTCTimestamp>[]>([]);
  const drawingsRef = useRef<any[]>([]);
  const indicatorsRef = useRef<{sma?: any, ema?: any, bbUpper?: any, bbLower?: any}>({});

  // Sample data for testing
  const sampleOrders = [
    { id: '1', type: 'Limit', side: 'Buy', amount: '1,250.00', price: '1.2345', total: '1,543.13', status: 'Open' },
    { id: '2', type: 'Limit', side: 'Sell', amount: '800.50', price: '1.2890', total: '1,031.84', status: 'Partial' },
    { id: '3', type: 'Market', side: 'Buy', amount: '2,100.00', price: '1.2456', total: '2,615.76', status: 'Open' },
  ];

  const sampleHistory = [
    { id: '1', type: 'Limit', side: 'Buy', amount: '500.00', price: '1.2234', total: '611.70', status: 'Filled', time: '14:23:45' },
    { id: '2', type: 'Market', side: 'Sell', amount: '750.25', price: '1.2456', total: '934.81', status: 'Filled', time: '13:45:12' },
    { id: '3', type: 'Limit', side: 'Buy', amount: '1,000.00', price: '1.2100', total: '1,210.00', status: 'Cancelled', time: '12:30:20' },
  ];

  const sampleTrades = [
    { id: '1', side: 'Buy', amount: '500.00', price: '1.2234', total: '611.70', fee: '1.22', time: '14:23:45' },
    { id: '2', side: 'Sell', amount: '750.25', price: '1.2456', total: '934.81', fee: '1.87', time: '13:45:12' },
    { id: '3', side: 'Buy', amount: '300.00', price: '1.2190', total: '365.70', fee: '0.73', time: '12:15:30' },
  ];

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        let m: any | undefined;
        try {
          const tick = await db.ticker();
          m = Object.values(tick)[0] as any;
        } catch {}
        if (!mounted) return;
        if (!m) {
          setSummary({ last: 1.2345, vol24h: 123456, high24h: 1.45, low24h: 1.12, change24h: 3.2 });
        } else {
          const change = m?.price_change_percent ?? ((m?.last_price - m?.open_price) / m?.open_price) * 100;
          setSummary({ last: m?.last_price, vol24h: m?.quote_volume, high24h: m?.high_price, low24h: m?.low_price, change24h: change });
        }
      } catch {}
    };
    void load();
    const id = setInterval(load, 3000);
    return () => { mounted = false; clearInterval(id); };
  }, [db]);

  // Update document title with price and pair info
  useEffect(() => {
    const price = summary.last;
    if (price) {
      document.title = `${price.toFixed(4)} | ${displayPair} | Unxversal DEX`;
    } else {
      document.title = `${displayPair} | Unxversal DEX`;
    }

    // No cleanup needed - App.tsx will handle title management when switching views
  }, [summary.last, displayPair]);

  useEffect(() => {
    let disposed = false;
    if (!chartRef.current) return;
    const chart = createChart(chartRef.current, {
      layout: { background: { color: '#0a0c12' }, textColor: '#e5e7eb' },
      rightPriceScale: { borderColor: '#1b1e27' },
      timeScale: { borderColor: '#1b1e27' },
      grid: { horzLines: { color: '#12141a' }, vertLines: { color: '#12141a' } },
      crosshair: { mode: activeTool === 'crosshair' ? 0 : 1 },
    });
    
    // Main price series based on chart type
    let priceSeries: any;
    if (chartType === 'candles') {
      priceSeries = chart.addSeries(CandlestickSeries, {
        upColor: '#10b981', downColor: '#ef4444', borderVisible: false, wickUpColor: '#10b981', wickDownColor: '#ef4444',
      });
    } else if (chartType === 'bars') {
      priceSeries = chart.addSeries(BarSeries, {
        upColor: '#10b981', downColor: '#ef4444', thinBars: true,
      });
    } else {
      priceSeries = chart.addSeries(LineSeries, {
        color: '#10b981', lineWidth: 2,
      });
    }
    
    // Volume histogram - try histogram series, fallback to line series
    const vol = (chart as any).addHistogramSeries ? 
      (chart as any).addHistogramSeries({ 
        color: 'rgba(100, 116, 139, 0.6)', 
        priceFormat: { type: 'volume' }, 
        priceScaleId: '' 
      }) : 
      chart.addSeries(LineSeries, { color: 'rgba(100, 116, 139, 0.6)', lineWidth: 1 });
    
    // Technical indicators
    if (showSMA) {
      indicatorsRef.current.sma = chart.addSeries(LineSeries, { color: '#60a5fa', lineWidth: 2 });
    }
    if (showEMA) {
      indicatorsRef.current.ema = chart.addSeries(LineSeries, { color: '#f59e0b', lineWidth: 2 });
    }
    if (showBB) {
      indicatorsRef.current.bbUpper = chart.addSeries(LineSeries, { color: '#9ca3af', lineWidth: 1 });
      indicatorsRef.current.bbLower = chart.addSeries(LineSeries, { color: '#9ca3af', lineWidth: 1 });
    }
    
    chartApi.current = chart;
    (async () => {
      try {
        // Try live trades; fallback to synthetic sample OHLC + volume
        let data: CandlestickData<UTCTimestamp>[] | undefined;
        try {
          const trades = await db.trades(pool, { limit: 400 });
          const bucket = new Map<number, { o: number; h: number; l: number; c: number; v: number }>();
          const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
          for (const t of trades) {
            const bucketed = (Math.floor(t.ts / step) * step) as UTCTimestamp;
            const b = bucket.get(bucketed) ?? { o: t.price, h: t.price, l: t.price, c: t.price, v: 0 };
            b.h = Math.max(b.h, t.price); b.l = Math.min(b.l, t.price); b.c = t.price; b.v += t.qty ?? 0; bucket.set(bucketed, b);
          }
          data = Array.from(bucket.entries()).sort((a,b)=>a[0]-b[0]).map(([time, v]) => ({ time: time as UTCTimestamp, open: v.o, high: v.h, low: v.l, close: v.c }));
          const volData = Array.from(bucket.entries()).sort((a,b)=>a[0]-b[0]).map(([time, v]) => ({ time: time as UTCTimestamp, value: v.v }));
          if (vol) vol.setData(showVolume ? volData : []);
        } catch {}
        if (!data) {
          // synthetic sample data - sine wave + noise
          const now = Math.floor(Date.now()/1000);
          const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
          const points: CandlestickData<UTCTimestamp>[] = [];
          const vols: { time: UTCTimestamp; value: number }[] = [];
          let base = 1.2;
          for (let i = 300; i >= 0; i--) {
            const time = (now - i*step) as UTCTimestamp;
            const noise = (Math.sin(i/8) + Math.random()*0.2 - 0.1) * 0.02;
            const open = base;
            const close = base + noise;
            const high = Math.max(open, close) + Math.random()*0.01;
            const low = Math.min(open, close) - Math.random()*0.01;
            base = close;
            points.push({ time, open, high, low, close });
            vols.push({ time, value: Math.round(100 + Math.random()*50) });
          }
          data = points;
          vol.setData(showVolume ? vols : []);
        }
        
        dataRef.current = data;
        if (chartType === 'line') {
          priceSeries.setData(data.map(d => ({ time: d.time, value: d.close })));
        } else {
          priceSeries.setData(data);
        }
        
        // Calculate and set indicators
        if (showSMA && indicatorsRef.current.sma) {
          const smaData = calculateSMA(data, 20);
          indicatorsRef.current.sma.setData(smaData);
        }
        if (showEMA && indicatorsRef.current.ema) {
          const emaData = calculateEMA(data, 21);
          indicatorsRef.current.ema.setData(emaData);
        }
        if (showBB && indicatorsRef.current.bbUpper && indicatorsRef.current.bbLower) {
          const bbData = calculateBollingerBands(data, 20, 2);
          indicatorsRef.current.bbUpper.setData(bbData.upper);
          indicatorsRef.current.bbLower.setData(bbData.lower);
        }
        
        // Update OHLC display with latest data
        if (data.length > 0) {
          const latest = data[data.length - 1];
          const vol24h = data.slice(-24).reduce((sum, d) => sum + ((d as any).volume || 0), 0);
          setOhlc({
            o: latest.open,
            h: latest.high,
            l: latest.low,
            c: latest.close,
            v: vol24h
          });
        }
        
        chart.timeScale().fitContent();
      } catch {}
    })();
    const resize = () => {
      if (!chartRef.current) return;
      const rect = chartRef.current.getBoundingClientRect();
      chart.applyOptions({ width: rect.width, height: rect.height });
    };
    resize();
    window.addEventListener('resize', resize);
    
    // Drawing tools interaction
    chart.subscribeClick((param) => {
      if (!param || !param.time || activeTool === 'none') return;
      const seriesData = param.seriesData.get(priceSeries);
      const price = (seriesData as any)?.close || (seriesData as any)?.value;
      
      if (activeTool === 'hline' && price !== undefined) {
        const line = priceSeries.createPriceLine({
          price: price,
          color: '#3b82f6',
          lineWidth: 1,
          lineStyle: 0,
        });
        drawingsRef.current.push(line);
        setActiveTool('none');
      } else if (activeTool === 'vline') {
        // Vertical line implementation would need custom drawing
        setActiveTool('none');
      }
    });
    
    return () => { 
      if (!disposed) { 
        chart.remove(); 
        indicatorsRef.current = {};
      } 
      disposed = true; 
      window.removeEventListener('resize', resize); 
    };
  }, [db, pool, tf, chartType, showVolume, activeTool, showSMA, showEMA, showBB]);
  
  // Helper functions for technical indicators
  const calculateSMA = (data: CandlestickData<UTCTimestamp>[], period: number) => {
    const result: {time: UTCTimestamp, value: number}[] = [];
    for (let i = period - 1; i < data.length; i++) {
      const sum = data.slice(i - period + 1, i + 1).reduce((acc, d) => acc + d.close, 0);
      result.push({ time: data[i].time, value: sum / period });
    }
    return result;
  };
  
  const calculateEMA = (data: CandlestickData<UTCTimestamp>[], period: number) => {
    const result: {time: UTCTimestamp, value: number}[] = [];
    const multiplier = 2 / (period + 1);
    let ema = data[0].close;
    
    for (let i = 0; i < data.length; i++) {
      if (i === 0) {
        ema = data[i].close;
      } else {
        ema = (data[i].close - ema) * multiplier + ema;
      }
      result.push({ time: data[i].time, value: ema });
    }
    return result;
  };
  
  const calculateBollingerBands = (data: CandlestickData<UTCTimestamp>[], period: number, stdDev: number) => {
    const upper: {time: UTCTimestamp, value: number}[] = [];
    const lower: {time: UTCTimestamp, value: number}[] = [];
    
    for (let i = period - 1; i < data.length; i++) {
      const slice = data.slice(i - period + 1, i + 1);
      const sma = slice.reduce((acc, d) => acc + d.close, 0) / period;
      const variance = slice.reduce((acc, d) => acc + Math.pow(d.close - sma, 2), 0) / period;
      const std = Math.sqrt(variance);
      
      upper.push({ time: data[i].time, value: sma + (std * stdDev) });
      lower.push({ time: data[i].time, value: sma - (std * stdDev) });
    }
    
    return { upper, lower };
  };

  return (
    <div className={styles.root}>
      {/* Price Header Card */}
      <div className={styles.priceCard}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>DEX / {displayPair}</div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.last ?? '-'}</div>
              <div className={styles.metricLabel}>Price</div>
            </div>
            <div className={styles.metricItem}>
              <div className={`${styles.metricValue} ${summary.change24h && summary.change24h >= 0 ? styles.positive : styles.negative}`}>
                {summary.change24h?.toFixed?.(2) ?? '-'}%
              </div>
              <div className={styles.metricLabel}>Change</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.high24h ?? '-'}</div>
              <div className={styles.metricLabel}>24h High</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.low24h ?? '-'}</div>
              <div className={styles.metricLabel}>24h Low</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.vol24h ?? '-'}</div>
              <div className={styles.metricLabel}>24h Vol</div>
            </div>
          </div>
        </div>
      </div>

      {/* Toolbox Card */}
      <div className={styles.toolboxCard}>
        <div className={styles.toolbox}>
            {/* Timeframes */}
            {(['1m','5m','15m','1h','1d','7d'] as const).map(t => (
              <Tooltip key={t} content={`${t} Timeframe`}>
                <button 
                  className={tf === t ? styles.active : ''}
                  onClick={() => setTf(t)}
                >
                  {t}
                </button>
              </Tooltip>
            ))}
            
            <div className={styles.toolboxDivider}></div>
            
            {/* Chart Types */}
            <Tooltip content="Candlestick Chart">
              <button 
                className={chartType === 'candles' ? styles.active : ''} 
                onClick={() => setChartType('candles')}
              >
                <CandlestickChart size={16} />
              </button>
            </Tooltip>
            <Tooltip content="Bar Chart">
              <button 
                className={chartType === 'bars' ? styles.active : ''}
                onClick={() => setChartType('bars')}
              >
                <BarChart3 size={16} />
              </button>
            </Tooltip>
            <Tooltip content="Line Chart">
              <button 
                className={chartType === 'line' ? styles.active : ''}
                onClick={() => setChartType('line')}
              >
                <LineChart size={16} />
              </button>
            </Tooltip>
            
            <div className={styles.toolboxDivider}></div>
            
            {/* Volume & Indicators */}
            <Tooltip content="Toggle Volume">
              <button 
                className={showVolume ? styles.active : ''} 
                onClick={() => setShowVolume(v => !v)}
              >
                <Waves size={16} />
              </button>
            </Tooltip>
            <Tooltip content="Simple Moving Average (20)">
              <button 
                className={showSMA ? styles.active : ''}
                onClick={() => setShowSMA(v => !v)}
              >
                SMA
              </button>
            </Tooltip>
            <Tooltip content="Exponential Moving Average (21)">
              <button 
                className={showEMA ? styles.active : ''}
                onClick={() => setShowEMA(v => !v)}
              >
                EMA
              </button>
            </Tooltip>
            <Tooltip content="Bollinger Bands (20, 2)">
              <button 
                className={showBB ? styles.active : ''}
                onClick={() => setShowBB(v => !v)}
              >
                BB
              </button>
            </Tooltip>
            
            <div className={styles.toolboxDivider}></div>
            
            {/* Drawing Tools */}
            <Tooltip content="Enable/Disable Crosshair">
              <button 
                className={activeTool === 'crosshair' ? styles.active : ''}
                onClick={() => setActiveTool(activeTool === 'crosshair' ? 'none' : 'crosshair')}
              >
                <Crosshair size={16} />
              </button>
            </Tooltip>
            <Tooltip content="Trend Line Tool (2-click)">
              <button 
                className={activeTool === 'trend' ? styles.active : ''}
                onClick={() => setActiveTool(activeTool === 'trend' ? 'none' : 'trend')}
              >
                <TrendingUp size={16} />
              </button>
            </Tooltip>
            <Tooltip content="Horizontal Line Tool">
              <button 
                className={activeTool === 'hline' ? styles.active : ''}
                onClick={() => setActiveTool(activeTool === 'hline' ? 'none' : 'hline')}
              >
                <Minus size={16} />
              </button>
            </Tooltip>
            <Tooltip content="Vertical Line Tool (Coming Soon)">
              <button 
                className={activeTool === 'vline' ? styles.active : ''}
                onClick={() => setActiveTool(activeTool === 'vline' ? 'none' : 'vline')}
              >
                <BarChart3 size={16} style={{ transform: 'rotate(90deg)' }} />
              </button>
            </Tooltip>
            <Tooltip content="Rectangle Tool (Coming Soon)">
              <button 
                className={activeTool === 'rect' ? styles.active : ''}
                onClick={() => setActiveTool(activeTool === 'rect' ? 'none' : 'rect')}
              >
                <Square size={16} />
              </button>
            </Tooltip>
            
            <div className={styles.toolboxDivider}></div>
            
            {/* Utilities */}
            <Tooltip content="Fit Chart to Screen">
              <button 
                onClick={() => chartApi.current?.timeScale().fitContent()}
              >
                <Eye size={16} />
              </button>
            </Tooltip>
        </div>
      </div>

      {/* Chart Card */}
      <div className={styles.chartCard}>
        <div className={styles.chartContainer}>
          <div className={styles.chartArea}>
            {ohlc && (
              <div className={styles.ohlcDisplay}>
                <span className={styles.pair}>{displayPair}</span>
                <span className={styles.ohlcValue}>O {ohlc.o.toFixed(4)}</span>
                <span className={styles.ohlcValue}>H {ohlc.h.toFixed(4)}</span>
                <span className={styles.ohlcValue}>L {ohlc.l.toFixed(4)}</span>
                <span className={styles.ohlcValue}>C {ohlc.c.toFixed(4)}</span>
                <span className={styles.ohlcValue}>Vol {ohlc.v.toFixed(2)}</span>
              </div>
            )}
            
            <div ref={chartRef} className={styles.chart} />
          </div>
        </div>
      </div>
      
      <div className={styles.center}>
        <div className={styles.centerTabs}>
          <button className={centerTab==='orderbook'? styles.active:''} onClick={()=>setCenterTab('orderbook')}>Orderbook</button>
          <button className={centerTab==='trades'? styles.active:''} onClick={()=>setCenterTab('trades')}>Trades</button>
        </div>
        {centerTab==='orderbook' ? (
          <Orderbook pool={pool} indexer={db} onMidChange={setMid} />
        ) : (
          <Trades pool={pool} indexer={db} />
        )}
      </div>
      
      <div className={styles.right}>
        <TradePanel pool={pool} mid={mid} />
      </div>
      
      <div className={styles.bottomSection}>
        <div className={styles.activityCard}>
          <div className={styles.activityTabs}>
            <button 
              className={activityTab === 'orders' ? styles.active : ''} 
              onClick={() => setActivityTab('orders')}
            >
              Open Orders
            </button>
            <button 
              className={activityTab === 'history' ? styles.active : ''} 
              onClick={() => setActivityTab('history')}
            >
              Order History
            </button>
            <button 
              className={activityTab === 'trades' ? styles.active : ''} 
              onClick={() => setActivityTab('trades')}
            >
              Trade History
            </button>
          </div>
          <div className={styles.activityContent}>
            {activityTab === 'orders' && (
              <>
                {sampleOrders.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Type</th>
                        <th>Side</th>
                        <th>Amount</th>
                        <th>Price</th>
                        <th>Total</th>
                        <th>Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleOrders.map(order => (
                        <tr key={order.id}>
                          <td>{order.type}</td>
                          <td className={order.side === 'Buy' ? styles.buyText : styles.sellText}>
                            {order.side}
                          </td>
                          <td>{order.amount}</td>
                          <td>{order.price}</td>
                          <td>{order.total}</td>
                          <td>{order.status}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No open orders yet.</div>
                )}
              </>
            )}
            
            {activityTab === 'history' && (
              <>
                {sampleHistory.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Type</th>
                        <th>Side</th>
                        <th>Amount</th>
                        <th>Price</th>
                        <th>Total</th>
                        <th>Status</th>
                        <th>Time</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleHistory.map(order => (
                        <tr key={order.id}>
                          <td>{order.type}</td>
                          <td className={order.side === 'Buy' ? styles.buyText : styles.sellText}>
                            {order.side}
                          </td>
                          <td>{order.amount}</td>
                          <td>{order.price}</td>
                          <td>{order.total}</td>
                          <td>{order.status}</td>
                          <td>{order.time}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No order history yet.</div>
                )}
              </>
            )}
            
            {activityTab === 'trades' && (
              <>
                {sampleTrades.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Side</th>
                        <th>Amount</th>
                        <th>Price</th>
                        <th>Total</th>
                        <th>Fee</th>
                        <th>Time</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleTrades.map(trade => (
                        <tr key={trade.id}>
                          <td className={trade.side === 'Buy' ? styles.buyText : styles.sellText}>
                            {trade.side}
                          </td>
                          <td>{trade.amount}</td>
                          <td>{trade.price}</td>
                          <td>{trade.total}</td>
                          <td>{trade.fee}</td>
                          <td>{trade.time}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No trades yet.</div>
                )}
              </>
            )}
          </div>
        </div>

        <div className={styles.pointsCard}>
          <div className={styles.pointsHeader}>Your rank</div>
          <div className={styles.pointsStats}>
            <div className={styles.pointsStat}>
              <span>Rank:</span>
              <span>-</span>
            </div>
            <div className={styles.pointsStat}>
              <span>Points:</span>
              <span>-</span>
            </div>
          </div>
          <div className={styles.pointsMessage}>
            Connect your wallet to see your position
          </div>
        </div>
      </div>

      <footer className={styles.footer}>
        <div className={styles.statusBadges}>
          <div className={`${styles.badge} ${account?.address ? styles.connected : styles.disconnected}`}>
            {account?.address ? <Wifi size={10} /> : <WifiOff size={10} />}
            <span>{account?.address ? 'Online' : 'Offline'}</span>
          </div>
          
          <div className={`${styles.badge} ${started ? styles.active : styles.inactive}`}>
            {started ? <Activity size={10} /> : <Pause size={10} />}
            <span>IDX</span>
          </div>
          
          <div className={`${styles.badge} ${surgeReady ? styles.active : styles.inactive}`}>
            {surgeReady ? <Activity size={10} /> : <Pause size={10} />}
            <span>PRC</span>
          </div>
        </div>
        
        <div className={styles.networkBadge}>
          <span>{(network || 'testnet').toUpperCase()}</span>
        </div>
      </footer>
    </div>
  );
}



