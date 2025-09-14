import React, { useEffect, useMemo, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import styles from './OptionsComponent.module.css';
import chainStyles from '../../components/options/OptionsScreen.module.css';
import tradePanelStyles from '../../components/options/components/OptionsTradePanel.module.css';
import optionsStyles from '../../components/options/OptionsScreen.module.css';
import type { OptionsComponentProps, UTCTimestamp } from './types';
import { createChart, type IChartApi, CandlestickSeries, LineSeries, BarSeries, type CandlestickData } from 'lightweight-charts';
import { BarChart3, CandlestickChart, Clock, Eye, LineChart, Minus, Square, TrendingUp, Waves, Crosshair, X, ChevronLeft } from 'lucide-react';

export function OptionsComponent(props: OptionsComponentProps) {
  const {
    selectedSymbol,
    allSymbols,
    onSelectSymbol,
    symbolIconMap,
    selectedExpiryMs,
    availableExpiriesMs,
    onSelectExpiry,

    summary,
    oiByExpiry,

    chainRows,
    underlyingPrice,

    orderBook,
    recentTrades,

    positions,
    openOrders,
    tradeHistory,
    orderHistory,
    portfolioSummary,
    leaderboardRank,
    leaderboardPoints,

    onPlaceBuyOrder,
    onPlaceSellOrder,
    onCancelOrder,
    onExercise,
    onSettleAfterExpiry,
  } = props;

  const [tf, setTf] = useState<'1m' | '5m' | '15m' | '1h' | '1d' | '7d'>('1m');
  const [chartType, setChartType] = useState<'candles' | 'bars' | 'line'>('candles');
  const [showVolume, setShowVolume] = useState<boolean>(false);
  const [activeTool, setActiveTool] = useState<'none' | 'crosshair' | 'trend' | 'hline' | 'rect'>('none');
  const [showSMA, setShowSMA] = useState<boolean>(false);
  const [showEMA, setShowEMA] = useState<boolean>(false);
  const [showBB, setShowBB] = useState<boolean>(false);

  const chartRef = useRef<HTMLDivElement | null>(null);
  const chartApi = useRef<IChartApi | null>(null);
  const [ohlc, setOhlc] = useState<{o: number, h: number, l: number, c: number, v: number} | null>(null);

  // De-duplicate symbols to avoid duplicate keys in dropdown
  const uniqueSymbols = useMemo(() => Array.from(new Set(allSymbols)), [allSymbols]);

  // Chain UI states
  const [buySell, setBuySell] = useState<'buy' | 'sell'>('buy');
  const [callPut, setCallPut] = useState<'call' | 'put'>('call');
  const tableContainerRef = useRef<HTMLDivElement>(null);
  const priceIndicatorRef = useRef<HTMLTableRowElement>(null);
  const [showStickyPrice, setShowStickyPrice] = useState<boolean>(false);

  // Trade popup state
  const [tradeOpen, setTradeOpen] = useState(false);
  const [tradeStrike, setTradeStrike] = useState<number | null>(null);
  const [tradeIsCall, setTradeIsCall] = useState<boolean>(true);
  const [tradePrice, setTradePrice] = useState<number | null>(null);
  const [tradeQty, setTradeQty] = useState<number>(1);
  const [tradeAction, setTradeAction] = useState<'buy' | 'sell'>('buy');
  const [tradeExpiry, setTradeExpiry] = useState<string>('next');
  const [feeType, setFeeType] = useState<'input' | 'unxv'>('input');

  // Activity tabs
  const [activityTab, setActivityTab] = useState<'positions' | 'open-orders' | 'trade-history' | 'order-history'>('positions');

  // Symbol dropdown state
  const [showSymbolDropdown, setShowSymbolDropdown] = useState(false);

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
    if (chartType === 'candles') {
      priceSeries = chart.addSeries(CandlestickSeries, {
        upColor: '#10b981', downColor: '#ef4444', borderVisible: false, wickUpColor: '#10b981', wickDownColor: '#ef4444',
      });
    } else if (chartType === 'bars') {
      priceSeries = chart.addSeries(BarSeries, { upColor: '#10b981', downColor: '#ef4444', thinBars: true });
    } else {
      priceSeries = chart.addSeries(LineSeries, { color: '#10b981', lineWidth: 2 });
    }

    // Only show chart data if we have actual price data (summary.last exists)
    if (summary.last) {
      const now = Math.floor(Date.now() / 1000);
      const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
      const targetPrice = summary.last;

      // Build synthetic candles only when we have real price data
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

      if (chartType === 'line') {
        priceSeries.setData(candles.map(d => ({ time: d.time as UTCTimestamp, value: d.close })) as { time: UTCTimestamp; value: number }[]);
      } else {
        priceSeries.setData(candles);
      }

      if (candles.length > 0) {
        const latest = candles[candles.length - 1];
        const vol24h = candles.slice(-24).reduce((sum, d) => sum + ((d as any).volume || 0), 0);
        setOhlc({ o: latest.open, h: latest.high, l: latest.low, c: latest.close, v: vol24h });
      }
    } else {
      // No price data - show empty chart
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
  }, [tf, chartType, showVolume, summary.last]);

  const handleClickPrice = (strike: number, isCall: boolean, price: number | null) => {
    if (price === null) return;
    setTradeStrike(strike);
    setTradeIsCall(isCall);
    setTradePrice(price);
    setTradeQty(1);
    setTradeAction('buy');
    // Set expiry to the currently selected expiry or first available
    if (availableExpiriesMs.length > 0) {
      const targetExpiry = selectedExpiryMs || availableExpiriesMs[0];
      setTradeExpiry(String(targetExpiry));
    }
    setTradeOpen(true);
  };

  const submitTrade = () => {
    if (tradeStrike === null || tradePrice === null) { setTradeOpen(false); return; }
    
    // Use the selected expiry from the trade popup, or fall back to main selection
    const expiryMs = tradeExpiry !== 'next' ? Number(tradeExpiry) : (selectedExpiryMs || availableExpiriesMs[0] || 0);
    
    const args = {
      side: tradeAction,
      isCall: tradeIsCall,
      expiryMs,
      strike_1e6: Math.round(tradeStrike * 1e6),
      quantity: tradeQty,
      limitPremiumQuote_1e6: Math.round(tradePrice * 1e6),
    } as const;
    
    console.log('Submitting trade with args:', args);
    if (tradeAction === 'buy') onPlaceBuyOrder?.(args as any); else onPlaceSellOrder?.(args as any);
    setTradeOpen(false);
  };

  // Fee calculations for trade panel
  const notionalValue = tradeQty * (tradePrice || 0);
  const tradingFee = notionalValue * 0.001; // 0.1% fee
  const feeUnxvDisc = tradingFee * 0.7; // 30% discount with UNXV
  const baseSymbol = selectedSymbol.split('/')[0] || 'SUI';
  const quoteSymbol = selectedSymbol.split('/')[1] || 'USDC';
  const mid = underlyingPrice || summary.last || 1.0;

  const priceBadgeRowIndex = useMemo(() => {
    if (!underlyingPrice || chainRows.length === 0) return null;
    let idx = 0;
    for (let i = 0; i < chainRows.length; i++) {
      if (chainRows[i].strike >= underlyingPrice) { idx = i; break; }
      idx = i;
    }
    return idx;
  }, [underlyingPrice, chainRows]);

  const formatMs = (ms?: number | null) => {
    if (!ms) return '-';
    const d = new Date(ms);
    return d.toLocaleString();
  };

  // Sticky price visibility observer
  useEffect(() => {
    const priceRow = priceIndicatorRef.current;
    const container = tableContainerRef.current;
    if (!priceRow || !container || !underlyingPrice) return;
    const observer = new IntersectionObserver((entries) => {
      const entry = entries[0];
      setShowStickyPrice(!entry.isIntersecting);
    }, { root: container, threshold: 0.1, rootMargin: '0px' });
    observer.observe(priceRow);
    return () => { observer.disconnect(); };
  }, [chainRows, underlyingPrice]);

  const scrollToPrice = () => {
    const priceRow = priceIndicatorRef.current;
    const container = tableContainerRef.current;
    if (priceRow && container) {
      priceRow.scrollIntoView({ behavior: 'smooth', block: 'center' });
      setTimeout(() => {
        const containerRect = container.getBoundingClientRect();
        const priceRowRect = priceRow.getBoundingClientRect();
        const scrollTop = container.scrollTop;
        const targetScroll = scrollTop + (priceRowRect.top - containerRect.top) - (containerRect.height / 2) + (priceRowRect.height / 2);
        container.scrollTo({ top: targetScroll, behavior: 'smooth' });
      }, 100);
    }
  };

  return (
    <div className={styles.root} onClick={(e) => {
      // Close symbol dropdown when clicking outside
      if (showSymbolDropdown && !(e.target as Element).closest(`.${styles.pair}`)) {
        setShowSymbolDropdown(false);
      }
    }}>
      <div className={styles.priceCard}>
        <div className={styles.pairBar}>
          <div className={styles.pair} style={{ position: 'relative' }}>
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
                      onSelectSymbol(sym); 
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
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{summary.last?.toFixed(4) ?? '-'}</div>
              <div className={styles.metricLabel}>Price</div>
            </div>
            <div className={styles.metricItem}>
              <div className={`${styles.metricValue} ${summary.change24h && summary.change24h >= 0 ? styles.positive : styles.negative}`}>
                {summary.change24h !== undefined ? `${summary.change24h.toFixed(2)}%` : '-'}
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
          </div>
        </div>
      </div>

      <div className={styles.toolboxCard}>
        <div className={styles.toolbox}>
          {(['1m','5m','15m','1h','1d','7d'] as const).map(t => (
            <button key={t} className={tf === t ? styles.active : ''} onClick={() => setTf(t)}>{t}</button>
          ))}
          <div className={styles.toolboxDivider}></div>
          <button className={chartType === 'candles' ? styles.active : ''} onClick={() => setChartType('candles')}>
            <CandlestickChart size={16} />
          </button>
          <button className={chartType === 'bars' ? styles.active : ''} onClick={() => setChartType('bars')}>
            <BarChart3 size={16} />
          </button>
          <button className={chartType === 'line' ? styles.active : ''} onClick={() => setChartType('line')}>
            <LineChart size={16} />
          </button>
          <div className={styles.toolboxDivider}></div>
          <button className={showVolume ? styles.active : ''} onClick={() => setShowVolume(v => !v)}>
            <Waves size={16} />
          </button>
          <button className={showSMA ? styles.active : ''} onClick={() => setShowSMA(v => !v)}>SMA</button>
          <button className={showEMA ? styles.active : ''} onClick={() => setShowEMA(v => !v)}>EMA</button>
          <button className={showBB ? styles.active : ''} onClick={() => setShowBB(v => !v)}>BB</button>
          <div className={styles.toolboxDivider}></div>
          <button className={activeTool === 'crosshair' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'crosshair' ? 'none' : 'crosshair')}>
            <Crosshair size={16} />
          </button>
          <button className={activeTool === 'trend' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'trend' ? 'none' : 'trend')}>
            <TrendingUp size={16} />
          </button>
          <button className={activeTool === 'hline' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'hline' ? 'none' : 'hline')}>
            <Minus size={16} />
          </button>
          <button className={activeTool === 'rect' ? styles.active : ''} onClick={() => setActiveTool(activeTool === 'rect' ? 'none' : 'rect')}>
            <Square size={16} />
          </button>
          <div className={styles.toolboxDivider}></div>
          <button onClick={() => chartApi.current?.timeScale().fitContent()}>
            <Eye size={16} />
          </button>
        </div>
      </div>

      <div className={styles.chartCard}>
        <div className={styles.chartContainer}>
          <div className={styles.chartArea}>
            {ohlc && (
              <div className={styles.ohlcDisplay}>
                <span className={styles.pair}>{selectedSymbol}</span>
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
        <div className={chainStyles.chainToolbar}>
          <div className={chainStyles.chainControls}>
            <div className={chainStyles.chainControls}>
              <button className={`${chainStyles.toggle} ${buySell==='buy'?chainStyles.active:''}`} onClick={()=>setBuySell('buy')}>Buy</button>
              <button className={`${chainStyles.toggle} ${buySell==='sell'?chainStyles.active:''}`} onClick={()=>setBuySell('sell')}>Sell</button>
            </div>
            <div className={chainStyles.chainControls}>
              <button className={`${chainStyles.toggle} ${callPut==='call'?chainStyles.active:''}`} onClick={()=>setCallPut('call')}>Call</button>
              <button className={`${chainStyles.toggle} ${callPut==='put'?chainStyles.active:''}`} onClick={()=>setCallPut('put')}>Put</button>
            </div>
          </div>
          <select className={chainStyles.select} value={selectedExpiryMs ?? ''} onChange={(e)=>onSelectExpiry(Number(e.target.value))}>
            <option value="" disabled>Select expiry</option>
            {availableExpiriesMs.map(ms => (
              <option key={ms} value={ms}>{formatMs(ms)}</option>
            ))}
          </select>
        </div>

        <div style={{ flex: 1, overflow: 'auto', position: 'relative' }} ref={tableContainerRef}>
          <table className={chainStyles.ordersTable} style={{ width: '100%' }}>
            <thead className={chainStyles.stickyHeader}>
              <tr>
                <th style={{textAlign:'left'}}>Strike price</th>
                <th style={{textAlign:'left'}}>Breakeven</th>
                <th style={{textAlign:'left'}}>% Change</th>
                <th style={{textAlign:'left'}}>Change</th>
                <th style={{textAlign:'right'}}>Bid Price</th>
                <th style={{textAlign:'center'}}></th>
              </tr>
            </thead>
            <tbody>
              {chainRows.map((r, i) => {
                const changeColor = (r.changePercent || 0) >= 0 ? '#10b981' : '#ef4444';
                const changePrefix = (r.changePercent || 0) >= 0 ? '+' : '';
                let showPriceIndicator = false;
                if (underlyingPrice && i < chainRows.length - 1) {
                  const a = chainRows[i].strike;
                  const b = chainRows[i + 1].strike;
                  showPriceIndicator = (a <= underlyingPrice && b >= underlyingPrice) || (a >= underlyingPrice && b <= underlyingPrice);
                }
                const ask = callPut === 'put' ? (r.putAsk ?? null) : (r.callAsk ?? null);
                const breakeven = r.breakeven ?? (callPut === 'put' ? (r.strike - (r.putBid ?? r.putAsk ?? 0)) : (r.strike + (r.callAsk ?? r.callBid ?? 0)));
                return (
                  <React.Fragment key={`row-${i}`}>
                    <tr className={chainStyles.optionRow}>
                      <td style={{textAlign:'left'}}>${r.strike.toFixed(2)}</td>
                      <td style={{textAlign:'left'}}>${(breakeven || r.strike).toFixed(2)}</td>
                      <td style={{textAlign:'left', color: changeColor}}>{changePrefix}{(r.changePercent || 0).toFixed(2)}%</td>
                      <td style={{textAlign:'left', color: changeColor}}>{changePrefix}${Math.abs(r.changeAmount || 0).toFixed(2)}</td>
                      <td style={{textAlign:'right'}}>
                        {ask !== null ? (
                          <div 
                            className={chainStyles.pricePlusBadge}
                            style={{ backgroundColor: (r.priceChange24h || 0) >= 0 ? 'rgba(16, 185, 129, 0.2)' : 'rgba(239, 68, 68, 0.2)' }}
                            onClick={() => handleClickPrice(r.strike, callPut==='call', ask)}
                          >
                            <span 
                              className={chainStyles.priceText}
                              style={{ color: (r.priceChange24h || 0) >= 0 ? '#10b981' : '#ef4444' }}
                            >
                              ${ask.toFixed(2)}
                            </span>
                            <div className={chainStyles.plusDivider} style={{ background: (r.priceChange24h || 0) >= 0 ? 'rgba(16, 185, 129, 0.3)' : 'rgba(239, 68, 68, 0.3)' }}></div>
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" className={chainStyles.plusIcon} style={{ color: (r.priceChange24h || 0) >= 0 ? '#10b981' : '#ef4444' }}>
                              <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
                            </svg>
                          </div>
                        ) : '-'}
                      </td>
                      <td></td>
                    </tr>
                    {showPriceIndicator && underlyingPrice && (
                      <tr className={chainStyles.priceIndicatorRow} ref={priceIndicatorRef}>
                        <td colSpan={7} style={{ padding: '8px 0', position: 'relative' }}>
                          <div className={chainStyles.priceIndicator}>
                            <div className={chainStyles.priceIndicatorLine}></div>
                            <div className={chainStyles.priceIndicatorLabel} onClick={(e) => { e.preventDefault(); e.stopPropagation(); scrollToPrice(); }}>
                              {selectedSymbol.split('/')[0]} price: ${underlyingPrice.toFixed(2)}
                            </div>
                            <div className={chainStyles.priceIndicatorLine}></div>
                          </div>
                        </td>
                      </tr>
                    )}
                  </React.Fragment>
                );
              })}
            </tbody>
          </table>
        </div>

        {showStickyPrice && underlyingPrice && (
          <div className={chainStyles.stickyPriceIndicator}>
            <div className={chainStyles.priceIndicatorLabel} onClick={(e) => { e.preventDefault(); e.stopPropagation(); scrollToPrice(); }} style={{ cursor: 'pointer' }}>
              {selectedSymbol.split('/')[0]} price: ${underlyingPrice.toFixed(2)}
            </div>
          </div>
        )}
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
              <table className={styles.ordersTable}>
                <thead>
                  <tr>
                    <th>Option</th>
                    <th>Strike</th>
                    <th>Expiry</th>
                    <th>Size</th>
                    <th>Entry Price</th>
                    <th>Mark Price</th>
                    <th>P&L</th>
                  </tr>
                </thead>
                <tbody>
                  {positions.map((p) => (
                    <tr key={p.positionId}>
                      <td><span className={p.isCall ? styles.positive : styles.negative}>{selectedSymbol.split('/')[0]} {p.isCall ? 'Call' : 'Put'}</span></td>
                      <td>${(p.strike1e6/1e6).toFixed(2)}</td>
                      <td>{formatMs(p.expiryMs)}</td>
                      <td>{p.amountUnits > 0 ? '+' : ''}{p.amountUnits}</td>
                      <td>{p.entryPriceQuote !== undefined ? `$${p.entryPriceQuote.toFixed(2)}` : '-'}</td>
                      <td>{p.markPriceQuote !== undefined ? `$${p.markPriceQuote.toFixed(2)}` : '-'}</td>
                      <td className={(p.pnlQuote ?? 0) >= 0 ? styles.positive : styles.negative}>{p.pnlQuote !== undefined ? `${(p.pnlQuote >= 0 ? '+' : '-')}$${Math.abs(p.pnlQuote).toFixed(2)}` : '-'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            {activityTab === 'open-orders' && (
              <table className={styles.ordersTable}>
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
                  {openOrders.map((o) => (
                    <tr key={o.orderId}>
                      <td>{selectedSymbol.split('/')[0]} {o.isBid ? 'Call' : 'Put'}</td>
                      <td>-</td>
                      <td>{formatMs(o.expiryMs)}</td>
                      <td className={o.isBid ? styles.positive : styles.negative}>{o.isBid ? 'Buy' : 'Sell'}</td>
                      <td>{o.qtyRemaining}</td>
                      <td>${o.priceQuote.toFixed(2)}</td>
                      <td><span className={styles.pendingBadge}>{o.status ?? 'Open'}</span></td>
                      <td><button className={styles.cancelButton} onClick={() => onCancelOrder?.(o.orderId)}>Cancel</button></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            {activityTab === 'trade-history' && (
              <table className={styles.ordersTable}>
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Maker</th>
                    <th>Taker</th>
                    <th>Price</th>
                    <th>Qty</th>
                  </tr>
                </thead>
                <tbody>
                  {tradeHistory.map((t, idx) => (
                    <tr key={`${t.tsMs}-${idx}`}>
                      <td>{new Date(t.tsMs).toLocaleTimeString()}</td>
                      <td>{t.maker.slice(0,6)}…</td>
                      <td>{t.taker.slice(0,6)}…</td>
                      <td>${t.priceQuote.toFixed(2)}</td>
                      <td>{t.baseQty}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            {activityTab === 'order-history' && (
              <table className={styles.ordersTable}>
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Action</th>
                    <th>Order</th>
                  </tr>
                </thead>
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
            )}
          </div>
        </div>
        <div className={styles.pointsCard}>
          <div className={styles.pointsHeader}>Your Rank</div>
          <div className={styles.pointsStats}>
            <div className={styles.pointsStat}><span>Rank:</span><span>{leaderboardRank ?? '-'}</span></div>
            <div className={styles.pointsStat}><span>Points:</span><span>{leaderboardPoints ?? '-'}</span></div>
          </div>
          <div className={styles.pointsMessage}>Trade options to earn points.</div>
        </div>
      </div>

      <AnimatePresence>
        {tradeOpen && (
          <motion.div 
            className={optionsStyles.tradePanelModal}
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
            <div className={tradePanelStyles.root}>
              <div className={tradePanelStyles.header}>
                <div className={tradePanelStyles.title}>Trade Options</div>
                <button className={tradePanelStyles.closeButton} onClick={() => setTradeOpen(false)}>
                  <X size={16} />
                </button>
              </div>

              <div className={tradePanelStyles.orderCard}>
                <div className={tradePanelStyles.orderHeader}>
                  <div className={tradePanelStyles.tabs}>
                    <button className={tradeAction==='buy'?tradePanelStyles.active:''} onClick={()=>setTradeAction('buy')}>Buy</button>
                    <button className={tradeAction==='sell'?tradePanelStyles.active:''} onClick={()=>setTradeAction('sell')}>Sell</button>
                  </div>
                </div>

                <div className={tradePanelStyles.contentArea}>
                  <div className={tradePanelStyles.optionTypeSegmented}>
                    <button className={tradeIsCall?tradePanelStyles.active:''} onClick={()=>setTradeIsCall(true)}>Call</button>
                    <button className={!tradeIsCall?tradePanelStyles.active:''} onClick={()=>setTradeIsCall(false)}>Put</button>
                  </div>

                  <div className={tradePanelStyles.field}>
                    <label className={tradePanelStyles.fieldLabel}>Strike Price ({quoteSymbol})</label>
                    <input 
                      className={tradePanelStyles.input}
                      type="number" 
                      value={tradeStrike || ''} 
                      onChange={(e)=>setTradeStrike(Number(e.target.value) || null)} 
                      placeholder="0.00"
                    />
                  </div>

                  <div className={tradePanelStyles.field}>
                    <label className={tradePanelStyles.fieldLabel}>Expiry</label>
                    <select className={tradePanelStyles.select} value={tradeExpiry} onChange={(e)=>setTradeExpiry(e.target.value)}>
                      {availableExpiriesMs.length > 0 ? (
                        availableExpiriesMs.map(ms => (
                          <option key={ms} value={ms}>{formatMs(ms)}</option>
                        ))
                      ) : (
                        <option value="next">Next Expiry</option>
                      )}
                    </select>
                  </div>

                  <div className={tradePanelStyles.field}>
                    <label className={tradePanelStyles.fieldLabel}>Size (Contracts)</label>
                    <input 
                      className={tradePanelStyles.input}
                      type="number" 
                      value={tradeQty} 
                      onChange={(e)=>setTradeQty(Math.max(1, Number(e.target.value) || 1))} 
                      placeholder="1"
                    />
                  </div>

                  <div className={tradePanelStyles.field}>
                    <label className={tradePanelStyles.fieldLabel}>Limit Price ({quoteSymbol})</label>
                    <input 
                      className={tradePanelStyles.input}
                      type="number" 
                      value={tradePrice || ''} 
                      onChange={(e)=>setTradePrice(Number(e.target.value) || null)} 
                      placeholder="0.00"
                    />
                  </div>

                  <div className={tradePanelStyles.orderSummary}>
                    <div className={tradePanelStyles.summaryRow}>
                      <span>Premium</span>
                      <span>${(tradeQty * (tradePrice || 0)).toFixed(2)}</span>
                    </div>
                    <div className={tradePanelStyles.summaryRow}>
                      <span>Max Profit</span>
                      <span>{tradeIsCall ? 'Unlimited' : `$${((tradeStrike || 0) * tradeQty - tradeQty * (tradePrice || 0)).toFixed(2)}`}</span>
                    </div>
                    <div className={tradePanelStyles.summaryRow}>
                      <span>Max Loss</span>
                      <span>${(tradeQty * (tradePrice || 0)).toFixed(2)}</span>
                    </div>
                  </div>

                  <div className={tradePanelStyles.marketInfo}>
                    <div className={tradePanelStyles.infoRow}>
                      <span>Base</span>
                      <span>{baseSymbol}</span>
                    </div>
                    <div className={tradePanelStyles.infoRow}>
                      <span>Quote</span>
                      <span>{quoteSymbol}</span>
                    </div>
                    <div className={tradePanelStyles.infoRow}>
                      <span>Mid</span>
                      <span>{mid.toFixed(4)}</span>
                    </div>
                  </div>

                  <div className={tradePanelStyles.feeSection}>
                    <div className={tradePanelStyles.feeSelector}>
                      <span className={tradePanelStyles.feeLabel}>Fee Payment</span>
                      <button 
                        className={`${tradePanelStyles.feeToggle} ${feeType === 'unxv' ? tradePanelStyles.active : ''}`}
                        onClick={() => setFeeType(feeType === 'unxv' ? 'input' : 'unxv')}
                      >
                        {feeType === 'unxv' ? 'UNXV' : quoteSymbol}
                      </button>
                    </div>
                    
                    <div className={tradePanelStyles.feeRow}>
                      <span>Trading Fee</span>
                      <span>
                        {feeType === 'unxv' 
                          ? `${feeUnxvDisc.toFixed(6)} UNXV` 
                          : `${tradingFee.toFixed(6)} ${quoteSymbol}`
                        }
                      </span>
                    </div>
                  </div>
                </div>

                <div className={tradePanelStyles.orderFooter}>
                  <div className={tradePanelStyles.buttonContainer}>
                    <button 
                      className={`${tradePanelStyles.submitButton} ${tradeAction === 'sell' ? tradePanelStyles.sell : ''}`}
                      onClick={submitTrade}
                    >
                      {tradeAction === 'buy' ? 'Buy' : 'Sell'} {tradeIsCall ? 'Call' : 'Put'}
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
