import { useEffect, useRef, useState, useMemo } from 'react';
import styles from './DerivativesScreen.module.css';
import { createChart, type IChartApi, type CandlestickData, type UTCTimestamp, CandlestickSeries, LineSeries, BarSeries } from 'lightweight-charts';
import { Orderbook } from './Orderbook';
import { Trades } from './Trades';
import { Tooltip } from '../dex/Tooltip';
import { BarChart3, Crosshair, Square, LineChart, CandlestickChart, Waves, Eye, Clock, TrendingUp, Minus } from 'lucide-react';
import type { DerivativesScreenProps } from './types';

export function DerivativesScreen({ 
  network, 
  marketLabel, 
  symbol, 
  quoteSymbol = 'USDC', 
  dataProvider, 
  panelProvider, 
  TradePanelComponent, 
  availableExpiries, 
  onExpiryChange, 
  protocolStatus,
  allSymbols,
  selectedSymbol,
  onSelectSymbol,
  symbolIconMap,
}: DerivativesScreenProps) {

  const [summary, setSummary] = useState<{ 
    last?: number; 
    vol24h?: number; 
    high24h?: number; 
    low24h?: number; 
    change24h?: number;
    openInterest?: number;
    fundingRate?: number;
    nextFunding?: number;
    expiryDate?: number;
    timeToExpiry?: number;
  }>({});
  const [mid, setMid] = useState<number>(0);
  const [centerTab, setCenterTab] = useState<'orderbook' | 'trades'>('orderbook');
  // Determine if this is a perpetual market (has funding) vs futures (has expiry)
  const isPerp = summary.fundingRate !== undefined;
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
  const [showSymbolDropdown, setShowSymbolDropdown] = useState(false);

  // Activity sample state when provider is not present
  const [samplePositions, setSamplePositions] = useState<any[]>([]);
  const [sampleOrders, setSampleOrders] = useState<any[]>([]);
  const [sampleTrades, setSampleTrades] = useState<any[]>([]);
  const [sampleFundingHistory, setSampleFundingHistory] = useState<any[]>([]);
  const [sampleTwapData, setSampleTwapData] = useState<any[]>([]);

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        let currentSummaryData;
        if (dataProvider?.getSummary) {
          const s = await dataProvider.getSummary();
          if (!mounted) return;
          setSummary(s);
          currentSummaryData = s;
        } else {
          // Mock
          if (!mounted) return;
          const mockSummary = { 
            last: 0.0234, 
            vol24h: 2150000, 
            high24h: 0.0256, 
            low24h: 0.0221, 
            change24h: 4.70,
            openInterest: 15750000,
            fundingRate: 0.012500,
            nextFunding: Date.now() + 3599000
          };
          setSummary(mockSummary);
          currentSummaryData = mockSummary;
        }

        if (dataProvider?.getPositions) setSamplePositions(await dataProvider.getPositions());
        else setSamplePositions([
          { id: '1', side: 'Long', size: '150,000', entryPrice: '0.0234', markPrice: '0.0245', pnl: '+165.00', margin: '1,250.00', leverage: '10x' },
          { id: '2', side: 'Short', size: '75,000', entryPrice: '0.0256', markPrice: '0.0245', pnl: '+82.50', margin: '800.00', leverage: '8x' },
        ]);

        if (dataProvider?.getOpenOrders) setSampleOrders(await dataProvider.getOpenOrders());
        else setSampleOrders([
          { id: '1', type: 'Limit', side: 'Long', size: '200,000', price: '0.0230', total: '4,600.00', leverage: '5x', status: 'Open' },
          { id: '2', type: 'Stop', side: 'Short', size: '100,000', price: '0.0250', total: '2,500.00', leverage: '10x', status: 'Pending' },
        ]);

        if (dataProvider?.getRecentTrades) setSampleTrades(await dataProvider.getRecentTrades());
        else setSampleTrades([
          { id: '1', side: 'Long', size: '150,000', price: '0.0234', value: '3,510.00', fee: '7.02', time: '14:23:45' },
          { id: '2', side: 'Short', size: '75,000', price: '0.0256', value: '1,920.00', fee: '3.84', time: '13:45:12' },
        ] as any);

        if (dataProvider?.getFundingHistory) setSampleFundingHistory(await dataProvider.getFundingHistory());
        else if (currentSummaryData?.fundingRate !== undefined) {
          // Only load mock funding history for perps
          setSampleFundingHistory([
            { timestamp: '2024-01-15 08:00:00', rate: '0.0125%', payment: '-1.25 USDC' },
            { timestamp: '2024-01-15 00:00:00', rate: '0.0087%', payment: '-0.87 USDC' },
            { timestamp: '2024-01-14 16:00:00', rate: '-0.0043%', payment: '+0.43 USDC' },
          ]);
        } else {
          setSampleFundingHistory([]);
        }

        if (dataProvider?.getTwap) setSampleTwapData(await dataProvider.getTwap());
        else setSampleTwapData([
          { period: '1h', twap: '0.02341', volume: '125,000' },
          { period: '4h', twap: '0.02356', volume: '485,000' },
          { period: '24h', twap: '0.02389', volume: '2,150,000' },
        ]);
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
    
    chart.subscribeClick((param) => {
      if (!param || !param.time || activeTool === 'none') return;
      const seriesData = param.seriesData.get(priceSeries);
      const price = (seriesData as any)?.close || (seriesData as any)?.value;
      if (activeTool === 'hline' && price !== undefined) {
        const line = priceSeries.createPriceLine({ price: price, color: '#3b82f6', lineWidth: 1, lineStyle: 0 });
        drawingsRef.current.push(line);
        setActiveTool('none');
      }
    });
    
    return () => { 
      if (!disposed) { chart.remove(); indicatorsRef.current = {}; } 
      disposed = true; 
      window.removeEventListener('resize', resize); 
    };
  }, [tf, chartType, showVolume, activeTool, showSMA, showEMA, showBB, dataProvider]);
  
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

  // Format expiry countdown for futures
  const formatExpiryCountdown = (timeToExpiry: number) => {
    if (timeToExpiry <= 0) return 'EXPIRED';
    const days = Math.floor(timeToExpiry / (24 * 60 * 60 * 1000));
    const hours = Math.floor((timeToExpiry % (24 * 60 * 60 * 1000)) / (60 * 60 * 1000));
    const minutes = Math.floor((timeToExpiry % (60 * 60 * 1000)) / (60 * 1000));
    
    if (days > 0) {
      return `${days}d ${hours}h ${minutes}m`;
    } else if (hours > 0) {
      return `${hours}h ${minutes}m`;
    } else {
      return `${minutes}m`;
    }
  };

  // Format expiry date
  const formatExpiryDate = (timestamp: number) => {
    return new Date(timestamp).toLocaleDateString('en-US', { 
      month: 'short', 
      day: 'numeric', 
      year: 'numeric' 
    });
  };

  const uniqueSymbols = useMemo(() => allSymbols ? Array.from(new Set(allSymbols)) : [], [allSymbols]);

  return (
    <div className={styles.root} onClick={(e) => {
      // Close symbol dropdown when clicking outside
      if (showSymbolDropdown && !(e.target as Element).closest(`.${styles.pair}`)) {
        setShowSymbolDropdown(false);
      }
    }}>
      <div className={styles.priceCard}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>
            {selectedSymbol && allSymbols && allSymbols.length > 0 ? (
              <>
                {symbolIconMap?.[selectedSymbol] && (
                  <img className={styles.pairIcon} src={symbolIconMap[selectedSymbol]} alt={selectedSymbol} />
                )}
                <span 
                  style={{ color: '#e5e7eb', fontWeight: 600, fontSize: '18px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: '4px' }}
                  onClick={() => setShowSymbolDropdown(v => !v)}
                >
                  {selectedSymbol}
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" style={{ color: '#9ca3af' }}>
                    <path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </span>
                {showSymbolDropdown && (
                  <div className={styles.symbolDropdown}>
                    {uniqueSymbols.map(sym => (
                      <div 
                        key={sym} 
                        className={styles.symbolOption}
                        onClick={() => { 
                          onSelectSymbol?.(sym); 
                          setShowSymbolDropdown(false); 
                        }}
                      >
                        {symbolIconMap?.[sym] && (
                          <img className={styles.symbolOptionIcon} src={symbolIconMap[sym]} alt={sym} />
                        )}
                        <span>{sym}</span>
                      </div>
                    ))}
                  </div>
                )}
              </>
            ) : (
              marketLabel
            )}
            {availableExpiries && availableExpiries.length > 0 && (
              <select 
                className={styles.expirySelector}
                value={availableExpiries.find(e => e.isActive)?.id || availableExpiries[0]?.id || ''}
                onChange={(e) => onExpiryChange?.(e.target.value)}
              >
                {availableExpiries.map(expiry => (
                  <option key={expiry.id} value={expiry.id}>
                    {expiry.label}
                  </option>
                ))}
              </select>
            )}
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
            {isPerp && summary.fundingRate !== undefined && (
              <>
                <div className={styles.metricItem}>
                  <div className={styles.metricValue}>
                    {(summary.fundingRate * 100).toFixed(4)}%
                  </div>
                  <div className={styles.metricLabel}>Funding</div>
                </div>
                <div className={`${styles.metricItem} ${styles.fundingItem}`}>
                  <div className={styles.metricValue}>
                    <Clock size={10} />
                    {summary.nextFunding ? formatCountdown(summary.nextFunding) : '--:--:--'}
                  </div>
                  <div className={styles.metricLabel}>Next Funding</div>
                </div>
              </>
            )}
            {summary.expiryDate !== undefined && (
              <>
                <div className={styles.metricItem}>
                  <div className={styles.metricValue}>
                    {formatExpiryDate(summary.expiryDate)}
                  </div>
                  <div className={styles.metricLabel}>Expiry</div>
                </div>
                <div className={`${styles.metricItem} ${styles.fundingItem}`}>
                  <div className={styles.metricValue}>
                    <Clock size={10} />
                    {summary.timeToExpiry ? formatExpiryCountdown(summary.timeToExpiry) : 'EXPIRED'}
                  </div>
                  <div className={styles.metricLabel}>Time to Expiry</div>
                </div>
              </>
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
        <div className={styles.centerTabs}>
          <button className={centerTab==='orderbook'? styles.active:''} onClick={()=>setCenterTab('orderbook')}>Orderbook</button>
          <button className={centerTab==='trades'? styles.active:''} onClick={()=>setCenterTab('trades')}>Trades</button>
        </div>
        {centerTab==='orderbook' ? (
          <Orderbook provider={dataProvider} />
        ) : (
          <Trades provider={dataProvider} />
        )}
      </div>
      
      <div className={styles.right}>
        {TradePanelComponent ? (
          <TradePanelComponent baseSymbol={symbol} quoteSymbol={quoteSymbol} mid={mid} provider={panelProvider} />
        ) : null}
      </div>
      
      <div className={styles.bottomSection}>
        <div className={styles.activityCard}>
          <div className={styles.activityTabs}>
            <button className={activityTab === 'positions' ? styles.active : ''} onClick={() => setActivityTab('positions')}>Positions</button>
            <button className={activityTab === 'orders' ? styles.active : ''} onClick={() => setActivityTab('orders')}>Open Orders</button>
            <button className={activityTab === 'twap' ? styles.active : ''} onClick={() => setActivityTab('twap')}>TWAP</button>
            <button className={activityTab === 'trades' ? styles.active : ''} onClick={() => setActivityTab('trades')}>Trade History</button>
            {isPerp && (
              <button className={activityTab === 'funding' ? styles.active : ''} onClick={() => setActivityTab('funding')}>Funding History</button>
            )}
            <button className={activityTab === 'history' ? styles.active : ''} onClick={() => setActivityTab('history')}>Order History</button>
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
                      {samplePositions.map((position: any, idx: number) => (
                        <tr key={position.id || idx}>
                          <td className={position.side === 'Long' ? styles.longText : styles.shortText}>{position.side}</td>
                          <td>{position.size}</td>
                          <td>{position.entryPrice}</td>
                          <td>{position.markPrice}</td>
                          <td className={(typeof position.pnl === 'string' ? position.pnl.startsWith('+') : Number(position.pnl) >= 0) ? styles.positive : styles.negative}>{position.pnl}</td>
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
                      {sampleOrders.map((order: any, idx: number) => (
                        <tr key={order.id || idx}>
                          <td>{order.type}</td>
                          <td className={order.side === 'Long' ? styles.longText : styles.shortText}>{order.side}</td>
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
                      {sampleTwapData.map((twap: any, index: number) => (
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
                      {(sampleTrades as any[]).map((trade: any, idx: number) => (
                        <tr key={trade.id || idx}>
                          <td className={trade.side === 'Long' ? styles.longText : styles.shortText}>{trade.side}</td>
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
            {activityTab === 'funding' && isPerp && (
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
                      {sampleFundingHistory.map((funding: any, index: number) => (
                        <tr key={index}>
                          <td>{funding.timestamp}</td>
                          <td>{funding.rate}</td>
                          <td className={typeof funding.payment === 'string' && funding.payment.startsWith('+') ? styles.positive : styles.negative}>{funding.payment}</td>
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
                      {sampleOrders.map((order: any, idx: number) => (
                        <tr key={order.id || idx}>
                          <td>{order.type}</td>
                          <td className={order.side === 'Long' ? styles.longText : styles.shortText}>{order.side}</td>
                          <td>{order.size}</td>
                          <td>{order.price}</td>
                          <td>{order.total}</td>
                          <td>{order.leverage}</td>
                          <td>{order.status}</td>
                          <td>--:--:--</td>
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
            <div className={styles.pointsStat}><span>Rank:</span><span>-</span></div>
            <div className={styles.pointsStat}><span>Points:</span><span>-</span></div>
          </div>
          <div className={styles.pointsMessage}>Connect your wallet to see your position</div>
        </div>
      </div>

      <footer className={styles.footer}>
        <div className={styles.statusBadges}>
          <div className={`${styles.badge} ${protocolStatus?.options ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.options ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Options</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.futures ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.futures ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Futures</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.perps ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.perps ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Perps</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.lending ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.lending ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Lending</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.staking ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.staking ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Staking</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.dex ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.dex ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>DEX</span>
          </div>
        </div>
        <div className={styles.networkBadge}><span>{(network || 'testnet').toUpperCase()}</span></div>
      </footer>
    </div>
  );
}



