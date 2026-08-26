// capture.js — screenshots of the Argo CD UI for the book.
//
//   ARGOCD_PASSWORD=… node capture.js <https-base> <out-dir> <app> [step ...]
//
// Steps:
//   login                 the login page, filled in (then signs in)
//   apps[:suffix]         the Applications list (apps:after-delete → 02-applications-after-delete.png)
//   app                   the Application tree view
//   app:<suffix>          same, saved as app-<suffix>.png (e.g. app:syncing, app:healthy)
//   sync-panel            the Sync panel opened over the tree
//   res:<kind>/<name>[:<tab>][:<suffix>]   a resource's sliding panel (tab: summary|logs|events|manifest)
//   logs:<job>[:<suffix>] the Logs tab of a hook Job, scrolled to the end
//   settings-repos        Settings → Repositories (connection status)
//   settings-projects     Settings → Projects
//   delete-dialog         the Delete dialog over the Application (cancelled)
//   delete-confirm        types the Application name into the Delete dialog and confirms (Foreground) — really deletes it
//   details-sources       Details → Sources (multi-source app: the Helm values / parameter overrides live here)
//   details-sources:<sfx> same, saved as details-sources-<sfx>.png
//
// WHY THIS LIVES WITH THE BOOK: the screenshots ARE the guide. The thing that
// produces them is versioned next to it so the next person can refresh them.
//
// SECRETS: the Argo CD UI renders manifests, and a hook Job's environment can
// show an API key. Every frame is scrubbed in the DOM before the shutter — any
// text matching a registered secret is replaced, and password-ish key/value
// pairs are masked by pattern. Pass secrets via SHOT_SECRETS (newline separated).
//
// REQUIRES puppeteer (not vendored): NODE_PATH=$(npm root -g) node capture.js …
if (!process.env.NODE_PATH) {
  try { require.resolve('puppeteer'); }
  catch { console.error('puppeteer not resolvable — set NODE_PATH=$(npm root -g)'); process.exit(2); }
}
const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

