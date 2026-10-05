// Teste do botão "Copiar" num Chromium real. Uso: node tests/copy_browser.js URL USUARIO SENHA
// Sai com 0 e imprime "OK ..." por checagem; sai com 2 se o Playwright/Chromium não estiver disponível.
let chromium;
try { ({ chromium } = require(process.env.PW_MODULE || '/opt/node-tools/node_modules/playwright')); } catch (e) { console.log('SEM-PLAYWRIGHT'); process.exit(2); }
const [base, user, pass] = process.argv.slice(2);
let fails = 0;
const check = (d, c) => { console.log((c ? 'OK ' : 'FALHA ') + d); if (!c) fails++; };

async function run(browser, disableClipboardApi) {
  const ctx = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
  const page = await ctx.newPage();
  const csp = [];
  page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });
  page.on('pageerror', (e) => csp.push('pageerror: ' + e.message));
  if (disableClipboardApi) await page.addInitScript(() => { Object.defineProperty(navigator, 'clipboard', { value: undefined }); });
  await page.goto(base + '/login.php');
  await page.fill('input[name=user]', user);
  await page.fill('input[name=pass]', pass);
  await Promise.all([page.waitForNavigation(), page.click('form button')]);
  await page.goto(base + '/wireguard.php');
  const tag = disableClipboardApi ? '(fallback execCommand) ' : '(navigator.clipboard) ';
  const n = await page.locator('pre[data-copy]').count();
  check(tag + 'blocos copiáveis encontrados', n >= 1);
  check(tag + 'um botão por bloco', (await page.locator('.copybtn').count()) === n);
  const pre = page.locator('pre[data-copy]').first();
  const expected = await pre.evaluate((e) => e.textContent);
  await page.locator('.copybtn').first().click();
  let label = '';
  try { await page.waitForFunction(() => document.querySelector('.copybtn').textContent === 'Copiado!', null, { timeout: 3000 }); label = 'Copiado!'; } catch (e) { label = await page.locator('.copybtn').first().textContent(); }
  check(tag + 'botão mostra "Copiado!"', label === 'Copiado!');
  // cola num campo de texto para conferir o conteúdo da área de transferência
  await page.evaluate(() => { const t = document.createElement('textarea'); t.id = 'colar'; document.body.appendChild(t); t.focus(); });
  await page.keyboard.press('Control+V');
  const got = await page.inputValue('#colar');
  check(tag + 'área de transferência = texto do bloco (' + JSON.stringify(got.slice(0, 40)) + ')', got === expected);
  check(tag + 'sem erro de CSP nem de JavaScript', csp.length === 0);
  if (csp.length) console.log(csp.join('\n'));
  await ctx.close();
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium', args: ['--no-sandbox'] });
  await run(browser, false);
  await run(browser, true);
  await browser.close();
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.log('FALHA exceção: ' + e.message); process.exit(1); });
