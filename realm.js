/* realm.js — the shared Core⇄Sandbox realm shell for every Sasayaki page.
 *
 * One <script src="/realm.js"> + one <div id="realmnav"></div> per page gives that page:
 *   - a Core/Sandbox dropdown that folds in the old standalone SANDBOX button,
 *   - the standard nav (LIBRARY WIKI IMPORT INTEL DEBUG) in the same place everywhere,
 *   - hrefs that carry the current realm so you stay in-realm as you move around,
 *   - a whole-page accent swap (rose #e4405f core -> cyan #22d3ee sandbox) via one CSS var override,
 *   - window.SASA_REALM + window.realmUrl(path) for the page's own data fetches.
 *
 * Realm resolution: ?realm=sandbox on the URL wins and is remembered; absent, localStorage decides;
 * default is core. Switching realm keeps you on the SAME path (only the logo points at the realm home).
 */
(function () {
  var url = new URL(location.href);
  var param = url.searchParams.get('realm');
  var realm;
  if (location.pathname.replace(/\/$/, '') === '/sandbox') {
    realm = 'sandbox';   // the sandbox overview is inherently sandbox — force it regardless of param/storage
    try { localStorage.setItem('sasa_realm', realm); } catch (e) {}
  } else if (param === 'sandbox' || param === 'core') {
    realm = param;
    try { localStorage.setItem('sasa_realm', realm); } catch (e) {}
  } else {
    try { realm = localStorage.getItem('sasa_realm') === 'sandbox' ? 'sandbox' : 'core'; } catch (e) { realm = 'core'; }
  }
  var SANDBOX = realm === 'sandbox';

  document.documentElement.dataset.realm = realm;
  window.SASA_REALM = realm;

  // --- theme (light / dark) --------------------------------------------------------------------
  // Set BEFORE the style injection below (this is a synchronous head script) so there's no flash.
  // Default = dark (no attribute). realm.js overrides only ACCENT tokens for sandbox, and the light
  // block below overrides only NEUTRAL tokens — disjoint sets, so realm + theme compose cleanly.
  var theme = 'dark';
  try { if (localStorage.getItem('sasa_theme') === 'light') theme = 'light'; } catch (e) {}
  if (theme === 'light') document.documentElement.dataset.theme = 'light';
  window.SASA_THEME = theme;

  // --- nav layout (topbar / sidebar) ------------------------------------------------------------
  // Read synchronously (same as theme) so the rail/topbar is decided before first paint — no flash.
  // Mirrored from settings.json into localStorage by settings.html; default = topbar.
  var nav = 'topbar';
  try { if (localStorage.getItem('sasa_nav') === 'sidebar') nav = 'sidebar'; } catch (e) {}
  document.documentElement.dataset.nav = nav;
  window.SASA_NAV = nav;
  window.setNav = function (m) {
    nav = (m === 'sidebar') ? 'sidebar' : 'topbar';
    window.SASA_NAV = nav;
    document.documentElement.dataset.nav = nav;
    try { localStorage.setItem('sasa_nav', nav); } catch (e) {}
    build(); fixHome();   // re-render into the rail or the inline strip (both fns hoisted below)
  };

  window.setTheme = function (t) {
    theme = (t === 'light') ? 'light' : 'dark';
    window.SASA_THEME = theme;
    if (theme === 'light') document.documentElement.dataset.theme = 'light';
    else document.documentElement.removeAttribute('data-theme');
    try { localStorage.setItem('sasa_theme', theme); } catch (e) {}
    document.querySelectorAll('.theme-tgl').forEach(function (b) { b.textContent = theme === 'light' ? '☾' : '☀'; });
  };
  window.toggleTheme = function () { window.setTheme(theme === 'light' ? 'dark' : 'light'); };

  // realmUrl(path): carry the realm on a link/fetch. Core adds nothing (clean URLs); sandbox appends ?realm.
  window.realmUrl = function (path) {
    if (!SANDBOX) return path;
    var u = new URL(path, location.origin);
    u.searchParams.set('realm', 'sandbox');
    return u.pathname + u.search + u.hash;
  };

  // --- palette swap: one override of the accent trio, scoped to the sandbox realm ---------------
  // Every page themes off --pk/--pk2/--pk3, so this single rule recolors the entire UI. Higher
  // specificity than :root and injected late, so it wins the cascade without touching any page CSS.
  var style = document.createElement('style');
  style.textContent =
    // The accent token is --pk on the static HTML pages but --cyan/--pink on the PS-generated
    // dashboard/debug/intel pages (68 uses of --cyan there, all = rose #e4405f). Override both
    // families so the whole app recolors regardless of which page you're on. (--teal is left
    // alone — it's a real distinct teal on the library page, only rose-ish on the dashboard.)
    'html[data-realm="sandbox"]{--pk:#22d3ee;--pk2:#67e8f9;--pk3:rgba(34,211,238,.14);' +
      '--cyan:#22d3ee;--pink:#67e8f9;--coral:#0aa5c4}' +
    // --- theme tokens -------------------------------------------------------------------------
    // Alpha tokens: the sweep replaces hardcoded rgba(255,255,255,*) hover-fills/borders with these
    // so they flip to black-alpha in light mode. Declared here (injected last) so every page gets them.
    ':root{--a04:rgba(255,255,255,.04);--a08:rgba(255,255,255,.08);--a12:rgba(255,255,255,.12);--a18:rgba(255,255,255,.18)}' +
    // Light neutrals — override BOTH token families (--surf* on static pages, --surface* on wiki/PS).
    // html[data-theme=light] (0,1,1) beats :root (0,1,0), so this wins; accents are untouched here.
    'html[data-theme="light"]{--bg:#f5f3ef;--surf:#ffffff;--surf2:#eceae4;--surface:#ffffff;--surface2:#eceae4;' +
      '--line:rgba(0,0,0,.09);--line2:rgba(0,0,0,.15);--txt:#1e1f20;--muted:#6b655f;--dim:#a49d95;' +
      '--a04:rgba(0,0,0,.035);--a08:rgba(0,0,0,.06);--a12:rgba(0,0,0,.09);--a18:rgba(0,0,0,.14)}' +
    // Light accent tweaks (must follow the sandbox rule so the cyan variant wins in sandbox+light):
    // the subtle --pk3 wash is near-invisible on white, so deepen it a touch per realm.
    'html[data-theme="light"]{--pk3:rgba(228,64,95,.10)}' +
    'html[data-theme="light"][data-realm="sandbox"]{--pk3:rgba(34,211,238,.16)}' +
    /* nav chrome, themes automatically via var(--pk) */
    '#realmnav{display:flex;align-items:center;gap:5px;flex:1 1 auto;min-width:0;overflow-x:auto;overflow-y:hidden;scrollbar-width:none}' +
    '#realmnav::-webkit-scrollbar{height:0}' +
    '#realmnav>*{flex:none}' +
    // realm switcher: a one-click sliding 2-state toggle (thumb slides left=Core / right=Sandbox).
    // The glowing thumb is the active realm; clicking the other side slides it and switches.
    '.realm-tgl{position:relative;display:grid;grid-template-columns:1fr 1fr;align-items:stretch;' +
      'background:var(--pk3);border:1px solid var(--pk);border-radius:8px;cursor:pointer;user-select:none;' +
      'overflow:hidden;line-height:0}' +
    '.realm-tgl .rthumb{position:absolute;top:0;bottom:0;left:0;width:50%;background:var(--pk);' +
      'box-shadow:0 0 10px var(--pk);transition:transform .28s cubic-bezier(.16,1,.3,1);z-index:0}' +
    '.realm-tgl[data-realm="sandbox"] .rthumb{transform:translateX(100%)}' +
    '.realm-tgl .rt-opt{position:relative;z-index:1;appearance:none;-webkit-appearance:none;background:transparent;' +
      'border:none;cursor:pointer;font:600 11px/1 ui-monospace,Menlo,Consolas,monospace;letter-spacing:.03em;' +
      'padding:7px 13px;color:var(--pk);transition:color .2s}' +
    '.realm-tgl .rt-opt.on{color:#fff}' +
    '@media (prefers-reduced-motion:reduce){.realm-tgl .rthumb{transition:none}}' +
    '#realmnav a{font:12px ui-monospace,Menlo,Consolas,monospace;padding:6px 9px;border-radius:8px;' +
      'color:var(--muted,#9aa);text-decoration:none;transition:color .15s,background .15s,transform .12s ease-out;' +
      'white-space:nowrap;position:relative;will-change:transform;transform-origin:50% 100%}' +
    '#realmnav a:hover{color:var(--txt,#fff);background:var(--a08)}' +
    '#realmnav a.on{color:#fff;background:var(--pk)}' +   /* on-accent text stays white in both themes */
    '.theme-tgl{border:1px solid var(--line2);background:transparent;color:var(--muted);cursor:pointer;' +
      'width:30px;height:30px;border-radius:8px;font-size:15px;line-height:1;display:inline-flex;' +
      'align-items:center;justify-content:center;transition:color .15s,background .15s,border-color .15s}' +
    '.theme-tgl:hover{color:var(--txt);border-color:var(--muted);background:var(--a08)}' +
    // --- sidebar (left-rail) layout — realm.js-owned, zero per-page HTML edits ------------------
    // In sidebar mode realm.js builds #sasa-rail (fixed, full height) and renders the nav into it;
    // each page's own top bar stays put (logo + page tools) and is shifted right by the body pad,
    // so nothing per-page needs to change. Tokens fall back across the static (--surf) and
    // PS-generated (--surface) families so the rail themes correctly on every page.
    '#sasa-rail{display:none}' +
    'html[data-nav="sidebar"] body{padding-left:210px}' +
    'html[data-nav="sidebar"] #sasa-rail{position:fixed;left:0;top:0;bottom:0;width:210px;z-index:60;' +
      'display:flex;flex-direction:column;gap:4px;padding:16px 12px;box-sizing:border-box;overflow-y:auto;' +
      'background:var(--surf,var(--surface,#14110f));border-right:1px solid var(--line,var(--a12))}' +
    '#sasa-rail .rail-head{font:600 12px/1 ui-monospace,Menlo,Consolas,monospace;letter-spacing:.14em;' +
      'color:var(--pk);padding:2px 8px 12px;text-transform:none}' +
    '#sasa-rail .realm-tgl{width:100%;margin-bottom:6px}' +
    '#sasa-rail .realm-tgl .rt-opt{padding:8px 13px}' +
    '#sasa-rail a{display:flex;align-items:center;font:12px ui-monospace,Menlo,Consolas,monospace;' +
      'padding:9px 11px;border-radius:8px;color:var(--muted,#9aa);text-decoration:none;white-space:nowrap;' +
      'letter-spacing:.02em;transition:color .15s,background .15s}' +
    '#sasa-rail a:hover{color:var(--txt,#fff);background:var(--a08)}' +
    '#sasa-rail a.on{color:#fff;background:var(--pk)}' +
    '#sasa-rail .rail-spacer{flex:1 1 auto;min-height:10px}' +
    '#sasa-rail .theme-tgl{align-self:flex-start}' +
    // mobile: the rail folds back into a horizontal top strip (no fixed gutter eating the screen)
    '@media (max-width:720px){' +
      'html[data-nav="sidebar"] body{padding-left:0}' +
      'html[data-nav="sidebar"] #sasa-rail{position:sticky;top:0;left:auto;bottom:auto;width:auto;' +
        'flex-direction:row;align-items:center;gap:5px;padding:8px 12px;overflow-x:auto;overflow-y:hidden;' +
        'border-right:none;border-bottom:1px solid var(--line,var(--a12))}' +
      '#sasa-rail .rail-head{padding:2px 8px 2px 0}' +
      '#sasa-rail .rail-spacer{display:none}' +
      '#sasa-rail a{flex:none}' +
      '#sasa-rail .realm-tgl{width:auto;margin-bottom:0}}';
  document.head.appendChild(style);

  // --- the standard nav ------------------------------------------------------------------------
  var BTNS = [
    { label: 'HOME',      path: '/home' },
    { label: 'LIBRARY',   path: '/library' },
    { label: 'DISCOVER',  path: '/discover' },
    { label: 'WIKI',      path: '/wiki' },
    { label: 'CHAT',      path: '/ai-chat' },
    { label: 'IMPORT',    path: '/import' },
    { label: 'DASHBOARD', path: '/' },
    { label: 'INTEL',     path: '/metrics' },
    { label: 'DEBUG',     path: '/debug' },
    { label: 'SETTINGS',  path: '/settings' }
  ];
  var here = location.pathname.replace(/\/$/, '') || '/';

  function build() {
    var inline = document.getElementById('realmnav');
    var sidebar = document.documentElement.dataset.nav === 'sidebar';
    // theme toggle opt-in is declared on the inline #realmnav (data-theme-host); honor it in either mode.
    var themeHost = inline && inline.hasAttribute('data-theme-host');
    var rail = document.getElementById('sasa-rail');
    var host;
    if (sidebar) {
      if (inline) inline.innerHTML = '';            // vacate the inline strip — nav lives in the rail
      if (!rail) { rail = document.createElement('nav'); rail.id = 'sasa-rail'; rail.setAttribute('aria-label', 'primary'); document.body.appendChild(rail); }
      host = rail; host.innerHTML = '';
      var hd = document.createElement('div'); hd.className = 'rail-head'; hd.textContent = '囁き'; host.appendChild(hd);
    } else {
      if (rail) rail.remove();                       // switched back to topbar — drop the rail
      if (!inline) return;
      host = inline; host.innerHTML = '';
    }

    var tgl = document.createElement('div');
    tgl.className = 'realm-tgl';
    tgl.setAttribute('data-realm', realm);
    tgl.title = 'switch realm';
    var thumb = document.createElement('span'); thumb.className = 'rthumb'; tgl.appendChild(thumb);
    [['core', 'Core'], ['sandbox', 'Sandbox']].forEach(function (o) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'rt-opt' + (o[0] === realm ? ' on' : '');
      b.setAttribute('data-r', o[0]);
      b.textContent = o[1];
      b.addEventListener('click', function () { if (o[0] !== realm) switchRealm(o[0]); });
      tgl.appendChild(b);
    });
    host.appendChild(tgl);

    BTNS.forEach(function (b) {
      var a = document.createElement('a');
      a.href = window.realmUrl(b.path);
      a.textContent = b.label;
      if (here === b.path || here.indexOf(b.path + '/') === 0) a.className = 'on';
      host.appendChild(a);
    });

    // theme toggle — only on pages that opt in via data-theme-host (the 6 web pages; NOT the
    // PS-generated dashboard/debug/intel, which stay dark until their own reskin). In the rail it
    // sits at the bottom, pushed down by a flex spacer.
    if (themeHost) {
      if (sidebar) { var sp = document.createElement('div'); sp.className = 'rail-spacer'; host.appendChild(sp); }
      var tg = document.createElement('button');
      tg.className = 'theme-tgl';
      tg.title = 'light / dark';
      tg.textContent = window.SASA_THEME === 'light' ? '☾' : '☀';
      tg.addEventListener('click', function () { window.toggleTheme(); });
      host.appendChild(tg);
    }
    if (!sidebar) initDock(host);                    // dock magnify is a horizontal-row effect only
  }

  // --- dock magnification (macOS-dock style, magicui.design/docs/components/dock ported to ---
  // vanilla): nav buttons scale up as the cursor nears and settle back as it leaves. The CSS
  // transition on transform (.12s ease-out) smooths the per-mousemove target updates into a
  // spring-ish glide. Hover-capable pointers only (phones keep static buttons), and skipped
  // entirely under prefers-reduced-motion. transform-origin is 50% 100% (set in the injected
  // CSS above), so the horizontal center never shifts under scale — getBoundingClientRect's
  // center X stays stable and the distance math needs no untransformed-layout bookkeeping.
  function initDock(host) {
    try {
      if (!matchMedia('(hover: hover) and (pointer: fine)').matches) return;
      if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    } catch (e) { return; }
    var MAG = 1.3, DIST = 110;    // peak scale; px falloff radius (magicui: magnification/distance)
    var links = host.querySelectorAll('a');
    host.addEventListener('mousemove', function (e) {
      for (var i = 0; i < links.length; i++) {
        var r = links[i].getBoundingClientRect();
        var d = Math.abs(e.clientX - (r.left + r.width / 2));
        var f = d >= DIST ? 0 : Math.cos((d / DIST) * Math.PI / 2);   // smooth cosine falloff
        var s = 1 + (MAG - 1) * f;
        links[i].style.transform = s > 1.005 ? 'scale(' + s.toFixed(3) + ')' : '';
        links[i].style.zIndex = s > 1.1 ? '2' : '';
      }
    });
    host.addEventListener('mouseleave', function () {
      for (var i = 0; i < links.length; i++) { links[i].style.transform = ''; links[i].style.zIndex = ''; }
    });
  }

  function switchRealm(next) {
    try { localStorage.setItem('sasa_realm', next); } catch (e) {}
    var u = new URL(location.href);
    if (next === 'sandbox') u.searchParams.set('realm', 'sandbox');
    else u.searchParams.delete('realm');
    location.href = u.pathname + u.search + u.hash;
  }

  // realm-aware logo/home: core -> landing page "/home", sandbox -> "/sandbox" pipeline overview.
  // (The live dashboard "/" is now reachable via the DASHBOARD nav button, not the logo.)
  // Any element marked data-realm-home gets its href retargeted.
  function fixHome() {
    var homes = document.querySelectorAll('[data-realm-home]');
    for (var i = 0; i < homes.length; i++) homes[i].setAttribute('href', SANDBOX ? '/sandbox' : '/home');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { build(); fixHome(); });
  } else { build(); fixHome(); }
})();
