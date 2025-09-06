

DOCS:

<!-- markdownlint-disable no-inline-html first-line-h1 -->

<div align="center">
  <a href="https://www.tradingview.com/lightweight-charts/" target="_blank">
    <img width="200" src="https://github.com/tradingview/lightweight-charts/raw/master/.github/logo.svg?sanitize=true" alt="Lightweight Charts logo">
  </a>

  <h1>Lightweight Charts™</h1>

  [![CircleCI][ci-img]][ci-link]
  [![npm version][npm-version-img]][npm-link]
  [![npm bundle size][bundle-size-img]][bundle-size-link]
  [![Dependencies count][deps-count-img]][bundle-size-link]
  [![Downloads][npm-downloads-img]][npm-link]
</div>

<!-- markdownlint-enable no-inline-html -->

[Demos][demo-url] | [Documentation](https://tradingview.github.io/lightweight-charts/) | [Reddit](https://www.reddit.com/r/TradingView/)

TradingView Lightweight Charts™ are one of the smallest and fastest financial HTML5 charts.

The Lightweight Charts™ library is the best choice for you if you want to display financial data as an interactive chart on your web page without affecting your web page loading speed and performance.

It is the best choice for you if you want to replace static image charts with interactive ones.
The size of the library is close to static images but if you have dozens of image charts on a web page then using this library can make the size of your web page smaller.

Take a look at [awesome-tradingview](https://github.com/tradingview/awesome-tradingview?tab=readme-ov-file#lightweight-charts) for related projects created by our community members.

The library provides a rich set of charting capabilities out of the box, but developers can also extend its functionality by building custom plugins. See the [interactive plugin examples here](https://tradingview.github.io/lightweight-charts/plugin-examples/), or check out [plugin-examples/README.md](https://github.com/tradingview/lightweight-charts/tree/master/plugin-examples) for more details.

## Installing

### es6 via npm

```bash
npm install lightweight-charts
```

```js
import { createChart, LineSeries } from 'lightweight-charts';

const chart = createChart(document.body, { width: 400, height: 300 });
const lineSeries = chart.addSeries(LineSeries);
lineSeries.setData([
    { time: '2019-04-11', value: 80.01 },
    { time: '2019-04-12', value: 96.63 },
    { time: '2019-04-13', value: 76.64 },
    { time: '2019-04-14', value: 81.89 },
    { time: '2019-04-15', value: 74.43 },
    { time: '2019-04-16', value: 80.01 },
    { time: '2019-04-17', value: 96.63 },
    { time: '2019-04-18', value: 76.64 },
    { time: '2019-04-19', value: 81.89 },
    { time: '2019-04-20', value: 74.43 },
]);
```

### CDN

You can use [unpkg](https://unpkg.com/):

<https://unpkg.com/lightweight-charts/dist/lightweight-charts.standalone.production.js>

The standalone version creates `window.LightweightCharts` object with all exports from `esm` version:

```js
const chart = LightweightCharts.createChart(document.body, { width: 400, height: 300 });
const lineSeries = chart.addSeries(LightweightCharts.LineSeries);
lineSeries.setData([
    { time: '2019-04-11', value: 80.01 },
    { time: '2019-04-12', value: 96.63 },
    { time: '2019-04-13', value: 76.64 },
    { time: '2019-04-14', value: 81.89 },
    { time: '2019-04-15', value: 74.43 },
    { time: '2019-04-16', value: 80.01 },
    { time: '2019-04-17', value: 96.63 },
    { time: '2019-04-18', value: 76.64 },
    { time: '2019-04-19', value: 81.89 },
    { time: '2019-04-20', value: 74.43 },
]);
```

### Build Variants

|Dependencies included|Mode|ES module|IIFE (`window.LightweightCharts`)|
|-|-|-|-|
|No|PROD|`lightweight-charts.production.mjs`|N/A|
|No|DEV|`lightweight-charts.development.mjs`|N/A|
|Yes (standalone)|PROD|`lightweight-charts.standalone.production.mjs`|`lightweight-charts.standalone.production.js`|
|Yes (standalone)|DEV|`lightweight-charts.standalone.development.mjs`|`lightweight-charts.standalone.development.js`|

## Development

See [BUILDING.md](./BUILDING.md) for instructions on how to build `lightweight-charts` from source.

## License

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this software except in compliance with the License.
You may obtain a copy of the License at LICENSE file.
Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

This software incorporates several parts of tslib (<https://github.com/Microsoft/tslib>, (c) Microsoft Corporation) that are covered by BSD Zero Clause License.

This license requires specifying TradingView as the product creator.
You shall add the "attribution notice" from the NOTICE file and a link to <https://www.tradingview.com/> to the page of your website or mobile application that is available to your users.
As thanks for creating this product, we'd be grateful if you add it in a prominent place.
You can use the [`attributionLogo`](https://tradingview.github.io/lightweight-charts/docs/api/interfaces/LayoutOptions#attributionLogo) chart option for displaying an appropriate link to <https://www.tradingview.com/> on the chart itself, which will satisfy the link requirement.

[demo-url]: https://www.tradingview.com/lightweight-charts/

[ci-img]: https://img.shields.io/circleci/build/github/tradingview/lightweight-charts.svg
[ci-link]: https://circleci.com/gh/tradingview/lightweight-charts

[npm-version-img]: https://badge.fury.io/js/lightweight-charts.svg
[npm-downloads-img]: https://img.shields.io/npm/dm/lightweight-charts.svg
[npm-link]: https://www.npmjs.com/package/lightweight-charts

[bundle-size-img]: https://badgen.net/bundlephobia/minzip/lightweight-charts
[deps-count-img]: https://img.shields.io/badge/dynamic/json.svg?label=dependecies&color=brightgreen&query=$.dependencyCount&uri=https%3A%2F%2Fbundlephobia.com%2Fapi%2Fsize%3Fpackage%3Dlightweight-charts
[bundle-size-link]: https://bundlephobia.com/result?p=lightweight-charts

Version: 5.0
Getting started
Requirements
Lightweight Charts™ is a client-side library that is not designed to work on the server side, for example, with Node.js.

The library code targets the ES2020 language specification. Therefore, the browsers you work with should support this language revision. Consider the following table to ensure the browser compatibility.

To support previous revisions, you can set up a transpilation process for the lightweight-charts package in your build system using tools such as Babel. If you encounter any issues, open a GitHub issue with detailed information, and we will investigate potential solutions.

Installation
To set up the library, install the lightweight-charts npm package:

npm install --save lightweight-charts

The package includes TypeScript declarations, enabling seamless integration within TypeScript projects.

Build variants
The library ships with the following build variants:

Dependencies included	Mode	ES module	IIFE (window.LightweightCharts)
No	PROD	lightweight-charts.production.mjs	N/A
No	DEV	lightweight-charts.development.mjs	N/A
Yes (standalone)	PROD	lightweight-charts.standalone.production.mjs	lightweight-charts.standalone.production.js
Yes (standalone)	DEV	lightweight-charts.standalone.development.mjs	lightweight-charts.standalone.development.js
License and attribution
The Lightweight Charts™ license requires specifying TradingView as the product creator. You should add the following attributes to a public page of your website or mobile application:

Attribution notice from the NOTICE file
The https://www.tradingview.com link
Creating a chart
As a first step, import the library to your file:

import { createChart } from 'lightweight-charts';

To create a chart, use the createChart function. You can call the function multiple times to create as many charts as needed:

import { createChart } from 'lightweight-charts';

// ...
const firstChart = createChart(document.getElementById('firstContainer'));
const secondChart = createChart(document.getElementById('secondContainer'));

As a result, createChart returns an IChartApi object that allows you to interact with the created chart.

Creating a series
When the chart is created, you can display data on it.

The basic primitive to display data is a series. The library supports the following series types:

Area
Bar
Baseline
Candlestick
Histogram
Line
To create a series, use the addSeries method from IChartApi. As a parameter, specify a series type you would like to create:

import { AreaSeries, BarSeries, BaselineSeries, createChart } from 'lightweight-charts';

const chart = createChart(container);

const areaSeries = chart.addSeries(AreaSeries);
const barSeries = chart.addSeries(BarSeries);
const baselineSeries = chart.addSeries(BaselineSeries);
// ...

Note that a series cannot be transferred from one type to another one, since different series types require different data and options types.

Setting and updating a data
When the series is created, you can populate it with data. Note that the API calls remain the same regardless of the series type, although the data format may vary.

Setting the data to a series
To set the data to a series, you should call the ISeriesApi.setData method:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const areaSeries = chart.addSeries(AreaSeries, {
    lineColor: '#2962FF', topColor: '#2962FF',
    bottomColor: 'rgba(41, 98, 255, 0.28)',
});
areaSeries.setData([
    { time: '2018-12-22', value: 32.51 },
    { time: '2018-12-23', value: 31.11 },
    { time: '2018-12-24', value: 27.02 },
    { time: '2018-12-25', value: 27.32 },
    { time: '2018-12-26', value: 25.17 },
    { time: '2018-12-27', value: 28.89 },
    { time: '2018-12-28', value: 25.46 },
    { time: '2018-12-29', value: 23.92 },
    { time: '2018-12-30', value: 22.68 },
    { time: '2018-12-31', value: 22.67 },
]);

const candlestickSeries = chart.addSeries(CandlestickSeries, {
    upColor: '#26a69a', downColor: '#ef5350', borderVisible: false,
    wickUpColor: '#26a69a', wickDownColor: '#ef5350',
});
candlestickSeries.setData([
    { time: '2018-12-22', open: 75.16, high: 82.84, low: 36.16, close: 45.72 },
    { time: '2018-12-23', open: 45.12, high: 53.90, low: 45.12, close: 48.09 },
    { time: '2018-12-24', open: 60.71, high: 60.71, low: 53.39, close: 59.29 },
    { time: '2018-12-25', open: 68.26, high: 68.26, low: 59.04, close: 60.50 },
    { time: '2018-12-26', open: 67.71, high: 105.85, low: 66.67, close: 91.04 },
    { time: '2018-12-27', open: 91.04, high: 121.40, low: 82.70, close: 111.40 },
    { time: '2018-12-28', open: 111.51, high: 142.83, low: 103.34, close: 131.25 },
    { time: '2018-12-29', open: 131.33, high: 151.17, low: 77.68, close: 96.43 },
    { time: '2018-12-30', open: 106.33, high: 110.20, low: 90.39, close: 98.10 },
    { time: '2018-12-31', open: 109.87, high: 114.69, low: 85.66, close: 111.26 },
]);

chart.timeScale().fitContent();


You can also use setData to replace all data items.

Updating the data in a series
If your data is updated, for example in real-time, you may also need to refresh the chart accordingly. To do this, call the ISeriesApi.update method that allows you to update the last data item or add a new one.

import { AreaSeries, CandlestickSeries, createChart } from 'lightweight-charts';

const chart = createChart(container);

const areaSeries = chart.addSeries(AreaSeries);
areaSeries.setData([
    // Other data items
    { time: '2018-12-31', value: 22.67 },
]);

const candlestickSeries = chart.addSeries(CandlestickSeries);
candlestickSeries.setData([
    // Other data items
    { time: '2018-12-31', open: 109.87, high: 114.69, low: 85.66, close: 111.26 },
]);

// ...

// Update the most recent bar
areaSeries.update({ time: '2018-12-31', value: 25 });
candlestickSeries.update({ time: '2018-12-31', open: 109.87, high: 114.69, low: 85.66, close: 112 });

// Creating the new bar
areaSeries.update({ time: '2019-01-01', value: 20 });
candlestickSeries.update({ time: '2019-01-01', open: 112, high: 112, low: 100, close: 101 });

We do not recommend calling ISeriesApi.setData to update the chart, as this method replaces all series data and can significantly affect the performance.

Version: 5.0
Series
This article describes supported series types and ways to customize them.

Supported types
Area
Series Definition: AreaSeries
Data format: SingleValueData or WhitespaceData
Style options: a mix of SeriesOptionsCommon and AreaStyleOptions
This series is represented with a colored area between the time scale and line connecting all data points:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const areaSeries = chart.addSeries(AreaSeries, { lineColor: '#2962FF', topColor: '#2962FF', bottomColor: 'rgba(41, 98, 255, 0.28)' });

const data = [{ value: 0, time: 1642425322 }, { value: 8, time: 1642511722 }, { value: 10, time: 1642598122 }, { value: 20, time: 1642684522 }, { value: 3, time: 1642770922 }, { value: 43, time: 1642857322 }, { value: 41, time: 1642943722 }, { value: 43, time: 1643030122 }, { value: 56, time: 1643116522 }, { value: 46, time: 1643202922 }];

areaSeries.setData(data);

chart.timeScale().fitContent();



Bar
Series Definition: BarSeries
Data format: BarData or WhitespaceData
Style options: a mix of SeriesOptionsCommon and BarStyleOptions
This series illustrates price movements with vertical bars. The length of each bar corresponds to the range between the highest and lowest price values. Open and close values are represented with the tick marks on the left and right side of the bar, respectively:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const barSeries = chart.addSeries(BarSeries, { upColor: '#26a69a', downColor: '#ef5350' });

const data = [
  { open: 10, high: 10.63, low: 9.49, close: 9.55, time: 1642427876 },
  { open: 9.55, high: 10.30, low: 9.42, close: 9.94, time: 1642514276 },
  { open: 9.94, high: 10.17, low: 9.92, close: 9.78, time: 1642600676 },
  { open: 9.78, high: 10.59, low: 9.18, close: 9.51, time: 1642687076 },
  { open: 9.51, high: 10.46, low: 9.10, close: 10.17, time: 1642773476 },
  { open: 10.17, high: 10.96, low: 10.16, close: 10.47, time: 1642859876 },
  { open: 10.47, high: 11.39, low: 10.40, close: 10.81, time: 1642946276 },
  { open: 10.81, high: 11.60, low: 10.30, close: 10.75, time: 1643032676 },
  { open: 10.75, high: 11.60, low: 10.49, close: 10.93, time: 1643119076 },
  { open: 10.93, high: 11.53, low: 10.76, close: 10.96, time: 1643205476 },
  { open: 10.96, high: 11.90, low: 10.80, close: 11.50, time: 1643291876 },
  { open: 11.50, high: 12.00, low: 11.30, close: 11.80, time: 1643378276 },
  { open: 11.80, high: 12.20, low: 11.70, close: 12.00, time: 1643464676 },
  { open: 12.00, high: 12.50, low: 11.90, close: 12.30, time: 1643551076 },
  { open: 12.30, high: 12.80, low: 12.10, close: 12.60, time: 1643637476 },
  { open: 12.60, high: 13.00, low: 12.50, close: 12.90, time: 1643723876 },
  { open: 12.90, high: 13.50, low: 12.70, close: 13.20, time: 1643810276 },
  { open: 13.20, high: 13.70, low: 13.00, close: 13.50, time: 1643896676 },
  { open: 13.50, high: 14.00, low: 13.30, close: 13.80, time: 1643983076 },
  { open: 13.80, high: 14.20, low: 13.60, close: 14.00, time: 1644069476 },
];

barSeries.setData(data);

chart.timeScale().fitContent();


Baseline
Series Definition: BaselineSeries
Data format: SingleValueData or WhitespaceData
Style options: a mix of SeriesOptionsCommon and BaselineStyleOptions
This series is represented with two colored areas between the the base value line and line connecting all data points:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const baselineSeries = chart.addSeries(BaselineSeries, { baseValue: { type: 'price', price: 25 }, topLineColor: 'rgba( 38, 166, 154, 1)', topFillColor1: 'rgba( 38, 166, 154, 0.28)', topFillColor2: 'rgba( 38, 166, 154, 0.05)', bottomLineColor: 'rgba( 239, 83, 80, 1)', bottomFillColor1: 'rgba( 239, 83, 80, 0.05)', bottomFillColor2: 'rgba( 239, 83, 80, 0.28)' });

const data = [{ value: 1, time: 1642425322 }, { value: 8, time: 1642511722 }, { value: 10, time: 1642598122 }, { value: 20, time: 1642684522 }, { value: 3, time: 1642770922 }, { value: 43, time: 1642857322 }, { value: 41, time: 1642943722 }, { value: 43, time: 1643030122 }, { value: 56, time: 1643116522 }, { value: 46, time: 1643202922 }];

baselineSeries.setData(data);

chart.timeScale().fitContent();



Candlestick
Series Definition: CandlestickSeries
Data format: CandlestickData or WhitespaceData
Style options: a mix of SeriesOptionsCommon and CandlestickStyleOptions
This series illustrates price movements with candlesticks. The solid body of each candlestick represents the open and close values for the time period. Vertical lines, known as wicks, above and below the candle body represent the high and low values, respectively:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const candlestickSeries = chart.addSeries(CandlestickSeries, { upColor: '#26a69a', downColor: '#ef5350', borderVisible: false, wickUpColor: '#26a69a', wickDownColor: '#ef5350' });

const data = [{ open: 10, high: 10.63, low: 9.49, close: 9.55, time: 1642427876 }, { open: 9.55, high: 10.30, low: 9.42, close: 9.94, time: 1642514276 }, { open: 9.94, high: 10.17, low: 9.92, close: 9.78, time: 1642600676 }, { open: 9.78, high: 10.59, low: 9.18, close: 9.51, time: 1642687076 }, { open: 9.51, high: 10.46, low: 9.10, close: 10.17, time: 1642773476 }, { open: 10.17, high: 10.96, low: 10.16, close: 10.47, time: 1642859876 }, { open: 10.47, high: 11.39, low: 10.40, close: 10.81, time: 1642946276 }, { open: 10.81, high: 11.60, low: 10.30, close: 10.75, time: 1643032676 }, { open: 10.75, high: 11.60, low: 10.49, close: 10.93, time: 1643119076 }, { open: 10.93, high: 11.53, low: 10.76, close: 10.96, time: 1643205476 }];

candlestickSeries.setData(data);

chart.timeScale().fitContent();



Histogram
Series Definition: HistogramSeries
Data format: HistogramData or WhitespaceData
Style options: a mix of SeriesOptionsCommon and HistogramStyleOptions
This series illustrates the distribution of values with columns:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const histogramSeries = chart.addSeries(HistogramSeries, { color: '#26a69a' });

const data = [{ value: 1, time: 1642425322 }, { value: 8, time: 1642511722 }, { value: 10, time: 1642598122 }, { value: 20, time: 1642684522 }, { value: 3, time: 1642770922, color: 'red' }, { value: 43, time: 1642857322 }, { value: 41, time: 1642943722, color: 'red' }, { value: 43, time: 1643030122 }, { value: 56, time: 1643116522 }, { value: 46, time: 1643202922, color: 'red' }];

histogramSeries.setData(data);

chart.timeScale().fitContent();



Line
Series Definition: LineSeries
Data format: LineData or WhitespaceData
Style options: a mix of SeriesOptionsCommon and LineStyleOptions
This series is represented with a set of data points connected by straight line segments:

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const lineSeries = chart.addSeries(LineSeries, { color: '#2962FF' });

const data = [{ value: 0, time: 1642425322 }, { value: 8, time: 1642511722 }, { value: 10, time: 1642598122 }, { value: 20, time: 1642684522 }, { value: 3, time: 1642770922 }, { value: 43, time: 1642857322 }, { value: 41, time: 1642943722 }, { value: 43, time: 1643030122 }, { value: 56, time: 1643116522 }, { value: 46, time: 1643202922 }];

lineSeries.setData(data);

chart.timeScale().fitContent();



Custom series (plugins)
The library enables you to create custom series types, also known as series plugins, to expand its functionality. With this feature, you can add new series types, indicators, and other visualizations.

To define a custom series type, create a class that implements the ICustomSeriesPaneView interface. This class defines the rendering code that Lightweight Charts™ uses to draw the series on the chart. Once your custom series type is defined, it can be added to any chart instance using the addCustomSeries() method. Custom series types function like any other series.

For more information, refer to the Plugins article.

Customization
Each series type offers a unique set of customization options listed on the SeriesStyleOptionsMap page.

You can adjust series options in two ways:

Specify the default options using the corresponding parameter while creating a series:

// Change default top & bottom colors of an area series in creating time
const series = chart.addSeries(AreaSeries, {
    topColor: 'red',
    bottomColor: 'green',
});

Use the ISeriesApi.applyOptions method to apply other options on the fly:

// Updating candlestick series options on the fly
candlestickSeries.applyOptions({
    upColor: 'red',
    downColor: 'blue',
});

Version: 5.0
Chart types
Lightweight Charts offers different types of charts to suit various data visualization needs. This article provides an overview of the available chart types and how to create them.

Standard Time-based Chart
The standard time-based chart is the most common type, suitable for displaying time series data.

Creation method: createChart
Horizontal scale: Time-based
Use case: General-purpose charting for financial and time series data
import { createChart } from 'lightweight-charts';

const chart = createChart(document.getElementById('container'), options);

This chart type uses time values for the horizontal scale and is ideal for most financial and time series data visualizations.

const chartOptions = { layout: { textColor: 'black', background: { type: 'solid', color: 'white' } } };
const chart = createChart(document.getElementById('container'), chartOptions);
const areaSeries = chart.addSeries(AreaSeries, { lineColor: '#2962FF', topColor: '#2962FF', bottomColor: 'rgba(41, 98, 255, 0.28)' });

const data = [{ value: 0, time: 1642425322 }, { value: 8, time: 1642511722 }, { value: 10, time: 1642598122 }, { value: 20, time: 1642684522 }, { value: 3, time: 1642770922 }, { value: 43, time: 1642857322 }, { value: 41, time: 1642943722 }, { value: 43, time: 1643030122 }, { value: 56, time: 1643116522 }, { value: 46, time: 1643202922 }];

areaSeries.setData(data);

chart.timeScale().fitContent();



Yield Curve Chart
The yield curve chart is specifically designed for displaying yield curves, common in financial analysis.

Creation method: createYieldCurveChart
Horizontal scale: Linearly spaced, defined in monthly time duration units
Key differences:
Whitespace is ignored for crosshair and grid lines
Specialized for yield curve representation
import { createYieldCurveChart } from 'lightweight-charts';

const chart = createYieldCurveChart(document.getElementById('container'), options);

Use this chart type when you need to visualize yield curves or similar financial data where the horizontal scale represents time durations rather than specific dates.

tip
If you want to spread out the beginning of the plot further and don't need a linear time scale, you can enforce a minimum spacing around each point by increasing the minBarSpacing option in the TimeScaleOptions. To prevent the rest of the chart from spreading too wide, adjust the baseResolution to a larger number, such as 12 (months).

const chartOptions = {
    layout: { textColor: 'black', background: { type: 'solid', color: 'white' } },
    yieldCurve: { baseResolution: 1, minimumTimeRange: 10, startTimeRange: 3 },
    handleScroll: false, handleScale: false,
};

const chart = createYieldCurveChart(document.getElementById('container'), chartOptions);
const lineSeries = chart.addSeries(LineSeries, { color: '#2962FF' });

const curve = [{ time: 1, value: 5.378 }, { time: 2, value: 5.372 }, { time: 3, value: 5.271 }, { time: 6, value: 5.094 }, { time: 12, value: 4.739 }, { time: 24, value: 4.237 }, { time: 36, value: 4.036 }, { time: 60, value: 3.887 }, { time: 84, value: 3.921 }, { time: 120, value: 4.007 }, { time: 240, value: 4.366 }, { time: 360, value: 4.290 }];

lineSeries.setData(curve);

chart.timeScale().fitContent();



Options Chart (Price-based)
The options chart is a specialized type that uses price values on the horizontal scale instead of time.

Creation method: createOptionsChart
Horizontal scale: Price-based (numeric)
Use case: Visualizing option chains, price distributions, or any data where price is the primary x-axis metric
import { createOptionsChart } from 'lightweight-charts';

const chart = createOptionsChart(document.getElementById('container'), options);

This chart type is particularly useful for financial instruments like options, where the price is a more relevant x-axis metric than time.

const chartOptions = {
    layout: { textColor: 'black', background: { type: 'solid', color: 'white' } },
};

const chart = createOptionsChart(document.getElementById('container'), chartOptions);
const lineSeries = chart.addSeries(LineSeries, { color: '#2962FF' });

const data = [];
for (let i = 0; i < 1000; i++) {
    data.push({
        time: i * 0.25,
        value: Math.sin(i / 100) + i / 500,
    });
}

lineSeries.setData(data);

chart.timeScale().fitContent();


Custom Horizontal Scale Chart
For advanced use cases, Lightweight Charts allows creating charts with custom horizontal scale behavior.

Creation method: createChartEx
Horizontal scale: Custom-defined
Use case: Specialized charting needs with non-standard horizontal scales
import { createChartEx, defaultHorzScaleBehavior } from 'lightweight-charts';

const customBehavior = new (defaultHorzScaleBehavior())();
// Customize the behavior as needed

const chart = createChartEx(document.getElementById('container'), customBehavior, options);

This method provides the flexibility to define custom horizontal scale behavior, allowing for unique and specialized chart types.

Choosing the Right Chart Type
Use createChart for most standard time-based charting needs.
Choose createYieldCurveChart when working specifically with yield curves or similar financial data.
Opt for createOptionsChart when you need to visualize data with price as the primary horizontal axis, such as option chains.
Use createChartEx when you need a custom horizontal scale behavior that differs from the standard time-based or price-based scales.
Each chart type provides specific functionality and is optimized for different use cases. Consider your data structure and visualization requirements when selecting the appropriate chart type for your application.

Previous
Series



Price scale
Price Scale (or price axis) is a vertical scale that mostly maps prices to coordinates and vice versa. The rules of converting depend on a price scale mode, a height of the chart and visible part of the data.

Price scales

By default, chart has 2 predefined price scales: left and right, and an unlimited number of overlay scales.

Only left and right price scales could be displayed on the chart, all overlay scales are hidden.

If you want to change left price scale, you need to use leftPriceScale option, to change right price scale use rightPriceScale, to change default options for an overlay price scale use overlayPriceScales option.

Alternatively, you can use IChartApi.priceScale method to get an API object of any price scale or ISeriesApi.priceScale to get an API object of series' price scale (the price scale that the series is attached to).

Creating a price scale
By default a chart has only 2 price scales: left and right.

If you want to create an overlay price scale, you can simply assign priceScaleId option to a series (note that a value should be differ from left and right) and a chart will automatically create an overlay price scale with provided ID. If a price scale with such ID already exists then a series will be attached to this existing price scale. Further you can use provided price scale ID to get its corresponding API object via IChartApi.priceScale method.

Removing a price scale
The default price scales (left and right) cannot be removed, you can only hide them by setting visible option to false.

An overlay price scale exists while there is at least 1 series attached to this price scale. Thus, to remove an overlay price scale remove all series attached to this price scale.

Version: 5.0
Time scale
Overview
Time scale (or time axis) is a horizontal scale that displays the time of data points at the bottom of the chart.

Time scale

The horizontal scale can also represent price or other custom values. Refer to the Chart types article for more information.

Time scale appearance
Use TimeScaleOptions to adjust the time scale appearance. You can specify these options in two ways:

On chart initialization. To do this, provide the desired options as a timeScale parameter when calling createChart.
On the fly using either the ITimeScaleApi.applyOptions or IChartApi.applyOptions method. Both methods produce the same result.
Time scale API
Call the IChartApi.timeScale method to get an instance of the ITimeScaleApi interface. This interface provides an extensive API for controlling the time scale. For example, you can adjust the visible range, convert a time point or index to a coordinate, and subscribe to events.

chart.timeScale().resetTimeScale();

Visible range
Visible range is a chart area that is currently visible on the canvas. This area can be measured with both data and logical range. Data range usually includes bar timestamps, while logical range has bar indices.

You can adjust the visible range using the following methods:

setVisibleRange
getVisibleRange
setVisibleLogicalRange
getVisibleLogicalRange
Data range
The data range includes only values from the first to the last bar visible on the chart. If the visible area has empty space, this part of the scale is not included in the data range.

Note that you cannot extrapolate time with the setVisibleRange method. For example, the chart does not have data prior 2018-01-01 date. If you set the visible range from 2016-01-01, it will be automatically adjusted to 2018-01-01.

If you want to adjust the visible range more flexible, operate with the logical range instead.

Logical range
The logical range represents a continuous line of values. These values are logical indices on the scale that illustrated as red lines in the image below:

Logical range

The logical range starts from the first data point across all series, with negative indices before it and positive ones after.

The indices can have fractional parts. The integer part represents the fully visible bar, while the fractional part indicates partial visibility. For example, the 5.2 index means that the fifth bar is fully visible, while the sixth bar is 20% visible. A half-index, such as 3.5, represents the middle of the bar.

In the library, the logical range is represented with the LogicalRange object. This object has the from and to properties, which are logical indices on the time scale. For example, the visible logical range on the chart above is approximately from -4.73 to 5.05.

The setVisibleLogicalRange method allows you to specify the visible range beyond the bounds of the available data. This can be useful for setting a chart margin or aligning series visually.

Chart margin
Margin is the space between the chart's borders and the series. It depends on the following time scale options:

barSpacing. The default value is 6.
rightOffset. The default value is 0.
You can specify these options as described in above.

Note that if a series contains only a few data points, the chart may have a large margin on the left side.

A series with a few points

In this case, you can call the fitContent method that adjust the view and fits all data within the chart.

chart.timeScale().fitContent();

If calling fitContent has no effect, it might be due to how the library displays data.

The library allocates specific width for each data point to maintain consistency between different chart types. For example, for line series, the plot point is placed at the center of this allocated space, while candlestick series use most of the width for the candle body. The allocated space for each data point is proportional to the chart width. As a result, series with fewer data points may have a small margin on both sides.

Margin

You can specify the logical range with the setVisibleLogicalRange method to display the series exactly to the edges. For example, the code sample below adjusts the range by half a bar-width on both sides.

const vr = chart.timeScale().getVisibleLogicalRange();
chart.timeScale().setVisibleLogicalRange({ from: vr.from + 0.5, to: vr.to - 0.5 });

Version: 5.0
Time zones
Overview
Lightweight Charts™ does not natively support time zones. If necessary, you should handle time zone adjustments manually.

The library processes all date and time values in UTC. To support time zones, adjust each bar's timestamp in your dataset based on the appropriate time zone offset. Therefore, a UTC timestamp should correspond to the local time in the target time zone.

Consider the example. A data point has the 2021-01-01T10:00:00.000Z timestamp in UTC. You want to display it in the Europe/Moscow time zone, which has the UTC+03:00 offset according to the IANA time zone database. To do this, adjust the original UTC timestamp by adding 3 hours. Therefore, the new timestamp should be 2021-01-01T13:00:00.000Z.

info
When converting time zones, consider the following:

Adding a time zone offset could change not only the time but the date as well.
An offset may vary due to DST (Daylight Saving Time) or other regional adjustments.
If your data is measured in business days and does not include a time component, in most cases, you should not adjust it to a time zone.
Approaches
Consider the approaches below to convert time values to the required time zone.

Using pure JavaScript
For more information on this approach, refer to StackOverflow.

function timeToTz(originalTime, timeZone) {
    const zonedDate = new Date(new Date(originalTime * 1000).toLocaleString('en-US', { timeZone }));
    return zonedDate.getTime() / 1000;
}

If you only need to support a client (local) time zone, you can use the following function:

function timeToLocal(originalTime) {
    const d = new Date(originalTime * 1000);
    return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()) / 1000;
}


Using the date-fns-tz library
You can use the utcToZonedTime function from the date-fns-tz library as follows:

import { utcToZonedTime } from 'date-fns-tz';

function timeToTz(originalTime, timeZone) {
    const zonedDate = utcToZonedTime(new Date(originalTime * 1000), timeZone);
    return zonedDate.getTime() / 1000;
}

Using the IANA time zone database
If you process a large dataset and approaches above do not meet your performance requirements, consider using the tzdata.

This approach can significantly improve performance for the following reasons:

You do not need to calculate the time zone offset for every data point individually. Instead, you can look up the correct offset just once for the first timestamp using a fast binary search.
After finding the starting offset, you go through the rest data and check whether an offset should be changed, for example, because of DST starting/ending.
Why are time zones not supported?
The approaches above were not implemented in Lightweight Charts™ for the following reasons:

Using pure JavaScript is slow. In our tests, processing 100,000 data points took over 20 seconds.
Using the date-fns-tz library introduces additional dependencies and is also slow. In our tests, processing 100,000 data points took 18 seconds.
Incorporating the IANA time zone database increases the bundle size by 29.9 kB, which is nearly the size of the entire Lightweight Charts™ library.
Since time zone support is not required for all users, it is intentionally left out of the library to maintain high performance and a lightweight package size.
