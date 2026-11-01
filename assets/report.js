(() => {
  'use strict';

  const VHOST_PALETTE = [
    '#38bdf8', '#a855f7', '#10b981', '#f59e0b',
    '#ec4899', '#6366f1', '#14b8a6', '#f97316',
    '#84cc16', '#06b6d4', '#eab308', '#f43f5e'
  ];

  const DATA = window.REPORT_DATA || {};

  const state = {
    startTs: null,
    endTs: null,
    granularity: 'auto',
    compareMetric: 'requests',
    shareMetric: 'requests',
    vhostChartMode: 'status',
    logsPage: 1,
    logsPerPage: 50,
    charts: {}
  };

  function fmtNumber(n) {
    return Number(n || 0).toLocaleString('en-US');
  }

  function fmtBytes(bytes) {
    const b = Number(bytes || 0);
    if (b === 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.min(Math.floor(Math.log(b) / Math.log(1024)), units.length - 1);
    const val = b / Math.pow(1024, i);
    return `${val.toFixed(i === 0 ? 0 : 2)} ${units[i]}`;
  }

  function fmtTimestampUTC(epoch, granularity = 'hour') {
    if (!epoch) return '-';
    const d = new Date(Number(epoch) * 1000);
    const yyyy = d.getUTCFullYear();
    const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
    const dd = String(d.getUTCDate()).padStart(2, '0');
    if (granularity === 'day') {
      return `${yyyy}-${mm}-${dd}`;
    }
    const hh = String(d.getUTCHours()).padStart(2, '0');
    const min = String(d.getUTCMinutes()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd} ${hh}:${min}`;
  }

  function fmtFullDateTimeUTC(epoch) {
    if (!epoch) return '-';
    const d = new Date(Number(epoch) * 1000);
    return d.toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
  }

  function epochToInputVal(epoch) {
    if (!epoch) return '';
    const d = new Date(Number(epoch) * 1000);
    return d.toISOString().slice(0, 16);
  }

  function inputValToEpoch(val) {
    if (!val) return null;
    const ms = Date.parse(val.endsWith('Z') ? val : `${val}:00Z`);
    return Number.isNaN(ms) ? null : Math.floor(ms / 1000);
  }

  function escapeHtml(str) {
    return String(str ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function statusBadgeClass(status) {
    const s = Number(status);
    if (s >= 200 && s < 300) return 'badge-2xx';
    if (s >= 300 && s < 400) return 'badge-3xx';
    if (s >= 400 && s < 500) return 'badge-4xx';
    return 'badge-5xx';
  }

  function destroyChart(key) {
    if (state.charts[key]) {
      state.charts[key].destroy();
      delete state.charts[key];
    }
  }

  function resolveGranularity() {
    if (state.granularity === 'hour' || state.granularity === 'day') {
      return state.granularity;
    }
    const span = (state.endTs || 0) - (state.startTs || 0);
    return span > 14 * 86400 ? 'day' : 'hour';
  }

  function setupSharedNavigation() {
    const vhostSelect = document.getElementById( 'vhost-nav-select' );
    if ( vhostSelect ) {
      vhostSelect.addEventListener( 'change', e => {
        let target = e.target.value;
        if ( target ) {
          if ( DATA.page_type === 'vhost_details' && target.endsWith( '.html' ) && ! target.endsWith( 'index.html' ) ) {
            if ( ! target.includes( '-details.html' ) ) {
              target = target.replace( /\.html$/, '-details.html' );
            }
          }
          else if ( DATA.page_type === 'vhost_charts' && target.endsWith( '.html' ) ) {
            target = target.replace( /-details\.html$/, '.html' );
          }
          window.location.href = target;
        }
      } );
    }

    const startInput = document.getElementById('start-date');
    const endInput = document.getElementById('end-date');
    const granSelect = document.getElementById('granularity-select');

    if (startInput && endInput) {
      const minTs = DATA.min_ts || DATA.first_seen || Math.floor(Date.now() / 1000) - 86400;
      const maxTs = DATA.max_ts || DATA.last_seen || Math.floor(Date.now() / 1000);
      state.startTs = minTs;
      state.endTs = maxTs;
      startInput.value = epochToInputVal(state.startTs);
      endInput.value = epochToInputVal(state.endTs);

      const onDateChange = () => {
        document.querySelectorAll('[data-range]').forEach(b => b.classList.remove('active'));
        state.startTs = inputValToEpoch(startInput.value) || minTs;
        state.endTs = inputValToEpoch(endInput.value) || maxTs;
        renderCurrentPage();
      };
      startInput.addEventListener('change', onDateChange);
      endInput.addEventListener('change', onDateChange);

      document.querySelectorAll('[data-range]').forEach(btn => {
        btn.addEventListener('click', () => {
          document.querySelectorAll('[data-range]').forEach(b => b.classList.remove('active'));
          btn.classList.add('active');
          const r = btn.dataset.range;
          state.endTs = maxTs;
          if (r === '24h') state.startTs = maxTs - 86400;
          else if (r === '7d') state.startTs = maxTs - 7 * 86400;
          else if (r === '30d') state.startTs = maxTs - 30 * 86400;
          else state.startTs = minTs;

          startInput.value = epochToInputVal(state.startTs);
          endInput.value = epochToInputVal(state.endTs);
          renderCurrentPage();
        });
      });
    }

    if (granSelect) {
      granSelect.addEventListener('change', e => {
        state.granularity = e.target.value;
        renderCurrentPage();
      });
    }
  }

  function renderCurrentPage() {
    if (DATA.page_type === 'compare') {
      renderComparePage();
    } else if (DATA.page_type === 'vhost_charts') {
      renderVhostChartsPage();
    } else if (DATA.page_type === 'vhost_details') {
      renderVhostDetailsPage();
    }
  }

  // ===========================================================================
  // PAGE TYPE 1: ALL VIRTUAL HOSTS COMPARISON (index.html)
  // ===========================================================================
  function computeCompareDataset() {
    const vhosts = DATA.vhosts || [];
    const startHour = state.startTs ? state.startTs - (state.startTs % 3600) : 0;
    const endHour = state.endTs || Number.MAX_SAFE_INTEGER;
    const gran = resolveGranularity();

    const bucketsSet = new Set();
    const seriesByVhost = {};
    const summaries = [];

    let globalReqs = 0;
    let globalBytes = 0;
    let globalErrs = 0;
    let global5xx = 0;
    let globalBots = 0;
    let globalIps = 0;

    for (const v of vhosts) {
      const hourly = v.hourly || {};
      let reqs = 0, bytes = 0, s2xx = 0, s3xx = 0, s4xx = 0, s5xx = 0, bots = 0, humans = 0;
      const bMap = {};

      for (const [hbStr, stats] of Object.entries(hourly)) {
        const hb = Number(hbStr);
        if (hb < startHour || hb > endHour) continue;

        reqs += stats.requests || 0;
        bytes += stats.bytes || 0;
        s2xx += stats.status_2xx || 0;
        s3xx += stats.status_3xx || 0;
        s4xx += stats.status_4xx || 0;
        s5xx += stats.status_5xx || 0;
        bots += stats.bot_requests || 0;
        humans += stats.human_requests || 0;

        const bucketKey = gran === 'day' ? (hb - (hb % 86400)) : hb;
        bucketsSet.add(bucketKey);
        if (!bMap[bucketKey]) {
          bMap[bucketKey] = { requests: 0, bytes: 0, errors: 0 };
        }
        bMap[bucketKey].requests += stats.requests || 0;
        bMap[bucketKey].bytes += stats.bytes || 0;
        bMap[bucketKey].errors += (stats.status_4xx || 0) + (stats.status_5xx || 0);
      }

      seriesByVhost[v.slug] = bMap;

      const errs = s4xx + s5xx;
      summaries.push({
        name: v.name,
        slug: v.slug,
        chart_href: v.chart_href,
        details_href: v.details_href,
        unique_ips: v.unique_ips || 0,
        requests: reqs,
        bytes,
        status_2xx: s2xx,
        status_3xx: s3xx,
        status_4xx: s4xx,
        status_5xx: s5xx,
        bot_requests: bots,
        human_requests: humans,
        error_rate_pct: reqs > 0 ? ((errs / reqs) * 100) : 0,
        bot_pct: reqs > 0 ? ((bots / reqs) * 100) : 0
      });

      globalReqs += reqs;
      globalBytes += bytes;
      globalErrs += errs;
      global5xx += s5xx;
      globalBots += bots;
      globalIps += v.unique_ips || 0;
    }

    summaries.sort((a, b) => b.requests - a.requests);
    for (const s of summaries) {
      s.request_share_pct = globalReqs > 0 ? (s.requests / globalReqs) * 100 : 0;
    }

    const buckets = Array.from(bucketsSet).sort((a, b) => a - b);

    return {
      granularity: gran,
      buckets,
      seriesByVhost,
      summaries,
      kpis: {
        total_requests: globalReqs,
        total_bytes: globalBytes,
        active_vhosts: summaries.filter(s => s.requests > 0).length,
        total_vhosts: summaries.length,
        unique_ips: globalIps,
        error_rate_pct: globalReqs > 0 ? (globalErrs / globalReqs) * 100 : 0,
        error_5xx_count: global5xx,
        bot_pct: globalReqs > 0 ? (globalBots / globalReqs) * 100 : 0
      }
    };
  }

  function renderComparePage() {
    const computed = computeCompareDataset();
    const k = computed.kpis;

    document.getElementById('cmp-kpi-requests').textContent = fmtNumber(k.total_requests);
    document.getElementById('cmp-kpi-vhosts').textContent = `${k.active_vhosts} of ${k.total_vhosts} active vhosts`;
    document.getElementById('cmp-kpi-bytes').textContent = fmtBytes(k.total_bytes);
    const avgB = k.total_requests > 0 ? Math.round(k.total_bytes / k.total_requests) : 0;
    document.getElementById('cmp-kpi-avg-bytes').textContent = `Avg ${fmtBytes(avgB)} / req`;
    document.getElementById('cmp-kpi-ips').textContent = fmtNumber(k.unique_ips);
    document.getElementById('cmp-kpi-err-rate').textContent = `${k.error_rate_pct.toFixed(2)}%`;
    document.getElementById('cmp-kpi-5xx-count').textContent = `${fmtNumber(k.error_5xx_count)} server (5xx) errors`;
    document.getElementById('cmp-kpi-bot-pct').textContent = `${k.bot_pct.toFixed(1)}%`;

    // 1. Timeline Chart
    destroyChart('compareTimeline');
    const metric = state.compareMetric;
    const labels = computed.buckets.map(b => fmtTimestampUTC(b, computed.granularity));
    const datasets = computed.summaries.map((s, idx) => {
      const color = VHOST_PALETTE[idx % VHOST_PALETTE.length];
      const bMap = computed.seriesByVhost[s.slug] || {};
      return {
        label: s.name,
        data: computed.buckets.map(b => (bMap[b] ? bMap[b][metric] : 0)),
        borderColor: color,
        backgroundColor: `${color}28`,
        borderWidth: 2,
        pointRadius: computed.buckets.length > 48 ? 0 : 3,
        tension: 0.25,
        fill: true
      };
    });

    const ctxTime = document.getElementById('chart-compare-timeline').getContext('2d');
    state.charts.compareTimeline = new Chart(ctxTime, {
      type: 'line',
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { labels: { color: '#cbd5e1' } },
          tooltip: {
            callbacks: {
              label(ctx) {
                const v = ctx.parsed.y;
                return `${ctx.dataset.label}: ${metric === 'bytes' ? fmtBytes(v) : fmtNumber(v)}`;
              }
            }
          }
        },
        scales: {
          x: { ticks: { color: '#94a3b8', maxRotation: 0, autoSkip: true, maxTicksLimit: 12 }, grid: { color: 'rgba(51,65,85,0.35)' } },
          y: {
            beginAtZero: true,
            ticks: { color: '#94a3b8', callback: v => (metric === 'bytes' ? fmtBytes(v) : fmtNumber(v)) },
            grid: { color: 'rgba(51,65,85,0.35)' }
          }
        }
      }
    });

    // 2. Traffic Share Chart
    destroyChart('compareShare');
    const shareM = state.shareMetric;
    const ctxShare = document.getElementById('chart-compare-share').getContext('2d');
    state.charts.compareShare = new Chart(ctxShare, {
      type: 'doughnut',
      data: {
        labels: computed.summaries.map(s => s.name),
        datasets: [{
          data: computed.summaries.map(s => s[shareM]),
          backgroundColor: computed.summaries.map((_, i) => VHOST_PALETTE[i % VHOST_PALETTE.length]),
          borderColor: '#1e293b',
          borderWidth: 2
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: 'right', labels: { color: '#cbd5e1' } },
          tooltip: {
            callbacks: {
              label(ctx) {
                const v = ctx.parsed;
                return `${ctx.label}: ${shareM === 'bytes' ? fmtBytes(v) : fmtNumber(v)}`;
              }
            }
          }
        }
      }
    });

    // 3. Status Code Breakdown Chart
    destroyChart('compareStatus');
    const ctxStatus = document.getElementById('chart-compare-status').getContext('2d');
    state.charts.compareStatus = new Chart(ctxStatus, {
      type: 'bar',
      data: {
        labels: computed.summaries.map(s => s.name),
        datasets: [
          { label: '2xx OK', data: computed.summaries.map(s => s.status_2xx), backgroundColor: '#10b981' },
          { label: '3xx Redirect', data: computed.summaries.map(s => s.status_3xx), backgroundColor: '#3b82f6' },
          { label: '4xx Client Err', data: computed.summaries.map(s => s.status_4xx), backgroundColor: '#f59e0b' },
          { label: '5xx Server Err', data: computed.summaries.map(s => s.status_5xx), backgroundColor: '#ef4444' }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { labels: { color: '#cbd5e1' } } },
        scales: {
          x: { stacked: true, ticks: { color: '#94a3b8' }, grid: { color: 'rgba(51,65,85,0.35)' } },
          y: { stacked: true, beginAtZero: true, ticks: { color: '#94a3b8' }, grid: { color: 'rgba(51,65,85,0.35)' } }
        }
      }
    });

    // 4. Vhost Comparison Table
    const tbody = document.getElementById('tbody-compare-vhosts');
    if (!computed.summaries.length) {
      tbody.innerHTML = '<tr><td colspan="12" style="text-align:center;color:#94a3b8;">No virtual host logs ingested yet. Run bin/build_reports.pl to generate reports.</td></tr>';
      return;
    }

    tbody.innerHTML = computed.summaries.map((v, idx) => {
      const color = VHOST_PALETTE[idx % VHOST_PALETTE.length];
      const errBadge = v.error_rate_pct >= 5 ? 'badge-5xx' : (v.error_rate_pct >= 1 ? 'badge-4xx' : 'badge-2xx');
      return `
        <tr>
          <td>
            <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${color};margin-right:8px;"></span>
            <a href="${escapeHtml(v.chart_href)}"><strong>${escapeHtml(v.name)}</strong></a>
          </td>
          <td class="num">${fmtNumber(v.requests)}</td>
          <td class="num">${v.request_share_pct.toFixed(1)}%</td>
          <td class="num">${fmtNumber(v.unique_ips)}</td>
          <td class="num">${fmtBytes(v.bytes)}</td>
          <td class="num">${fmtNumber(v.status_2xx)}</td>
          <td class="num">${fmtNumber(v.status_3xx)}</td>
          <td class="num">${fmtNumber(v.status_4xx)}</td>
          <td class="num">${fmtNumber(v.status_5xx)}</td>
          <td class="num"><span class="badge ${errBadge}">${v.error_rate_pct.toFixed(2)}%</span></td>
          <td class="num">${v.bot_pct.toFixed(1)}%</td>
          <td>
            <div class="action-links">
              <a href="${escapeHtml(v.chart_href)}" class="btn btn-primary btn-sm">📈 Charts</a>
              <a href="${escapeHtml(v.details_href)}" class="btn btn-secondary btn-sm">🔎 Details</a>
            </div>
          </td>
        </tr>
      `;
    }).join('');
  }

  // ===========================================================================
  // PAGE TYPE 2: SINGLE VIRTUAL HOST CHARTS VIEW (vhosts/<slug>.html)
  // ===========================================================================
  function renderVhostChartsPage() {
    const hourly = DATA.hourly || {};
    const startHour = state.startTs ? state.startTs - (state.startTs % 3600) : 0;
    const endHour = state.endTs || Number.MAX_SAFE_INTEGER;
    const gran = resolveGranularity();

    let reqs = 0, bytes = 0, s2xx = 0, s3xx = 0, s4xx = 0, s5xx = 0, bots = 0, humans = 0;
    const bucketMap = {};

    for (const [hbStr, stats] of Object.entries(hourly)) {
      const hb = Number(hbStr);
      if (hb < startHour || hb > endHour) continue;

      reqs += stats.requests || 0;
      bytes += stats.bytes || 0;
      s2xx += stats.status_2xx || 0;
      s3xx += stats.status_3xx || 0;
      s4xx += stats.status_4xx || 0;
      s5xx += stats.status_5xx || 0;
      bots += stats.bot_requests || 0;
      humans += stats.human_requests || 0;

      const bKey = gran === 'day' ? (hb - (hb % 86400)) : hb;
      if (!bucketMap[bKey]) {
        bucketMap[bKey] = {
          requests: 0, bytes: 0,
          status_2xx: 0, status_3xx: 0, status_4xx: 0, status_5xx: 0,
          bot_requests: 0, human_requests: 0
        };
      }
      const b = bucketMap[bKey];
      b.requests += stats.requests || 0;
      b.bytes += stats.bytes || 0;
      b.status_2xx += stats.status_2xx || 0;
      b.status_3xx += stats.status_3xx || 0;
      b.status_4xx += stats.status_4xx || 0;
      b.status_5xx += stats.status_5xx || 0;
      b.bot_requests += stats.bot_requests || 0;
      b.human_requests += stats.human_requests || 0;
    }

    const subEl = document.getElementById('vh-subtitle');
    if (subEl) {
      subEl.textContent = `Active from ${fmtFullDateTimeUTC(DATA.first_seen)} to ${fmtFullDateTimeUTC(DATA.last_seen)}`;
    }

    const uniqueIps = DATA.unique_ips || 0;
    document.getElementById('vh-kpi-requests').textContent = fmtNumber(reqs);
    document.getElementById('vh-kpi-2xx').textContent = `${fmtNumber(s2xx)} successful (2xx)`;
    document.getElementById('vh-kpi-ips').textContent = fmtNumber(uniqueIps);
    document.getElementById('vh-kpi-req-per-ip').textContent =
      `${uniqueIps > 0 ? (reqs / uniqueIps).toFixed(1) : '0.0'} req / IP`;

    document.getElementById('vh-kpi-bytes').textContent = fmtBytes(bytes);
    const avgBytes = reqs > 0 ? Math.round(bytes / reqs) : 0;
    document.getElementById('vh-kpi-avg-bytes').textContent = `Avg ${fmtBytes(avgBytes)} / response`;

    const errPct = reqs > 0 ? (((s4xx + s5xx) / reqs) * 100).toFixed(2) : '0.00';
    document.getElementById('vh-kpi-err-rate').textContent = `${errPct}%`;
    document.getElementById('vh-kpi-err-breakdown').textContent =
      `4xx: ${fmtNumber(s4xx)} | 5xx: ${fmtNumber(s5xx)}`;

    const botPct = reqs > 0 ? ((bots / reqs) * 100).toFixed(1) : '0.0';
    document.getElementById('vh-kpi-bot-pct').textContent = `${botPct}% Bots`;
    document.getElementById('vh-kpi-bot-counts').textContent =
      `${fmtNumber(humans)} human / ${fmtNumber(bots)} bot`;

    // 1. Timeline Chart
    destroyChart('vhostTimeline');
    const sortedBuckets = Object.keys(bucketMap).map(Number).sort((a, b) => a - b);
    const labels = sortedBuckets.map(b => fmtTimestampUTC(b, gran));
    const mode = state.vhostChartMode;

    let datasets = [];
    let chartType = 'bar';
    let stacked = true;

    if (mode === 'status') {
      datasets = [
        { label: '2xx OK', data: sortedBuckets.map(b => bucketMap[b].status_2xx), backgroundColor: '#10b981' },
        { label: '3xx Redirect', data: sortedBuckets.map(b => bucketMap[b].status_3xx), backgroundColor: '#3b82f6' },
        { label: '4xx Client Err', data: sortedBuckets.map(b => bucketMap[b].status_4xx), backgroundColor: '#f59e0b' },
        { label: '5xx Server Err', data: sortedBuckets.map(b => bucketMap[b].status_5xx), backgroundColor: '#ef4444' }
      ];
    } else if (mode === 'bytes') {
      chartType = 'line';
      stacked = false;
      datasets = [{
        label: 'Bandwidth Transferred',
        data: sortedBuckets.map(b => bucketMap[b].bytes),
        borderColor: '#38bdf8',
        backgroundColor: 'rgba(56, 189, 248, 0.2)',
        fill: true,
        tension: 0.25
      }];
    } else if (mode === 'bots') {
      datasets = [
        { label: 'Human Requests', data: sortedBuckets.map(b => bucketMap[b].human_requests), backgroundColor: '#38bdf8' },
        { label: 'Bot / Crawler Requests', data: sortedBuckets.map(b => bucketMap[b].bot_requests), backgroundColor: '#a855f7' }
      ];
    }

    const ctxTime = document.getElementById('chart-vhost-timeline').getContext('2d');
    state.charts.vhostTimeline = new Chart(ctxTime, {
      type: chartType,
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { labels: { color: '#cbd5e1' } },
          tooltip: {
            callbacks: {
              label(ctx) {
                const v = ctx.parsed.y;
                return `${ctx.dataset.label}: ${mode === 'bytes' ? fmtBytes(v) : fmtNumber(v)}`;
              }
            }
          }
        },
        scales: {
          x: { stacked, ticks: { color: '#94a3b8', maxRotation: 0, autoSkip: true, maxTicksLimit: 12 }, grid: { color: 'rgba(51,65,85,0.35)' } },
          y: {
            stacked,
            beginAtZero: true,
            ticks: { color: '#94a3b8', callback: v => (mode === 'bytes' ? fmtBytes(v) : fmtNumber(v)) },
            grid: { color: 'rgba(51,65,85,0.35)' }
          }
        }
      }
    });

    // 2. HTTP Methods Chart
    destroyChart('vhMethods');
    const methods = DATA.methods || [];
    const ctxMethods = document.getElementById('chart-vh-methods').getContext('2d');
    state.charts.vhMethods = new Chart(ctxMethods, {
      type: 'doughnut',
      data: {
        labels: methods.map(m => m.method),
        datasets: [{
          data: methods.map(m => m.requests),
          backgroundColor: VHOST_PALETTE,
          borderColor: '#1e293b',
          borderWidth: 2
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { position: 'right', labels: { color: '#cbd5e1' } } }
      }
    });

    // 3. Client Categories Chart
    destroyChart('vhUaCat');
    const uaCats = DATA.ua_categories || [];
    const ctxUa = document.getElementById('chart-vh-ua-cat').getContext('2d');
    state.charts.vhUaCat = new Chart(ctxUa, {
      type: 'doughnut',
      data: {
        labels: uaCats.map(u => u.ua_category),
        datasets: [{
          data: uaCats.map(u => u.requests),
          backgroundColor: ['#38bdf8', '#10b981', '#a855f7', '#f59e0b', '#64748b'],
          borderColor: '#1e293b',
          borderWidth: 2
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { position: 'right', labels: { color: '#cbd5e1' } } }
      }
    });

    // 4. Error Status Codes Chart
    destroyChart('vhErrorCodes');
    const errCodes = DATA.error_codes || [];
    const ctxErr = document.getElementById('chart-vh-error-codes').getContext('2d');
    state.charts.vhErrorCodes = new Chart(ctxErr, {
      type: 'bar',
      data: {
        labels: errCodes.map(c => String(c.status)),
        datasets: [{
          label: 'Occurrences',
          data: errCodes.map(c => c.requests),
          backgroundColor: errCodes.map(c => (c.status >= 500 ? '#ef4444' : '#f59e0b'))
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: {
          x: { ticks: { color: '#94a3b8' }, grid: { color: 'rgba(51,65,85,0.35)' } },
          y: { beginAtZero: true, ticks: { color: '#94a3b8' }, grid: { color: 'rgba(51,65,85,0.35)' } }
        }
      }
    });
  }

  // ===========================================================================
  // PAGE TYPE 3: DETAILED TRAFFIC & LOGS PAGE (vhosts/<slug>-details.html)
  // ===========================================================================
  function renderVhostDetailsPage() {
    renderEndpointsTable('');
    renderIpsTable('');
    renderUaAndReferrersTables();
    renderErrorsTables();
    renderFilteredRawLogs();
  }

  function renderEndpointsTable(query) {
    const q = (query || '').toLowerCase().trim();
    const eps = (DATA.endpoints || []).filter(ep => {
      if (!q) return true;
      return ep.path.toLowerCase().includes(q) || ep.method.toLowerCase().includes(q);
    });

    const tbody = document.getElementById('tbody-vh-endpoints');
    if (!eps.length) {
      tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;color:#94a3b8;">No matching endpoints found.</td></tr>';
      return;
    }

    tbody.innerHTML = eps.map(ep => `
      <tr>
        <td><span class="badge badge-method">${escapeHtml(ep.method)}</span></td>
        <td class="mono truncate-cell" title="${escapeHtml(ep.path)}">${escapeHtml(ep.path)}</td>
        <td class="num">${fmtNumber(ep.requests)}</td>
        <td class="num">${fmtBytes(ep.bytes)}</td>
        <td class="num">${fmtBytes(ep.avg_bytes)}</td>
        <td class="num">${ep.error_4xx > 0 ? `<span class="badge badge-4xx">${fmtNumber(ep.error_4xx)}</span>` : '0'}</td>
        <td class="num">${ep.error_5xx > 0 ? `<span class="badge badge-5xx">${fmtNumber(ep.error_5xx)}</span>` : '0'}</td>
        <td>
          <button type="button" class="btn btn-secondary btn-sm btn-inspect-logs"
            data-path="${escapeHtml(ep.path)}" data-method="${escapeHtml(ep.method)}">
            Logs
          </button>
        </td>
      </tr>
    `).join('');
  }

  function renderIpsTable(query) {
    const q = (query || '').toLowerCase().trim();
    const ips = (DATA.ips || []).filter(ip => !q || ip.client_ip.toLowerCase().includes(q));

    const tbody = document.getElementById('tbody-vh-ips');
    if (!ips.length) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;color:#94a3b8;">No matching client IPs found.</td></tr>';
      return;
    }

    tbody.innerHTML = ips.map(ip => `
      <tr>
        <td class="mono">${escapeHtml(ip.client_ip)}</td>
        <td class="num">${fmtNumber(ip.requests)}</td>
        <td class="num">${fmtBytes(ip.bytes)}</td>
        <td class="num">${ip.error_count > 0 ? `<span class="badge badge-4xx">${fmtNumber(ip.error_count)}</span>` : '0'}</td>
        <td>
          <button type="button" class="btn btn-secondary btn-sm btn-inspect-logs" data-ip="${escapeHtml(ip.client_ip)}">
            Logs
          </button>
        </td>
      </tr>
    `).join('');
  }

  function renderUaAndReferrersTables() {
    const uaFams = DATA.ua_families || [];
    document.getElementById('tbody-vh-ua-families').innerHTML = uaFams.map(u => `
      <tr>
        <td><span class="badge ${u.ua_category === 'Bot' ? 'badge-bot' : 'badge-method'}">${escapeHtml(u.ua_category)}</span></td>
        <td>${escapeHtml(u.ua_family)}</td>
        <td class="num">${fmtNumber(u.requests)}</td>
        <td class="num">${fmtBytes(u.bytes)}</td>
      </tr>
    `).join('');

    const refs = DATA.referrers || [];
    const tbodyRefs = document.getElementById('tbody-vh-referrers');
    if (!refs.length) {
      tbodyRefs.innerHTML = '<tr><td colspan="2" style="text-align:center;color:#94a3b8;">No external referrers recorded.</td></tr>';
    } else {
      tbodyRefs.innerHTML = refs.map(r => `
        <tr>
          <td class="mono truncate-cell" title="${escapeHtml(r.referer)}">${escapeHtml(r.referer)}</td>
          <td class="num">${fmtNumber(r.requests)}</td>
        </tr>
      `).join('');
    }
  }

  function renderErrorsTables() {
    const errUrls = DATA.error_urls || [];
    const tbodyUrls = document.getElementById('tbody-vh-error-urls');
    if (!errUrls.length) {
      tbodyUrls.innerHTML = '<tr><td colspan="6" style="text-align:center;color:#94a3b8;">Zero 4xx/5xx errors recorded!</td></tr>';
    } else {
      tbodyUrls.innerHTML = errUrls.map(e => `
        <tr>
          <td><span class="badge ${statusBadgeClass(e.status)}">${e.status}</span></td>
          <td><span class="badge badge-method">${escapeHtml(e.method)}</span></td>
          <td class="mono truncate-cell" title="${escapeHtml(e.path)}">${escapeHtml(e.path)}</td>
          <td class="num">${fmtNumber(e.requests)}</td>
          <td class="num">${fmtNumber(e.unique_ips)}</td>
          <td>
            <button type="button" class="btn btn-secondary btn-sm btn-inspect-logs"
              data-path="${escapeHtml(e.path)}" data-status="${e.status}" data-method="${escapeHtml(e.method)}">
              Logs
            </button>
          </td>
        </tr>
      `).join('');
    }

    const errIps = DATA.error_ips || [];
    const tbodyIps = document.getElementById('tbody-vh-error-ips');
    if (!errIps.length) {
      tbodyIps.innerHTML = '<tr><td colspan="5" style="text-align:center;color:#94a3b8;">No error-triggering IPs recorded.</td></tr>';
    } else {
      tbodyIps.innerHTML = errIps.map(ip => `
        <tr>
          <td class="mono">${escapeHtml(ip.client_ip)}</td>
          <td class="num">${fmtNumber(ip.count_4xx)}</td>
          <td class="num">${fmtNumber(ip.count_5xx)}</td>
          <td class="num">${fmtNumber(ip.distinct_paths)}</td>
          <td>
            <button type="button" class="btn btn-secondary btn-sm btn-inspect-logs"
              data-ip="${escapeHtml(ip.client_ip)}" data-status="errors">
              Logs
            </button>
          </td>
        </tr>
      `).join('');
    }
  }

  function renderFilteredRawLogs() {
    const allLogs = DATA.recent_logs || [];
    const pathQ = (document.getElementById('filter-path')?.value || '').toLowerCase().trim();
    const ipQ = (document.getElementById('filter-ip')?.value || '').toLowerCase().trim();
    const methodQ = document.getElementById('filter-method')?.value || '';
    const statusQ = document.getElementById('filter-status')?.value || '';
    const uaCatQ = document.getElementById('filter-ua-cat')?.value || '';

    const filtered = allLogs.filter(l => {
      if (methodQ && l.method !== methodQ) return false;
      if (uaCatQ && l.ua_category !== uaCatQ) return false;
      if (ipQ && !l.client_ip.toLowerCase().includes(ipQ)) return false;
      if (pathQ) {
        const fullUri = l.query_string ? `${l.path}?${l.query_string}` : l.path;
        if (!fullUri.toLowerCase().includes(pathQ)) return false;
      }
      if (statusQ) {
        const s = Number(l.status);
        if (statusQ === '2xx' && (s < 200 || s >= 300)) return false;
        else if (statusQ === '3xx' && (s < 300 || s >= 400)) return false;
        else if (statusQ === '4xx' && (s < 400 || s >= 500)) return false;
        else if (statusQ === '5xx' && s < 500) return false;
        else if (statusQ === 'errors' && s < 400) return false;
        else if (/^\d{3}$/.test(statusQ) && s !== Number(statusQ)) return false;
      }
      return true;
    });

    const total = filtered.length;
    const totalPages = Math.max(1, Math.ceil(total / state.logsPerPage));
    if (state.logsPage > totalPages) state.logsPage = totalPages;

    const startIdx = (state.logsPage - 1) * state.logsPerPage;
    const pageRows = filtered.slice(startIdx, startIdx + state.logsPerPage);

    const tbody = document.getElementById('tbody-raw-logs');
    if (!pageRows.length) {
      tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:#94a3b8;">No matching log entries found.</td></tr>';
    } else {
      tbody.innerHTML = pageRows.map(l => {
        const fullUri = l.query_string ? `${l.path}?${l.query_string}` : l.path;
        return `
          <tr>
            <td class="mono">${fmtFullDateTimeUTC(l.timestamp)}</td>
            <td class="mono">${escapeHtml(l.client_ip)}</td>
            <td><span class="badge badge-method">${escapeHtml(l.method)}</span></td>
            <td class="mono truncate-cell" title="${escapeHtml(fullUri)}">${escapeHtml(fullUri)}</td>
            <td><span class="badge ${statusBadgeClass(l.status)}">${l.status}</span></td>
            <td class="num">${fmtBytes(l.bytes)}</td>
            <td class="truncate-cell" title="${escapeHtml(l.user_agent)}">
              <span class="badge ${l.ua_category === 'Bot' ? 'badge-bot' : 'badge-method'}">${escapeHtml(l.ua_family)}</span>
              <span style="color:#94a3b8;font-size:0.76rem;margin-left:4px;">${escapeHtml(l.user_agent)}</span>
            </td>
          </tr>
        `;
      }).join('');
    }

    document.getElementById('raw-logs-summary').textContent =
      `Showing ${pageRows.length} of ${fmtNumber(total)} matching recent requests`;
    document.getElementById('raw-logs-page-indicator').textContent =
      `Page ${state.logsPage} of ${totalPages}`;
    document.getElementById('btn-logs-prev').disabled = state.logsPage <= 1;
    document.getElementById('btn-logs-next').disabled = state.logsPage >= totalPages;
  }

  function switchSubtab(tabId) {
    document.querySelectorAll('.subtab-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.subtab === tabId);
    });
    document.querySelectorAll('.subtab-panel').forEach(panel => {
      panel.hidden = panel.id !== tabId;
    });
  }

  function setupPageInteractions() {
    if (DATA.page_type === 'compare') {
      document.querySelectorAll('[data-cmp-metric]').forEach(btn => {
        btn.addEventListener('click', () => {
          document.querySelectorAll('[data-cmp-metric]').forEach(b => b.classList.remove('active'));
          btn.classList.add('active');
          state.compareMetric = btn.dataset.cmpMetric;
          renderComparePage();
        });
      });

      document.querySelectorAll('[data-share-metric]').forEach(btn => {
        btn.addEventListener('click', () => {
          document.querySelectorAll('[data-share-metric]').forEach(b => b.classList.remove('active'));
          btn.classList.add('active');
          state.shareMetric = btn.dataset.shareMetric;
          renderComparePage();
        });
      });
    } else if (DATA.page_type === 'vhost_charts') {
      document.querySelectorAll('[data-vh-chart-mode]').forEach(btn => {
        btn.addEventListener('click', () => {
          document.querySelectorAll('[data-vh-chart-mode]').forEach(b => b.classList.remove('active'));
          btn.classList.add('active');
          state.vhostChartMode = btn.dataset.vhChartMode;
          renderVhostChartsPage();
        });
      });
    } else if (DATA.page_type === 'vhost_details') {
      document.querySelectorAll('.subtab-btn').forEach(btn => {
        btn.addEventListener('click', () => switchSubtab(btn.dataset.subtab));
      });

      const epSearch = document.getElementById('search-endpoints');
      if (epSearch) {
        epSearch.addEventListener('input', e => renderEndpointsTable(e.target.value));
      }

      const ipSearch = document.getElementById('search-ips');
      if (ipSearch) {
        ipSearch.addEventListener('input', e => renderIpsTable(e.target.value));
      }

      document.body.addEventListener('click', e => {
        const btn = e.target.closest('.btn-inspect-logs');
        if (!btn) return;
        document.getElementById('filter-path').value = btn.dataset.path || '';
        document.getElementById('filter-ip').value = btn.dataset.ip || '';
        document.getElementById('filter-method').value = btn.dataset.method || '';
        document.getElementById('filter-status').value = btn.dataset.status || '';
        document.getElementById('filter-ua-cat').value = '';
        state.logsPage = 1;
        switchSubtab('tab-rawlogs');
        renderFilteredRawLogs();
      });

      ['filter-path', 'filter-ip', 'filter-method', 'filter-status', 'filter-ua-cat'].forEach(id => {
        const el = document.getElementById(id);
        if (el) {
          el.addEventListener('input', () => {
            state.logsPage = 1;
            renderFilteredRawLogs();
          });
          el.addEventListener('change', () => {
            state.logsPage = 1;
            renderFilteredRawLogs();
          });
        }
      });

      document.getElementById('btn-clear-log-filters')?.addEventListener('click', () => {
        document.getElementById('filter-path').value = '';
        document.getElementById('filter-ip').value = '';
        document.getElementById('filter-method').value = '';
        document.getElementById('filter-status').value = '';
        document.getElementById('filter-ua-cat').value = '';
        state.logsPage = 1;
        renderFilteredRawLogs();
      });

      document.getElementById('btn-logs-prev')?.addEventListener('click', () => {
        if (state.logsPage > 1) {
          state.logsPage--;
          renderFilteredRawLogs();
        }
      });

      document.getElementById('btn-logs-next')?.addEventListener('click', () => {
        state.logsPage++;
        renderFilteredRawLogs();
      });
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    setupSharedNavigation();
    setupPageInteractions();
    renderCurrentPage();
  });
})();
