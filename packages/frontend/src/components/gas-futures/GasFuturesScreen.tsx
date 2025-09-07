import { useEffect, useMemo, useRef, useState } from 'react';
import styles from './GasFuturesScreen.module.css';
import { createChart, type IChartApi, type CandlestickData, type UTCTimestamp, CandlestickSeries, LineSeries, BarSeries } from 'lightweight-charts';
import { Orderbook } from './Orderbook';
import { Trades } from './Trades';
import { GasFuturesTradePanel } from './GasFuturesTradePanel';
import { Tooltip } from '../dex/Tooltip';
import { loadSettings } from '../../lib/settings.config';
import { useCurrentAccount } from '@mysten/dapp-kit';
import { Wifi, WifiOff, Activity, Pause, TrendingUp, Minus, BarChart3, Crosshair, Square, LineChart, CandlestickChart, Waves, Eye, Clock } from 'lucide-react';

export function GasFuturesScreen({ started, surgeReady, network }: { started?: boolean; surgeReady?: boolean; network?: string }) {
  const account = useCurrentAccount();

  const [summary, setSummary] = useState<{ 
    last?: number; 
    vol24h?: number; 
    high24h?: number; 
    low24h?: number; 
    change24h?: number;
    openInterest?: number;
    fundingRate?: number;
    nextFunding?: number;
  }>({});
  const [mid, setMid] = useState<number>(0);
  const [centerTab, setCenterTab] = useState<'orderbook' | 'trades'>('orderbook');
  const [activityTab, setActivityTab] = useState<'positions' | 'orders' | 'twap' | 'trades' | 'funding' | 'history'>('positions');
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

  // Sample data for gas futures
  const samplePositions = [
    { id: '1', side: 'Long', size: '150,000', entryPrice: '0.0234', markPrice: '0.0245', pnl: '+165.00', margin: '1,250.00', leverage: '10x' },
    { id: '2', side: 'Short', size: '75,000', entryPrice: '0.0256', markPrice: '0.0245', pnl: '+82.50', margin: '800.00', leverage: '8x' },
  ];

  const sampleOrders = [
    { id: '1', type: 'Limit', side: 'Long', size: '200,000', price: '0.0230', total: '4,600.00', leverage: '5x', status: 'Open' },
    { id: '2', type: 'Stop', side: 'Short', size: '100,000', price: '0.0250', total: '2,500.00', leverage: '10x', status: 'Pending' },
  ];

  const sampleTrades = [
    { id: '1', side: 'Long', size: '150,000', price: '0.0234', value: '3,510.00', fee: '7.02', time: '14:23:45' },
    { id: '2', side: 'Short', size: '75,000', price: '0.0256', value: '1,920.00', fee: '3.84', time: '13:45:12' },
  ];

  const sampleFundingHistory = [
    { timestamp: '2024-01-15 08:00:00', rate: '0.0125%', payment: '-1.25 USDC' },
    { timestamp: '2024-01-15 00:00:00', rate: '0.0087%', payment: '-0.87 USDC' },
    { timestamp: '2024-01-14 16:00:00', rate: '-0.0043%', payment: '+0.43 USDC' },
  ];

  const sampleTwapData = [
    { period: '1h', twap: '0.02341', volume: '125,000' },
    { period: '4h', twap: '0.02356', volume: '485,000' },
    { period: '24h', twap: '0.02389', volume: '2,150,000' },
  ];

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        // Mock data for gas futures
        if (!mounted) return;
        setSummary({ 
          last: 0.02345, 
          vol24h: 2150000, 
          high24h: 0.0256, 
          low24h: 0.0221, 
          change24h: 4.7,
          openInterest: 15750000,
          fundingRate: 0.0125,
          nextFunding: Date.now() + 3600000 // 1 hour from now
        });
      } catch {}
    };
    void load();
    const id = setInterval(load, 3000);
    return () => { mounted = false; clearInterval(id); };
  }, []);

  // Update document title
  useEffect(() => {
    const price = summary.last;
    if (price) {
      document.title = `${price.toFixed(4)} | MIST Futures | Unxversal`;
    } else {
      document.title = `MIST Futures | Unxversal`;
    }
  }, [summary.last]);

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
    
    // Volume histogram
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
        // Generate synthetic gas price data
        const now = Math.floor(Date.now()/1000);
        const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
        const points: CandlestickData<UTCTimestamp>[] = [];
        const vols: { time: UTCTimestamp; value: number }[] = [];
        let base = 0.023;
        for (let i = 300; i >= 0; i--) {
          const time = (now - i*step) as UTCTimestamp;
          const noise = (Math.sin(i/12) + Math.random()*0.3 - 0.15) * 0.002;
          const open = base;
          const close = base + noise;
          const high = Math.max(open, close) + Math.random()*0.001;
          const low = Math.min(open, close) - Math.random()*0.001;
          base = close;
          points.push({ time, open, high, low, close });
          vols.push({ time, value: Math.round(50000 + Math.random()*30000) });
        }
        const data = points;
        vol.setData(showVolume ? vols : []);
        
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
  }, [tf, chartType, showVolume, activeTool, showSMA, showEMA, showBB]);
  
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

  // Format funding countdown
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
      <div className={styles.chartCard}>
        <div className={styles.topbar}>
          <div className={styles.pairBar}>
            <div className={styles.pair}>MIST Futures</div>
            <div className={styles.metrics}>
              <span>Price: {summary.last?.toFixed(4) ?? '-'}</span>
              <span className={summary.change24h && summary.change24h >= 0 ? styles.positive : styles.negative}>
                Change: {summary.change24h?.toFixed(2) ?? '-'}%
              </span>
              <span>24h Vol: {summary.vol24h?.toLocaleString() ?? '-'}</span>
              <span>OI: {summary.openInterest?.toLocaleString() ?? '-'}</span>
              <span className={styles.fundingInfo}>
                <Clock size={12} />
                Funding: {summary.fundingRate ? (summary.fundingRate * 100).toFixed(4) + '%' : '-'} 
                {summary.nextFunding && ` | ${formatCountdown(summary.nextFunding)}`}
              </span>
            </div>
          </div>
        </div>
        <div className={styles.chartContainer}>
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
            <Tooltip content="Trend Line Tool">
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
            <Tooltip content="Rectangle Tool">
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
          
          <div className={styles.chartArea}>
            {ohlc && (
              <div className={styles.ohlcDisplay}>
                <span className={styles.pair}>MIST</span>
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
        <div className={styles.centerTabs}>
          <button className={centerTab==='orderbook'? styles.active:''} onClick={()=>setCenterTab('orderbook')}>Orderbook</button>
          <button className={centerTab==='trades'? styles.active:''} onClick={()=>setCenterTab('trades')}>Trades</button>
        </div>
        {centerTab==='orderbook' ? (
          <Orderbook />
        ) : (
          <Trades />
        )}
      </div>
      
      <div className={styles.right}>
        <GasFuturesTradePanel mid={mid} />
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
              className={activityTab === 'orders' ? styles.active : ''} 
              onClick={() => setActivityTab('orders')}
            >
              Open Orders
            </button>
            <button 
              className={activityTab === 'twap' ? styles.active : ''} 
              onClick={() => setActivityTab('twap')}
            >
              TWAP
            </button>
            <button 
              className={activityTab === 'trades' ? styles.active : ''} 
              onClick={() => setActivityTab('trades')}
            >
              Trade History
            </button>
            <button 
              className={activityTab === 'funding' ? styles.active : ''} 
              onClick={() => setActivityTab('funding')}
            >
              Funding History
            </button>
            <button 
              className={activityTab === 'history' ? styles.active : ''} 
              onClick={() => setActivityTab('history')}
            >
              Order History
            </button>
          </div>
          <div className={styles.activityContent}>
            {activityTab === 'positions' && (
              <>
                {samplePositions.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Side</th>
                        <th>Size</th>
                        <th>Entry Price</th>
                        <th>Mark Price</th>
                        <th>PnL</th>
                        <th>Margin</th>
                        <th>Leverage</th>
                      </tr>
                    </thead>
                    <tbody>
                      {samplePositions.map(position => (
                        <tr key={position.id}>
                          <td className={position.side === 'Long' ? styles.longText : styles.shortText}>
                            {position.side}
                          </td>
                          <td>{position.size}</td>
                          <td>{position.entryPrice}</td>
                          <td>{position.markPrice}</td>
                          <td className={position.pnl.startsWith('+') ? styles.positive : styles.negative}>
                            {position.pnl}
                          </td>
                          <td>{position.margin}</td>
                          <td>{position.leverage}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No open positions.</div>
                )}
              </>
            )}
            
            {activityTab === 'orders' && (
              <>
                {sampleOrders.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Type</th>
                        <th>Side</th>
                        <th>Size</th>
                        <th>Price</th>
                        <th>Total</th>
                        <th>Leverage</th>
                        <th>Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleOrders.map(order => (
                        <tr key={order.id}>
                          <td>{order.type}</td>
                          <td className={order.side === 'Long' ? styles.longText : styles.shortText}>
                            {order.side}
                          </td>
                          <td>{order.size}</td>
                          <td>{order.price}</td>
                          <td>{order.total}</td>
                          <td>{order.leverage}</td>
                          <td>{order.status}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No open orders.</div>
                )}
              </>
            )}

            {activityTab === 'twap' && (
              <>
                {sampleTwapData.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Period</th>
                        <th>TWAP</th>
                        <th>Volume</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleTwapData.map((twap, index) => (
                        <tr key={index}>
                          <td>{twap.period}</td>
                          <td>{twap.twap}</td>
                          <td>{twap.volume}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No TWAP data available.</div>
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
                        <th>Size</th>
                        <th>Price</th>
                        <th>Value</th>
                        <th>Fee</th>
                        <th>Time</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleTrades.map(trade => (
                        <tr key={trade.id}>
                          <td className={trade.side === 'Long' ? styles.longText : styles.shortText}>
                            {trade.side}
                          </td>
                          <td>{trade.size}</td>
                          <td>{trade.price}</td>
                          <td>{trade.value}</td>
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

            {activityTab === 'funding' && (
              <>
                {sampleFundingHistory.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Timestamp</th>
                        <th>Funding Rate</th>
                        <th>Payment</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleFundingHistory.map((funding, index) => (
                        <tr key={index}>
                          <td>{funding.timestamp}</td>
                          <td>{funding.rate}</td>
                          <td className={funding.payment.startsWith('+') ? styles.positive : styles.negative}>
                            {funding.payment}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No funding history.</div>
                )}
              </>
            )}

            {activityTab === 'history' && (
              <>
                {sampleOrders.length > 0 ? (
                  <table className={styles.ordersTable}>
                    <thead>
                      <tr>
                        <th>Type</th>
                        <th>Side</th>
                        <th>Size</th>
                        <th>Price</th>
                        <th>Total</th>
                        <th>Leverage</th>
                        <th>Status</th>
                        <th>Time</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleOrders.map(order => (
                        <tr key={order.id}>
                          <td>{order.type}</td>
                          <td className={order.side === 'Long' ? styles.longText : styles.shortText}>
                            {order.side}
                          </td>
                          <td>{order.size}</td>
                          <td>{order.price}</td>
                          <td>{order.total}</td>
                          <td>{order.leverage}</td>
                          <td>{order.status}</td>
                          <td>14:23:45</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className={styles.emptyState}>No order history.</div>
                )}
              </>
            )}
          </div>
        </div>

        <div className={styles.pointsCard}>
          <div className={styles.pointsHeader}>Your Rank</div>
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