const [, , base0, outDir, app, ...steps] = process.argv;
const base = (base0 || '').replace(/\/$/, '');
const ns = process.env.ARGOCD_NS || 'argocd';
const user = process.env.ARGOCD_USERNAME || 'admin';
const pass = process.env.ARGOCD_PASSWORD || '';
if (!base || !outDir || !app || !pass) {
  console.error('usage: ARGOCD_PASSWORD=… node capture.js <https-base> <out-dir> <app> [step ...]');
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });
const SECRETS = (process.env.SHOT_SECRETS || '').split('\n').map(s => s.trim()).filter(s => s.length > 7);
if (pass.length > 7) SECRETS.push(pass);
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const browser = await puppeteer.launch({
    headless: 'new', acceptInsecureCerts: true,
    executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || undefined,
    args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--ignore-certificate-errors',
           '--disable-features=HttpsUpgrades,HttpsFirstBalancedMode,HttpsFirstModeV2'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1600, height: 1000, deviceScaleFactor: 2 });

  const scrub = async () => {
    await page.evaluate((secrets) => {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
      for (const n of nodes) {
        let t = n.nodeValue; if (!t) continue;
        for (const s of secrets) if (s && t.includes(s)) t = t.split(s).join('••••••••');
        t = t.replace(/((?:api[_-]?key|password|passwd|secret|token|sshPrivateKey)\S*\s*[:=]\s*)(["']?)([^\s"',]{8,})/gi, '$1$2••••••••');
        if (t !== n.nodeValue) n.nodeValue = t;
      }
      document.querySelectorAll('input[type=password]').forEach(i => { i.value = '••••••••••••'; });
    }, SECRETS);
  };
  const shot = async (name) => {
    await sleep(600);
    await scrub();
    const file = path.join(outDir, `${name}.png`);
    await page.screenshot({ path: file, fullPage: false });
    console.log(`captured ${file}`);
  };
  const clickText = async (tag, text) => {
    const ok = await page.evaluate((tag, text) => {
      const el = Array.from(document.querySelectorAll(tag)).find(e => (e.textContent || '').trim().toLowerCase().startsWith(text.toLowerCase()));
      if (el) { el.click(); return true; } return false;
    }, tag, text);
    if (!ok) console.error(`  (no <${tag}> with text "${text}")`);
    return ok;
  };
  const goto = async (url, wait = 2500) => { await page.goto(url, { waitUntil: 'networkidle2', timeout: 60000 }).catch(() => {}); await sleep(wait); };
  const appUrl = (q = '') => `${base}/applications/${ns}/${app}?view=tree${q}`;

  let loggedIn = false;
  const login = async (capture) => {
    await goto(`${base}/login`, 1500);
    await page.waitForSelector('input[name=username]', { timeout: 30000 });
    // Argo CD's login inputs are React-controlled: click, then type through the keyboard.
    await page.click('input[name=username]'); await page.keyboard.type(user);
    await page.click('input[name=password]'); await page.keyboard.type('x'.repeat(12));   // the screenshot shows a filled form, never the real password
    if (capture) await shot('01-login');
    // clear the placeholder password (triple-click does not select all in a password field)
    await page.click('input[name=password]'); await page.keyboard.down('Control'); await page.keyboard.press('a'); await page.keyboard.up('Control'); await page.keyboard.press('Backspace');
    await page.keyboard.type(pass);
    await page.evaluate(() => { const b = Array.from(document.querySelectorAll('button')).find(x => /sign in/i.test(x.textContent || '')); if (b) b.click(); });
    await page.waitForFunction(() => !location.pathname.startsWith('/login'), { timeout: 60000 }).catch(() => {});
    await sleep(2500); loggedIn = true;
  };
  const ensureLogin = async () => { if (!loggedIn) await login(false); };

  for (const step of steps) {
    const [kind, ...rest] = step.split(':');
    try {
      if (kind === 'login') { await login(true); continue; }
      await ensureLogin();
      if (kind === 'apps') { await goto(`${base}/applications`); await shot(rest[0] ? `02-applications-${rest[0]}` : '02-applications'); }
      else if (kind === 'app') { await goto(appUrl()); await shot(rest[0] ? `app-${rest[0]}` : '03-app'); }
      else if (kind === 'sync-panel') {
        await goto(appUrl());
        await clickText('button', 'sync'); await sleep(1500);
        await shot('04-sync-panel');
        await page.keyboard.press('Escape');
      }
      else if (kind === 'res') {
        const [kn, tab = 'summary', suffix] = rest;
        const [k, n] = kn.split('/');
        const group = k === 'Job' ? 'batch' : (k === 'ConfigMap' || k === 'PersistentVolumeClaim' || k === 'Secret' || k === 'ServiceAccount') ? '' : '';
        const appNs = process.env.APP_NS || `bnk-${app.replace(/^bnk-/, '')}`;
        await goto(appUrl(`&node=${encodeURIComponent(`${group}/${k}/${appNs}/${n}/0`)}&tab=${tab}`), 3500);
        await shot(`res-${n}-${tab}${suffix ? '-' + suffix : ''}`);
      }
      else if (kind === 'logs') {
        const [job, suffix] = rest;
        const appNs = process.env.APP_NS || `bnk-${app.replace(/^bnk-/, '')}`;
        await goto(appUrl(`&node=${encodeURIComponent(`batch/Job/${appNs}/${job}/0`)}&tab=logs`), 4000);
        // scroll the log viewer to its end
        await page.evaluate(() => { document.querySelectorAll('.log-viewer, .pod-logs-viewer, pre, [class*="log"]').forEach(el => { el.scrollTop = el.scrollHeight; }); });
        await sleep(800);
        await shot(`logs-${job}${suffix ? '-' + suffix : ''}`);
      }
      else if (kind === 'settings-repos') { await goto(`${base}/settings/repos`); await shot('settings-repositories'); }
      else if (kind === 'settings-projects') { await goto(`${base}/settings/projects`); await shot('settings-projects'); }
      else if (kind === 'details-sources' || kind === 'details-params') {
        await goto(appUrl());
        await clickText('button', 'details'); await sleep(1500);
        // the sliding panel's tabs are anchors/spans; find "Parameters" by text
        // the panel's tab strip: match the tab by (case-insensitive) text, prefer the smallest element
        await page.evaluate(() => {
          const cands = Array.from(document.querySelectorAll('.tabs__nav a, .tabs__nav span, [class*="tab"] a, [class*="tab"] span, a, span, div, li'))
            .filter(e => /^(sources|parameters)$/i.test((e.textContent || '').trim()));
          cands.sort((a, b) => a.textContent.length - b.textContent.length || (a.getBoundingClientRect().width - b.getBoundingClientRect().width));
          if (cands[0]) cands[0].click();
        });
        await sleep(2500);
        // expand the first (chart) source so its Helm parameters are visible
        await page.evaluate(() => {
          // "Source 1: <repo>" header row → its expand chevron
          const hdr = Array.from(document.querySelectorAll('div,span,a')).filter(e => /^Source 1:/.test((e.textContent || '').trim()) && e.children.length <= 3).sort((a, b) => a.textContent.length - b.textContent.length)[0];
          const chev = hdr && hdr.parentElement && hdr.parentElement.querySelector('i[class*="chevron"], i[class*="angle"], [class*="expand"]');
          (chev || hdr) && (chev || hdr).click();
        });
        await sleep(2000);
        await shot(rest[0] ? `details-sources-${rest[0]}` : 'details-sources');
        await page.keyboard.press('Escape');
      }
      else if (kind === 'delete-confirm') {
        await goto(appUrl());
        await clickText('button', 'delete'); await sleep(1500);
        const input = await page.$('.modal input[type=text], .argo-modal input, div[class*="modal"] input[type=text], input[qe-id*="delete"], input');
        if (input) { await input.click(); await page.keyboard.type(app); }
        await sleep(600);
        await shot('delete-confirm');
        await page.evaluate(() => { const b = Array.from(document.querySelectorAll('button')).find(x => /^\s*ok\s*$/i.test(x.textContent || '')); if (b) b.click(); });
        await sleep(3000);
        await shot('delete-deleting');
      }
      else if (kind === 'delete-dialog') {
        await goto(appUrl());
        await clickText('button', 'delete'); await sleep(1500);
        await shot('delete-dialog');
        await page.keyboard.press('Escape');
      }
      else console.error(`unknown step ${step}`);
    } catch (e) { console.error(`step ${step} failed: ${e.message}`); }
  }
  await browser.close();
})();
