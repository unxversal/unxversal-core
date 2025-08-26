#!/usr/bin/env python3
"""
Fetch up to 1200 Switchboard 'surge' feeds, save to feeds.json,
and generate an offline HTML analytics viewer (index.html) with
click-to-sort (multi-column with Shift-click), filtering, and CSV export.

No external dependencies required.
"""

from __future__ import annotations
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

BASE_URL = "https://explorer.switchboardlabs.xyz/api/surge/feeds"
LIMIT_PER_PAGE = 25
MAX_FEEDS = 1200
SLEEP_BETWEEN_REQS_SEC = 0.15  # be polite

OUT_JSON = Path("feeds.json")
OUT_HTML = Path("index.html")


def http_get_json(url: str, retries: int = 3, backoff: float = 0.6) -> dict:
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            req = Request(url, headers={"User-Agent": "feeds-fetcher/1.1"})
            with urlopen(req, timeout=30) as resp:
                data = resp.read()
            return json.loads(data)
        except Exception as e:
            last_err = e
            print(f"[warn] attempt {attempt}/{retries} failed: {e}", file=sys.stderr, flush=True)
            if attempt < retries:
                time.sleep(backoff * attempt)
    raise last_err


def fetch_all(max_items: int = MAX_FEEDS, limit: int = LIMIT_PER_PAGE) -> list[dict]:
    page = 1
    seen = set()
    out: list[dict] = []
    total_pages = 0

    print(f"[info] Starting fetch: max_items={max_items}, page_size={limit}", flush=True)

    while len(out) < max_items:
        qs = urlencode({"page": page, "limit": limit})
        url = f"{BASE_URL}?{qs}"
        print(f"[fetch] page {page} -> {url}", flush=True)

        try:
            payload = http_get_json(url)
        except Exception as e:
            print(f"[error] giving up on page {page}: {e}", file=sys.stderr, flush=True)
            break

        feeds = payload.get("feeds") or []
        count = len(feeds)
        print(f"[ok] page {page} received {count} feeds", flush=True)

        if count == 0:
            print("[done] no more feeds available from API", flush=True)
            break

        before_seen = len(seen)
        before_out = len(out)

        for f in feeds:
            slug = f.get("slug")
            if slug and slug not in seen:
                seen.add(slug)
                out.append(f)
                if len(out) >= max_items:
                    break

        added = len(out) - before_out
        dupes = count - added
        print(
            f"[agg] page {page}: added {added} new, {dupes} duplicates; "
            f"running unique total = {len(out)}",
            flush=True,
        )

        total_pages += 1
        if count < limit:
            print("[done] last page returned fewer than page_size; stopping pagination", flush=True)
            break

        page += 1
        time.sleep(SLEEP_BETWEEN_REQS_SEC)

    print(f"[summary] fetched {len(out)} unique feeds across {total_pages} page(s)", flush=True)
    return out


