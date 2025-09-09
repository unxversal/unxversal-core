import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import styles from './OptionsScreen.module.css';
import { createChart, type IChartApi, type CandlestickData, type UTCTimestamp, CandlestickSeries, LineSeries, BarSeries } from 'lightweight-charts';
import { Tooltip } from '../dex/Tooltip';
import { useCurrentAccount } from '@mysten/dapp-kit';
import { BarChart3, CandlestickChart, Clock, Eye, LineChart, Minus, Square, TrendingUp, Waves, Crosshair } from 'lucide-react';
import { OptionsChain } from './components/OptionsChain';
import { OptionsTradePanel } from './components/OptionsTradePanel';
import type { OptionsDataProvider } from './types';

export function OptionsScreen({ started, surgeReady, network, marketLabel, symbol, quoteSymbol = 'USDC', dataProvider, panelProvider }: {
  started?: boolean;
  surgeReady?: boolean;
  network?: string;
  marketLabel: string;
  symbol: string;
  quoteSymbol?: string;
  dataProvider?: OptionsDataProvider;
  panelProvider?: any;
}) {
  const account = useCurrentAccount();

  const [summary, setSummary] = useState<{ 
    last?: number; 
    vol24h?: number; 
    high24h?: number; 
    low24h?: number; 
    change24h?: number;
    openInterest?: number;
    iv30?: number;
    nextExpiry?: number;
  }>({});
  const [mid, setMid] = useState<number>(0);
  const [showTradePanel, setShowTradePanel] = useState<boolean>(false);
  const [selectedOption, setSelectedOption] = useState<{strike: number, isCall: boolean, price: number} | null>(null);
  const [activityTab, setActivityTab] = useState<'positions' | 'open-orders' | 'trade-history' | 'order-history'>('positions');
  const chartRef = useRef<HTMLDivElement | null>(null);
  const chartApi = useRef<IChartApi | null>(null);
  const [tf, setTf] = useState<'1m' | '5m' | '15m' | '1h' | '1d' | '7d'>('1m');
  const [chartType, setChartType] = useState<'candles' | 'bars' | 'line'>('candles');
  const [showVolume, setShowVolume] = useState<boolean>(false);
  const [activeTool, setActiveTool] = useState<'none' | 'crosshair' | 'trend' | 'hline' | 'rect'>('none');
  const [showSMA, setShowSMA] = useState<boolean>(false);
  const [showEMA, setShowEMA] = useState<boolean>(false);
  const [showBB, setShowBB] = useState<boolean>(false);
  const [ohlc, setOhlc] = useState<{o: number, h: number, l: number, c: number, v: number} | null>(null);
  const dataRef = useRef<CandlestickData<UTCTimestamp>[]>([]);
  const indicatorsRef = useRef<{sma?: any, ema?: any, bbUpper?: any, bbLower?: any}>({});

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        if (dataProvider?.getSummary) {
          const s = await dataProvider.getSummary();
          if (!mounted) return;
          setSummary(s);
        } else {
          if (!mounted) return;
          setSummary({ 
            last: 0.97, 
            vol24h: 120000,
            high24h: 1.12, 
            low24h: 0.86, 
            change24h: 1.85,
            openInterest: 580000,
            iv30: 0.58,
            nextExpiry: Date.now() + 5 * 24 * 60 * 60 * 1000,
          });
        }
      } catch {}
    };
    void load();
    const id = setInterval(load, 3000);
    return () => { mounted = false; clearInterval(id); };
  }, [dataProvider]);

  useEffect(() => {
    const price = summary.last;
    if (price) {
      document.title = `${price.toFixed(4)} | ${marketLabel} | Unxversal`;
    } else {
      document.title = `${marketLabel} | Unxversal`;
    }
  }, [summary.last, marketLabel]);

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

    const vol = (chart as any).addHistogramSeries ? 
      (chart as any).addHistogramSeries({ 
        color: 'rgba(100, 116, 139, 0.6)', 
        priceFormat: { type: 'volume' }, 
        priceScaleId: '' 
      }) : 
      chart.addSeries(LineSeries, { color: 'rgba(100, 116, 139, 0.6)', lineWidth: 1 });

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
        const now = Math.floor(Date.now()/1000);
        const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
        let data: CandlestickData<UTCTimestamp>[] = [];
        let vols: { time: UTCTimestamp; value: number }[] = [];
        if (dataProvider?.getOhlc) {
          try {
            const r = await dataProvider.getOhlc(tf);
            data = r.candles.map(c => ({ time: c.time as UTCTimestamp, open: c.open, high: c.high, low: c.low, close: c.close }));
            vols = (r.volumes ?? []).map(v => ({ time: v.time as UTCTimestamp, value: v.value }));
          } catch {}
        }
        if (data.length === 0) {
          const points: CandlestickData<UTCTimestamp>[] = [];
          const volData: { time: UTCTimestamp; value: number }[] = [];
          // Use summary.last as the target final price, defaulting to 1.0
          const targetPrice = summary.last || 1.0;
          let base = targetPrice * 0.95; // Start slightly below target
          for (let i = 300; i >= 0; i--) {
            const time = (now - i*step) as UTCTimestamp;
            // Trend towards target price over time with noise
            const progress = (300 - i) / 300; // 0 to 1
            const trend = base + (targetPrice - base) * progress * 0.1;
            const noise = (Math.sin(i/12) + Math.random()*0.3 - 0.15) * 0.05;
            const open = base;
            const close = Math.max(0.2, trend + noise);
            const high = Math.max(open, close) + Math.random()*0.03;
            const low = Math.max(0.2, Math.min(open, close) - Math.random()*0.03);
            base = close;
            points.push({ time, open, high, low, close });
            volData.push({ time, value: Math.round(500 + Math.random()*300) });
          }
          // Ensure the final price is close to the target
          if (points.length > 0) {
            points[points.length - 1].close = targetPrice;
          }
          data = points;
          vols = volData;
        }
        vol.setData(showVolume ? vols : []);
        dataRef.current = data;
        if (chartType === 'line') {
          priceSeries.setData(data.map(d => ({ time: d.time as UTCTimestamp, value: d.close })) as { time: UTCTimestamp; value: number }[]);
        } else {
          priceSeries.setData(data);
        }
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
        if (data.length > 0) {
          const latest = data[data.length - 1];
          const vol24h = data.slice(-24).reduce((sum, d) => sum + ((d as any).volume || 0), 0);
          setOhlc({ o: latest.open, h: latest.high, l: latest.low, c: latest.close, v: vol24h });
          setMid(latest.close);
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

    return () => { 
      if (!disposed) { chart.remove(); indicatorsRef.current = {}; } 
      disposed = true; 
      window.removeEventListener('resize', resize); 
    };
  }, [tf, chartType, showVolume, activeTool, showSMA, showEMA, showBB, dataProvider, summary.last]);

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
      if (i === 0) ema = data[i].close; else ema = (data[i].close - ema) * multiplier + ema;
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

  const formatCountdown = (timestamp: number) => {
    const diff = timestamp - Date.now();
    if (diff <= 0) return '00:00:00';
    const hours = Math.floor(diff / 3600000);
    const minutes = Math.floor((diff % 3600000) / 60000);
    const seconds = Math.floor((diff % 60000) / 1000);
    return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  };

  return (
    <div className={styles.root}>
      <div className={styles.priceCard}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>
            {marketLabel}
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.last?.toFixed(4) ?? '-'}</div>
              <div className={styles.metricLabel}>Price</div>
            </div>
            <div className={styles.metricItem}>
              <div className={`${styles.metricValue} ${summary.change24h && summary.change24h >= 0 ? styles.positive : styles.negative}`}>
                {summary.change24h?.toFixed(2) ?? '-'}%
              </div>
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
            {summary.iv30 !== undefined && (
              <div className={styles.metricItem}>
                <div className={styles.metricValue}>{(summary.iv30 * 100).toFixed(2)}%</div>
                <div className={styles.metricLabel}>IV30</div>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className={styles.toolboxCard}>
        <div className={styles.toolbox}>
          {(['1m','5m','15m','1h','1d','7d'] as const).map(t => (
            <Tooltip key={t} content={`${t} Timeframe`}>
              <button className={tf === t ? styles.active : ''} onClick={() => setTf(t)}>{t}</button>
            </Tooltip>
          ))}
          <div className={styles.toolboxDivider}></div>
          <Tooltip content="Candlestick Chart">
            <button className={chartType === 'candles' ? styles.active : ''} onClick={() => setChartType('candles')}>
              <CandlestickChart size={16} />
            </button>
          </Tooltip>
          <Tooltip content="Bar Chart">
            <button className={chartType === 'bars' ? styles.active : ''} onClick={() => setChartType('bars')}>
              <BarChart3 size={16} />
            </button>
          </Tooltip>
          <Tooltip content="Line Chart">
            <button className={chartType === 'line' ? styles.active : ''} onClick={() => setChartType('line')}>
              <LineChart size={16} />
            </button>
          </Tooltip>
          <div className={styles.toolboxDivider}></div>
          <Tooltip content="Toggle Volume">
            <button className={showVolume ? styles.active : ''} onClick={() => setShowVolume(v => !v)}>
              <Waves size={16} />
            </button>
          </Tooltip>
          <Tooltip content="Simple Moving Average (20)">
            <button className={showSMA ? styles.active : ''} onClick={() => setShowSMA(v => !v)}>SMA</button>
          </Tooltip>
          <Tooltip content="Exponential Moving Average (21)">
            <button className={showEMA ? styles.active : ''} onClick={() => setShowEMA(v => !v)}>EMA</button>
          </Tooltip>
          <Tooltip content="Bollinger Bands (20, 2)">
            <button className={showBB ? styles.active : ''} onClick={() => setShowBB(v => !v)}>BB</button>
          </Tooltip>
          <div className={styles.toolboxDivider}></div>
          <Tooltip content="Enable/Disable Crosshair">
            <button className={activeTool === 'crosshair' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'crosshair' ? 'none' : 'crosshair')}>
              <Crosshair size={16} />
            </button>
          </Tooltip>
          <Tooltip content="Trend Line Tool">
            <button className={activeTool === 'trend' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'trend' ? 'none' : 'trend')}>
              <TrendingUp size={16} />
            </button>
          </Tooltip>
          <Tooltip content="Horizontal Line Tool">
            <button className={activeTool === 'hline' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'hline' ? 'none' : 'hline')}>
              <Minus size={16} />
            </button>
          </Tooltip>
          <Tooltip content="Rectangle Tool">
            <button className={activeTool === 'rect' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'rect' ? 'none' : 'rect')}>
              <Square size={16} />
            </button>
          </Tooltip>
          <div className={styles.toolboxDivider}></div>
          <Tooltip content="Fit Chart to Screen">
            <button onClick={() => chartApi.current?.timeScale().fitContent()}>
              <Eye size={16} />
            </button>
          </Tooltip>
        </div>
      </div>

      <div className={styles.chartCard}>
        <div className={styles.chartContainer}>
          <div className={styles.chartArea}>
            {ohlc && (
              <div className={styles.ohlcDisplay}>
                <span className={styles.pair}>{symbol}</span>
                <span className={styles.ohlcValue}>O {ohlc.o.toFixed(4)}</span>
                <span className={styles.ohlcValue}>H {ohlc.h.toFixed(4)}</span>
                <span className={styles.ohlcValue}>L {ohlc.l.toFixed(4)}</span>
                <span className={styles.ohlcValue}>C {ohlc.c.toFixed(4)}</span>
                <span className={styles.ohlcValue}>Vol {ohlc.v.toFixed(0)}</span>
              </div>
            )}
            <div ref={chartRef} className={styles.chart} />
          </div>
        </div>
      </div>

      <div className={styles.center}>
        <OptionsChain 
          provider={dataProvider} 
          spotPrice={mid}
          baseSymbol={symbol}
          onOptionSelect={(strike, isCall, price) => {
            setSelectedOption({strike, isCall, price});
            setShowTradePanel(true);
          }}
        />
        
        <AnimatePresence>
          {showTradePanel && (
            <motion.div 
              className={styles.tradePanelModal}
              initial={{ x: '100%' }}
              animate={{ x: 0 }}
              exit={{ x: '100%' }}
              transition={{ 
                type: 'spring',
                stiffness: 300,
                damping: 30,
                mass: 0.8
              }}
            >
              <OptionsTradePanel 
                baseSymbol={symbol} 
                quoteSymbol={quoteSymbol} 
                mid={mid} 
                provider={panelProvider}
                selectedStrike={selectedOption?.strike}
                selectedIsCall={selectedOption?.isCall}
                selectedPrice={selectedOption?.price}
                onClose={() => setShowTradePanel(false)}
                showBackButton={true}
              />
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <div className={styles.bottomSection}>
        <div className={styles.activityCard}>
          <div className={styles.activityTabs}>
            <button 
              className={activityTab === 'positions' ? styles.active : ''} 
              onClick={() => setActivityTab('positions')}
            >
              Positions
            </button>
            <button 
              className={activityTab === 'open-orders' ? styles.active : ''} 
              onClick={() => setActivityTab('open-orders')}
            >
              Open Orders
            </button>
            <button 
              className={activityTab === 'trade-history' ? styles.active : ''} 
              onClick={() => setActivityTab('trade-history')}
            >
              Trade History
            </button>
            <button 
              className={activityTab === 'order-history' ? styles.active : ''} 
              onClick={() => setActivityTab('order-history')}
            >
              Order History
            </button>
          </div>
          <div className={styles.activityContent}>
            {activityTab === 'positions' && (
              <table className={styles.activityTable}>
                <thead>
                  <tr>
                    <th>Option</th>
                    <th>Strike</th>
                    <th>Expiry</th>
                    <th>Size</th>
                    <th>Entry Price</th>
                    <th>Mark Price</th>
                    <th>P&L</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td><span className={styles.callBadge}>SUI Call</span></td>
                    <td>$1.65</td>
                    <td>Sep 12</td>
                    <td>+5</td>
                    <td>$0.12</td>
                    <td>$0.18</td>
                    <td className={styles.positive}>+$0.30 (+25%)</td>
                    <td><button className={styles.closeButton}>Close</button></td>
                  </tr>
                  <tr>
                    <td><span className={styles.putBadge}>SUI Put</span></td>
                    <td>$1.55</td>
                    <td>Sep 19</td>
                    <td>+2</td>
                    <td>$0.08</td>
                    <td>$0.05</td>
                    <td className={styles.negative}>-$0.06 (-37.5%)</td>
                    <td><button className={styles.closeButton}>Close</button></td>
                  </tr>
                </tbody>
              </table>
            )}
            
            {activityTab === 'open-orders' && (
              <table className={styles.activityTable}>
                <thead>
                  <tr>
                    <th>Option</th>
                    <th>Strike</th>
                    <th>Expiry</th>
                    <th>Side</th>
                    <th>Size</th>
                    <th>Price</th>
                    <th>Status</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td><span className={styles.callBadge}>SUI Call</span></td>
                    <td>$1.70</td>
                    <td>Sep 12</td>
                    <td className={styles.buyText}>Buy</td>
                    <td>3</td>
                    <td>$0.15</td>
                    <td><span className={styles.pendingBadge}>Pending</span></td>
                    <td><button className={styles.cancelButton}>Cancel</button></td>
                  </tr>
                  <tr>
                    <td><span className={styles.putBadge}>SUI Put</span></td>
                    <td>$1.50</td>
                    <td>Sep 19</td>
                    <td className={styles.sellText}>Sell</td>
                    <td>1</td>
                    <td>$0.06</td>
                    <td><span className={styles.pendingBadge}>Pending</span></td>
                    <td><button className={styles.cancelButton}>Cancel</button></td>
                  </tr>
                </tbody>
              </table>
            )}
            
            {activityTab === 'trade-history' && (
              <table className={styles.activityTable}>
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Option</th>
                    <th>Strike</th>
                    <th>Side</th>
                    <th>Size</th>
                    <th>Price</th>
                    <th>Fee</th>
                    <th>Total</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>14:32:15</td>
                    <td><span className={styles.callBadge}>SUI Call</span></td>
                    <td>$1.65</td>
                    <td className={styles.buyText}>Buy</td>
                    <td>5</td>
                    <td>$0.12</td>
                    <td>$0.003</td>
                    <td>$0.603</td>
                  </tr>
                  <tr>
                    <td>13:45:22</td>
                    <td><span className={styles.putBadge}>SUI Put</span></td>
                    <td>$1.55</td>
                    <td className={styles.buyText}>Buy</td>
                    <td>2</td>
                    <td>$0.08</td>
                    <td>$0.001</td>
                    <td>$0.161</td>
                  </tr>
                  <tr>
                    <td>12:18:45</td>
                    <td><span className={styles.callBadge}>SUI Call</span></td>
                    <td>$1.60</td>
                    <td className={styles.sellText}>Sell</td>
                    <td>3</td>
                    <td>$0.22</td>
                    <td>$0.004</td>
                    <td>$0.656</td>
                  </tr>
                </tbody>
              </table>
            )}
            
            {activityTab === 'order-history' && (
              <table className={styles.activityTable}>
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Option</th>
                    <th>Strike</th>
                    <th>Side</th>
                    <th>Size</th>
                    <th>Price</th>
                    <th>Status</th>
                    <th>Filled</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>14:32:15</td>
                    <td><span className={styles.callBadge}>SUI Call</span></td>
                    <td>$1.65</td>
                    <td className={styles.buyText}>Buy</td>
                    <td>5</td>
                    <td>$0.12</td>
                    <td><span className={styles.filledBadge}>Filled</span></td>
                    <td>5/5</td>
                  </tr>
                  <tr>
                    <td>13:45:22</td>
                    <td><span className={styles.putBadge}>SUI Put</span></td>
                    <td>$1.55</td>
                    <td className={styles.buyText}>Buy</td>
                    <td>2</td>
                    <td>$0.08</td>
                    <td><span className={styles.filledBadge}>Filled</span></td>
                    <td>2/2</td>
                  </tr>
                  <tr>
                    <td>12:18:45</td>
                    <td><span className={styles.callBadge}>SUI Call</span></td>
                    <td>$1.60</td>
                    <td className={styles.sellText}>Sell</td>
                    <td>3</td>
                    <td>$0.22</td>
                    <td><span className={styles.filledBadge}>Filled</span></td>
                    <td>3/3</td>
                  </tr>
                  <tr>
                    <td>11:55:12</td>
                    <td><span className={styles.putBadge}>SUI Put</span></td>
                    <td>$1.45</td>
                    <td className={styles.buyText}>Buy</td>
                    <td>4</td>
                    <td>$0.05</td>
                    <td><span className={styles.cancelledBadge}>Cancelled</span></td>
                    <td>0/4</td>
                  </tr>
                </tbody>
              </table>
            )}
          </div>
        </div>
        <div className={styles.pointsCard}>
          <div className={styles.pointsHeader}>Your Rank</div>
          <div className={styles.pointsStats}>
            <div className={styles.pointsStat}><span>Rank:</span><span>-</span></div>
            <div className={styles.pointsStat}><span>Points:</span><span>-</span></div>
          </div>
          <div className={styles.pointsMessage}>Trade options to earn points.</div>
        </div>
      </div>

    </div>
  );
}


