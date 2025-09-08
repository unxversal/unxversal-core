import { useEffect, useMemo, useState, useRef } from 'react';
import { Plus } from 'lucide-react';
import styles from '../OptionsScreen.module.css';
import type { OptionsChainRow, OptionsDataProvider } from '../types';

export function OptionsChain({ 
  provider, 
  spotPrice,
  onOptionSelect,
  baseSymbol = 'Token'
}: { 
  provider?: OptionsDataProvider;
  spotPrice?: number;
  onOptionSelect?: (strike: number, isCall: boolean, price: number) => void;
  baseSymbol?: string;
}) {
  const [rows, setRows] = useState<OptionsChainRow[]>([]);
  const [expiry, setExpiry] = useState<string>('next');
  const [buySell, setBuySell] = useState<'buy' | 'sell'>('buy');
  const [callPut, setCallPut] = useState<'call' | 'put' | 'both'>('call');
  const [showStickyPrice, setShowStickyPrice] = useState<boolean>(false);
  const tableContainerRef = useRef<HTMLDivElement>(null);
  const priceIndicatorRef = useRef<HTMLTableRowElement>(null);

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        if (provider?.getChain) {
          const r = await provider.getChain(expiry);
          if (!mounted) return;
          setRows(r);
        } else {
          // mock
          if (!mounted) return;
          const baseStrike = spotPrice || 1.0;
          const mock: OptionsChainRow[] = Array.from({ length: 15 }, (_, i) => {
            const k = baseStrike + (i - 7) * 0.1;
            const changeSign = Math.random() > 0.6 ? 1 : -1; // 40% chance of negative
            const changePercent = changeSign * (Math.random() * 100 + 20);
            const changeAmount = changeSign * (Math.random() * 3 + 0.5);
            return {
              strike: Number(k.toFixed(2)),
              callBid: Number((Math.max(0, 0.15 - Math.abs(k - baseStrike) * 0.3) + Math.random() * 0.02).toFixed(3)),
              callAsk: Number((Math.max(0.01, 0.17 - Math.abs(k - baseStrike) * 0.3) + Math.random() * 0.02).toFixed(3)),
              putBid: Number((Math.max(0, 0.15 - Math.abs(k - baseStrike) * 0.3) + Math.random() * 0.02).toFixed(3)),
              putAsk: Number((Math.max(0.01, 0.17 - Math.abs(k - baseStrike) * 0.3) + Math.random() * 0.02).toFixed(3)),
              callIv: Number((0.52 + Math.random() * 0.12).toFixed(3)),
              putIv: Number((0.55 + Math.random() * 0.12).toFixed(3)),
              openInterest: Math.round(80 + Math.random() * 400),
              volume: Math.round(5 + Math.random() * 120),
              changePercent,
              changeAmount,
              chanceOfProfit: Math.random() * 40 + 50,
              breakeven: k + (Math.max(0.01, 0.17 - Math.abs(k - baseStrike) * 0.3) + Math.random() * 0.02),
              priceChange24h: changeSign * (Math.random() * 0.05 + 0.01) // For badge coloring
            };
          });
          setRows(mock);
        }
      } catch {}
    };
    void load();
    const id = setInterval(load, 4000);
    return () => { mounted = false; clearInterval(id); };
  }, [provider, expiry, spotPrice]);

  // Handle scroll to show/hide sticky price indicator using intersection observer
  useEffect(() => {
    const priceRow = priceIndicatorRef.current;
    const container = tableContainerRef.current;
    
    if (!priceRow || !container || !spotPrice) return;
    
    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        // Show sticky price when the main indicator is NOT intersecting (out of view)
        setShowStickyPrice(!entry.isIntersecting);
      },
      {
        root: container,
        threshold: 0.1,
        rootMargin: '0px'
      }
    );
    
    observer.observe(priceRow);
    
    return () => {
      observer.disconnect();
    };
  }, [rows, spotPrice]);

  const filtRows = useMemo(() => {
    // Filter by call/put doesn't hide data, just determines what we show
    return rows;
  }, [rows]);

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', position: 'relative' }}>
      <div className={styles.chainToolbar}>
        <div className={styles.chainControls}>
          <div className={styles.chainControls}>
            <button className={`${styles.toggle} ${buySell==='buy'?styles.active:''}`} onClick={()=>setBuySell('buy')}>Buy</button>
            <button className={`${styles.toggle} ${buySell==='sell'?styles.active:''}`} onClick={()=>setBuySell('sell')}>Sell</button>
          </div>
          <div className={styles.chainControls}>
            <button className={`${styles.toggle} ${callPut==='call'?styles.active:''}`} onClick={()=>setCallPut('call')}>Call</button>
            <button className={`${styles.toggle} ${callPut==='put'?styles.active:''}`} onClick={()=>setCallPut('put')}>Put</button>
          </div>
          <select className={styles.select} value={expiry} onChange={(e)=>setExpiry(e.target.value)}>
            <option value="next">Expiring September 12 (5d)</option>
            <option value="2w">2 Weeks</option>
            <option value="1m">1 Month</option>
          </select>
        </div>
      </div>

      <div style={{ flex: 1, overflow: 'auto', position: 'relative' }} ref={tableContainerRef}>
        <table className={styles.ordersTable} style={{ width: '100%' }}>
          <thead className={styles.stickyHeader}>
            <tr>
              <th style={{textAlign:'left'}}>Strike price</th>
              <th style={{textAlign:'left'}}>Breakeven</th>
              <th style={{textAlign:'left'}}>Chance of profit</th>
              <th style={{textAlign:'left'}}>% Change</th>
              <th style={{textAlign:'left'}}>Change</th>
              <th style={{textAlign:'right'}}>Bid Price</th>
              <th style={{textAlign:'center'}}></th>
            </tr>
          </thead>
          <tbody>
            {filtRows.map((r, i) => {
              const changeColor = (r.changePercent || 0) >= 0 ? '#10b981' : '#ef4444';
              const changePrefix = (r.changePercent || 0) >= 0 ? '+' : '';
              
              // Find the closest strike to spot price for price indicator placement
              let showPriceIndicator = false;
              if (spotPrice && i < filtRows.length - 1) {
                const currentDiff = Math.abs(r.strike - spotPrice);
                const nextDiff = Math.abs(filtRows[i + 1].strike - spotPrice);
                // Show indicator between current and next row if spot price is between them
                showPriceIndicator = (r.strike <= spotPrice && filtRows[i + 1].strike >= spotPrice) ||
                                   (r.strike >= spotPrice && filtRows[i + 1].strike <= spotPrice);
              }
              
              return (
                <>
                  <tr key={i} className={styles.optionRow}>
                    <td style={{textAlign:'left'}}>${r.strike.toFixed(0)}</td>
                    <td style={{textAlign:'left'}}>${(r.breakeven || r.strike + r.callAsk).toFixed(2)}</td>
                    <td style={{textAlign:'left'}}>{(r.chanceOfProfit || Math.random() * 40 + 50).toFixed(2)}%</td>
                    <td style={{textAlign:'left', color: changeColor}}>{changePrefix}{(r.changePercent || 0).toFixed(2)}%</td>
                    <td style={{textAlign:'left', color: changeColor}}>{changePrefix}${Math.abs(r.changeAmount || 0).toFixed(2)}</td>
                    <td style={{textAlign:'right'}}>
                      <div 
                        className={styles.pricePlusBadge}
                        style={{
                          backgroundColor: (r.priceChange24h || 0) >= 0 ? '#10b981' : '#ef4444'
                        }}
                        onClick={() => onOptionSelect?.(r.strike, callPut !== 'put', callPut === 'put' ? r.putAsk : r.callAsk)}
                      >
                        <span className={styles.priceText}>
                          ${(callPut === 'put' ? r.putAsk : r.callAsk).toFixed(2)}
                        </span>
                        <div className={styles.plusDivider}></div>
                        <Plus size={14} className={styles.plusIcon} />
                      </div>
                    </td>
                    <td></td>
                  </tr>
                  {showPriceIndicator && spotPrice && (
                    <tr className={styles.priceIndicatorRow} ref={priceIndicatorRef}>
                      <td colSpan={7} style={{ padding: '8px 0', position: 'relative' }}>
                        <div className={styles.priceIndicator}>
                          <div className={styles.priceIndicatorLine}></div>
                          <div className={styles.priceIndicatorLabel}>
                            {baseSymbol} price: ${spotPrice.toFixed(2)}
                          </div>
                          <div className={styles.priceIndicatorLine}></div>
                        </div>
                      </td>
                    </tr>
                  )}
                </>
              );
            })}
          </tbody>
        </table>
      </div>
      
      {/* Sticky price indicator when scrolled out of view - positioned relative to the main container */}
      {showStickyPrice && spotPrice && (
        <div className={styles.stickyPriceIndicator}>
          <div className={styles.priceIndicatorLabel}>
            {baseSymbol} price: ${spotPrice.toFixed(2)}
          </div>
        </div>
      )}
    </div>
  );
}