def write_json(feeds: list[dict], path: Path) -> None:
    print(f"[write] saving {len(feeds)} feeds to {path.resolve()}", flush=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(feeds, f, ensure_ascii=False, indent=2)
        f.write("\n")


def write_html(feeds: list[dict], path: Path) -> None:
    # Embed JSON directly for offline usage.
    data_json = json.dumps(feeds, ensure_ascii=False)

    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Switchboard Feeds Viewer</title>
<style>
  :root {{
    --border:#e5e7eb; --muted:#64748b; --bg:#f8fafc; --ink:#0f172a;
    --pill:#eef2ff; --tag:#f1f5f9; --accent:#312e81;
  }}
  body {{ font: 14px/1.45 system-ui, -apple-system, Segoe UI, Roboto, Arial; margin: 24px; color: var(--ink); }}
  header {{ display: flex; align-items: baseline; gap: 12px; margin-bottom: 12px; }}
  .pill {{ display:inline-block; padding: 4px 8px; border-radius: 999px; background:var(--pill); margin-right:6px; }}
  #stats {{ display: grid; grid-template-columns: repeat(auto-fit,minmax(220px,1fr)); gap: 10px; margin: 12px 0 18px; }}
  .card {{ border: 1px solid var(--border); border-radius: 10px; padding: 12px; }}
  .muted {{ color:var(--muted); }}
  .row {{ display:flex; align-items:center; gap:8px; margin:10px 0 18px; flex-wrap:wrap; }}
  input[type="search"] {{ width: 320px; padding:8px 10px; border:1px solid #cbd5e1; border-radius:8px; }}
  button {{ padding:8px 10px; border:1px solid #cbd5e1; border-radius:8px; background:#fff; cursor:pointer; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ border-bottom: 1px solid var(--border); padding: 8px 6px; text-align: left; vertical-align: top; }}
  th {{ background: var(--bg); position: sticky; top: 0; z-index: 1; user-select: none; }}
  th.sortable {{ cursor: pointer; }}
  th .arrow {{ margin-left: 6px; color: var(--accent); opacity: 0.9; }}
  .tags {{ display:flex; flex-wrap:wrap; gap:6px; }}
  .tag {{ background:var(--tag); padding:2px 6px; border-radius:6px; font-size:12px; }}
  .small {{ font-size: 12px; color:#475569; word-break: break-all; }}
  .kbd {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size:12px; padding:2px 4px; border:1px solid var(--border); border-bottom-width:2px; border-radius:4px; background:#fff; }}
  .help {{ color: var(--muted); font-size: 12px; }}
</style>
</head>
<body>
  <header>
    <h1>Switchboard Feeds</h1>
    <span id="count" class="pill"></span>
    <span id="updateRange" class="small"></span>
  </header>

  <div class="row">
    <input id="q" type="search" placeholder="Filter by name/base/quote/category/slug…" />
    <button id="clearBtn" title="Clear filter">Clear</button>
    <button id="exportCsv" title="Download current view as CSV">Export CSV</button>
    <span class="help">Tip: Click a column header to sort. Shift-click to add secondary sorts. Click again to toggle ↑/↓.</span>
  </div>

  <section id="stats">
    <div class="card">
      <div class="muted">Top Categories</div>
      <div id="topCats"></div>
    </div>
    <div class="card">
      <div class="muted">Top Bases</div>
      <div id="topBases"></div>
    </div>
    <div class="card">
      <div class="muted">Top Quotes</div>
      <div id="topQuotes"></div>
    </div>
  </section>

  <table id="tbl">
    <thead>
      <tr id="thead-row">
        <!-- headers injected by JS -->
      </tr>
    </thead>
    <tbody></tbody>
  </table>

  <script id="data" type="application/json">{data_json}</script>
  <script>
  (function () {{
    const RAW = JSON.parse(document.getElementById('data').textContent || '[]');

    // Deduplicate by slug (defensive) and normalize
    const bySlug = new Map();
    RAW.forEach(f => {{ if (f && f.slug && !bySlug.has(f.slug)) bySlug.set(f.slug, f); }});
    const feeds = Array.from(bySlug.values());

    // Column model: label, key, getter for sort value, type, sortable
    const columns = [
      {{ key:'idx',      label:'#',        sortable:false }},
      {{ key:'name',     label:'Name',     sortable:true,  type:'string',  get:f=> (f.name??'') }},
      {{ key:'base',     label:'Base',     sortable:true,  type:'string',  get:f=> (f.base??'') }},
      {{ key:'quote',    label:'Quote',    sortable:true,  type:'string',  get:f=> (f.quote??'') }},
      {{ key:'rank',     label:'Rank',     sortable:true,  type:'number',  get:f=> (typeof f.rank==='number'?f.rank:Number.POSITIVE_INFINITY) }},
      {{ key:'surge',    label:'Surge',    sortable:true,  type:'boolean', get:f=> !!f.surge }},
      {{ key:'categories', label:'Categories', sortable:true, type:'string', get:f=> Array.isArray(f.categories)?f.categories.join('|'):'' }},
      {{ key:'updated',  label:'Updated',  sortable:true,  type:'date',    get:f=> Date.parse(f.updatedAt||f.createdAt||'') || 0 }},
      {{ key:'slug',     label:'Slug',     sortable:true,  type:'string',  get:f=> (f.slug??'') }},
    ];

    // Base sort (newest first)
    let sortSpec = [{{ key:'updated', dir:'desc' }}];

    // Filtering
    const q = document.getElementById('q');
    const clearBtn = document.getElementById('clearBtn');
    const countEl = document.getElementById('count');
    const updateRangeEl = document.getElementById('updateRange');
    const theadRow = document.getElementById('thead-row');
    const tbody = document.querySelector('#tbl tbody');

    // Render headers with sort indicators
    function renderHeaders() {{
      theadRow.innerHTML = '';
      columns.forEach(col => {{
        const th = document.createElement('th');
        th.textContent = col.label;
        if (col.sortable) {{
          th.classList.add('sortable');
          const arrow = document.createElement('span');
          arrow.className = 'arrow';
          const spec = sortSpec.find(s => s.key === col.key);
          if (spec) arrow.textContent = spec.dir === 'asc' ? '▲' : '▼';
          else arrow.textContent = '↕';
          th.appendChild(arrow);

          th.addEventListener('click', (ev) => onHeaderClick(col.key, ev.shiftKey));
        }}
        theadRow.appendChild(th);
      }});
    }}

    function onHeaderClick(key, isShift) {{
      const col = columns.find(c => c.key === key);
      if (!col || !col.sortable) return;
      const existingIdx = sortSpec.findIndex(s => s.key === key);

      if (!isShift) {{
        // Replace sortSpec with this column, toggle direction if already primary
        if (existingIdx === 0) {{
          sortSpec[0].dir = sortSpec[0].dir === 'asc' ? 'desc' : 'asc';
        }} else {{
          const dir = (existingIdx >= 0) ? sortSpec[existingIdx].dir : 'asc';
          sortSpec = [{{ key, dir }}];
        }}
      }} else {{
        // Multi-sort: add or toggle this key while preserving others
        if (existingIdx >= 0) {{
          sortSpec[existingIdx].dir = sortSpec[existingIdx].dir === 'asc' ? 'desc' : 'asc';
        }} else {{
          sortSpec.push({{ key, dir:'asc' }});
        }}
      }}
      renderHeaders();
      update();
    }}

    // Sorting comparator using sortSpec and column types
    function cmp(a, b) {{
      for (const spec of sortSpec) {{
        const col = columns.find(c => c.key === spec.key);
        if (!col) continue;
        const av = col.get ? col.get(a) : a[spec.key];
        const bv = col.get ? col.get(b) : b[spec.key];
        let diff = 0;
        switch (col.type) {{
          case 'number': diff = (av ?? Infinity) - (bv ?? Infinity); break;
          case 'boolean': diff = (av === bv) ? 0 : (av ? 1 : -1); break;
          case 'date': diff = (av ?? 0) - (bv ?? 0); break;
          default: {{
            const as = (av ?? '').toString().toLowerCase();
            const bs = (bv ?? '').toString().toLowerCase();
            diff = as < bs ? -1 : as > bs ? 1 : 0;
          }}
        }}
        if (diff !== 0) return spec.dir === 'asc' ? diff : -diff;
      }}
      return 0;
    }}

    // Quick analytics + updated range
    const ds = feeds
      .map(f => new Date(f.updatedAt || f.createdAt || 0))
      .filter(d => !isNaN(d))
      .sort((a,b) => a-b);
    if (ds.length) {{
      updateRangeEl.textContent = `Updated between ${{ds[0].toLocaleString()}} → ${{ds[ds.length-1].toLocaleString()}}`;
    }}
    function topCounts(items, keyFn, topN=8) {{
      const m = new Map();
      items.forEach(it => {{
        const k = keyFn(it);
        if (!k) return;
        if (Array.isArray(k)) k.forEach(kk => m.set(kk, (m.get(kk)||0)+1));
        else m.set(k, (m.get(k)||0)+1);
      }});
      return [...m.entries()].sort((a,b)=>b[1]-a[1]).slice(0, topN);
    }}
    const fmtDate = iso => iso ? new Date(iso).toLocaleString() : '';

    function renderStats(rows) {{
      const topCats = topCounts(rows, f => f.categories || []);
      const topBases = topCounts(rows, f => f.base);
      const topQuotes = topCounts(rows, f => f.quote);
      const renderList = (id, entries) => {{
        const el = document.getElementById(id);
        el.innerHTML = entries.map(([k,v]) => `<div>${{k}}: <strong>${{v}}</strong></div>`).join('');
      }};
      renderList('topCats', topCats);
      renderList('topBases', topBases);
      renderList('topQuotes', topQuotes);
    }}

    function applyFilter(rows) {{
      const s = q.value.trim().toLowerCase();
      if (!s) return rows;
      return rows.filter(f => {{
        const hay = [
          f.name, f.base, f.quote, f.slug,
          ...(Array.isArray(f.categories) ? f.categories : [])
        ].filter(Boolean).join(' ').toLowerCase();
        return hay.includes(s);
      }});
    }}

    function renderRows(rows) {{
      tbody.innerHTML = '';
      rows.forEach((f, i) => {{
        const tr = document.createElement('tr');
        const cats = Array.isArray(f.categories) ? f.categories : [];
        tr.innerHTML = `
          <td>${{i+1}}</td>
          <td>${{f.name ?? ''}}</td>
          <td>${{f.base ?? ''}}</td>
          <td>${{f.quote ?? ''}}</td>
          <td>${{(f.rank ?? '')}}</td>
          <td>${{f.surge ? '✓' : ''}}</td>
          <td class="tags">${{cats.map(c=>`<span class="tag">${{c}}</span>`).join(' ')}}</td>
          <td>${{fmtDate(f.updatedAt || f.createdAt)}}</td>
          <td class="small">${{f.slug ?? ''}}</td>
        `;
        tbody.appendChild(tr);
      }});
    }}

    function update() {{
      // Start with full set, sort, then filter view
      const sorted = feeds.slice().sort(cmp);
      const filtered = applyFilter(sorted);
      countEl.textContent = filtered.length + ' feeds';
      renderRows(filtered);
      renderStats(filtered);
    }}

    // Initial header & view
    renderHeaders();
    // Base default sort already set to updated desc
    update();

    // Filter events
    q.addEventListener('input', update);
    clearBtn.addEventListener('click', () => {{ q.value = ''; update(); }});

    // CSV export (current view order & filter)
    function toCsv(rows) {{
      const esc = (v) => {{
        const s = (v ?? '').toString();
        return /[",\\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
      }};
      const header = ['name','base','quote','rank','surge','categories','updatedAt','slug'];
      const lines = [header.join(',')];
      rows.forEach(f => {{
        const cats = Array.isArray(f.categories) ? f.categories.join('|') : '';
        lines.push([
          esc(f.name), esc(f.base), esc(f.quote), esc(f.rank),
          esc(!!f.surge), esc(cats), esc(f.updatedAt || f.createdAt), esc(f.slug)
        ].join(','));
      }});
      return lines.join('\\n');
    }}
    document.getElementById('exportCsv').addEventListener('click', () => {{
      const sorted = feeds.slice().sort(cmp);
      const rows = applyFilter(sorted);
      const blob = new Blob([toCsv(rows)], {{ type: 'text/csv;charset=utf-8;' }});
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'feeds.csv';
      a.click();
      URL.revokeObjectURL(url);
    }});
  }})();
  </script>
</body>
</html>"""
    print(f"[write] saving interactive HTML to {path.resolve()}", flush=True)
    path.write_text(html, encoding="utf-8")


def main():
    print(f"[info] Fetching up to {MAX_FEEDS} feeds …", flush=True)
    feeds = fetch_all(MAX_FEEDS, LIMIT_PER_PAGE)

    # final dedupe + cap
    by_slug = {}
    for f in feeds:
        slug = f.get("slug")
        if slug and slug not in by_slug:
            by_slug[slug] = f
    feeds = list(by_slug.values())[:MAX_FEEDS]
    print(f"[info] Final unique count: {len(feeds)}", flush=True)

    # Write files
    write_json(feeds, OUT_JSON)
    write_html(feeds, OUT_HTML)

    print("========================================", flush=True)
    print(f"Done.\n - JSON: {OUT_JSON.resolve()} ({len(feeds)} feeds)\n - HTML: {OUT_HTML.resolve()}", flush=True)
    print("Open index.html in your browser (works offline).", flush=True)


if __name__ == "__main__":
    main()
