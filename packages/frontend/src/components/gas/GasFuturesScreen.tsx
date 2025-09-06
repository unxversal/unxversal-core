import styles from './GasFuturesScreen.module.css';
import { useMemo, useRef, useEffect } from 'react';
import { createChart, LineSeries, type UTCTimestamp } from 'lightweight-charts';
import { GasFuturesClient } from '../../protocols/gas-futures/client';
import { loadSettings } from '../../lib/settings.config';

export function GasFuturesScreen() {
  const { contracts } = loadSettings();
  const client = useMemo(() => new GasFuturesClient(contracts.pkgUnxversal), [contracts.pkgUnxversal]);
  const chartRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!chartRef.current) return;
    const chart = createChart(chartRef.current, { layout: { background: { color: '#0a0c12' }, textColor: '#e5e7eb' }, grid: { horzLines: { color: '#12141a' }, vertLines: { color: '#12141a' } }, rightPriceScale: { borderColor: '#1b1e27' }, timeScale: { borderColor: '#1b1e27' } });
    const s = chart.addSeries(LineSeries, { color: '#60a5fa' });
    const now = Math.floor(Date.now()/1000) as UTCTimestamp;
    const data = new Array(120).fill(0).map((_,i)=>({ time: (now - (120-i)*15) as UTCTimestamp, value: 10 + Math.sin(i/8)*0.2 }));
    s.setData(data);
    chart.timeScale().fitContent();
    const resize = () => { const r = chartRef.current!.getBoundingClientRect(); chart.applyOptions({ width: r.width, height: r.height }); };
    resize(); window.addEventListener('resize', resize);
    return () => { window.removeEventListener('resize', resize); chart.remove(); };
  }, []);

  return (
    <div className={styles.root}>
      <div className={styles.header}>Gas Futures</div>
      <div className={styles.body}>
        <div className={styles.chart} ref={chartRef} />
        <div className={styles.panel}>
          <div className={styles.row}><span>Funding Rate</span><b>~0.00%</b></div>
          <div className={styles.row}><span>Next Funding</span><b>~1h</b></div>
          <button className={styles.btn} disabled>Open Long</button>
          <button className={styles.btn} disabled>Open Short</button>
        </div>
      </div>
    </div>
  );
}
