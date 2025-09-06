import { useEffect, useRef } from 'react';
import { 
  createChart, 
  ColorType, 
  CandlestickSeries, 
  HistogramSeries,
  type IChartApi,
  type ISeriesApi,
  type Time
} from 'lightweight-charts';

interface TradingChartProps {
  data?: Array<{
    time: number;
    open: number;
    high: number;
    low: number;
    close: number;
    volume?: number;
  }>;
}

export function TradingChart({ data = [] }: TradingChartProps) {
  const chartContainerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const candlestickSeriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null);
  const volumeSeriesRef = useRef<ISeriesApi<'Histogram'> | null>(null);

  useEffect(() => {
    if (!chartContainerRef.current) return;

    const chart = createChart(chartContainerRef.current, {
      layout: {
        background: { type: ColorType.Solid, color: '#0f1014' },
        textColor: '#888',
      },
      grid: {
        vertLines: { color: '#1a1a1a' },
        horzLines: { color: '#1a1a1a' },
      },
      crosshair: {
        mode: 1,
      },
      rightPriceScale: {
        borderColor: '#1a1a1a',
      },
      timeScale: {
        borderColor: '#1a1a1a',
        timeVisible: true,
        secondsVisible: false,
      },
      handleScroll: {
        mouseWheel: true,
        pressedMouseMove: true,
      },
      handleScale: {
        axisPressedMouseMove: true,
        mouseWheel: true,
        pinch: true,
      },
    });

    const candlestickSeries = chart.addSeries(CandlestickSeries, {
      upColor: '#00d4aa',
      downColor: '#ff6b6b',
      borderDownColor: '#ff6b6b',
      borderUpColor: '#00d4aa',
      wickDownColor: '#ff6b6b',
      wickUpColor: '#00d4aa',
    });

    const volumeSeries = chart.addSeries(HistogramSeries, {
      color: '#26a69a',
      priceFormat: {
        type: 'volume',
      },
      priceScaleId: 'volume',
    });

    // Position volume series at the bottom
    volumeSeries.priceScale().applyOptions({
      scaleMargins: {
        top: 0.8,
        bottom: 0,
      },
    });

    chartRef.current = chart;
    candlestickSeriesRef.current = candlestickSeries;
    volumeSeriesRef.current = volumeSeries;

    // Generate sample data if none provided
    const sampleData = data.length > 0 ? data : generateSampleData();
    
    candlestickSeries.setData(sampleData.map(d => ({
      time: d.time as Time,
      open: d.open,
      high: d.high,
      low: d.low,
      close: d.close,
    })));

    if (sampleData.some(d => d.volume)) {
      volumeSeries.setData(sampleData.map(d => ({
        time: d.time as Time,
        value: d.volume || 0,
        color: d.close >= d.open ? '#00d4aa' : '#ff6b6b',
      })));
    }

    const handleResize = () => {
      if (chartContainerRef.current) {
        chart.applyOptions({
          width: chartContainerRef.current.clientWidth,
          height: chartContainerRef.current.clientHeight,
        });
      }
    };

    window.addEventListener('resize', handleResize);

    return () => {
      window.removeEventListener('resize', handleResize);
      chart.remove();
    };
  }, []);

  useEffect(() => {
    if (candlestickSeriesRef.current && data.length > 0) {
      candlestickSeriesRef.current.setData(data.map(d => ({
        time: d.time as Time,
        open: d.open,
        high: d.high,
        low: d.low,
        close: d.close,
      })));

      if (volumeSeriesRef.current && data.some(d => d.volume)) {
        volumeSeriesRef.current.setData(data.map(d => ({
          time: d.time as Time,
          value: d.volume || 0,
          color: d.close >= d.open ? '#00d4aa' : '#ff6b6b',
        })));
      }
    }
  }, [data]);

  return <div ref={chartContainerRef} style={{ width: '100%', height: '100%' }} />;
}

function generateSampleData() {
  const data = [];
  let basePrice = 110000;
  const now = Math.floor(Date.now() / 1000);
  
  for (let i = 100; i >= 0; i--) {
    const time = now - i * 300; // 5-minute intervals
    const volatility = 0.02;
    const change = (Math.random() - 0.5) * volatility * basePrice;
    
    const open = basePrice;
    const close = basePrice + change;
    const high = Math.max(open, close) + Math.random() * 0.01 * basePrice;
    const low = Math.min(open, close) - Math.random() * 0.01 * basePrice;
    const volume = Math.random() * 1000000 + 100000;
    
    data.push({
      time,
      open,
      high,
      low,
      close,
      volume,
    });
    
    basePrice = close;
  }
  
  return data;
}