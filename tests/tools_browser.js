// Teste do gerador de segredo e do botão "Baixar .rsc" (tools.php) num Chromium real.
// Uso: node tests/tools_browser.js URL USUARIO SENHA   (sai com 2 se não houver Playwright)
let chromium;
try { ({ chromium } = require(process.env.PW_MODULE || '/opt/node-tools/node_modules/playwright')); } catch (e) { console.log('SEM-PLAYWRIGHT'); process.exit(2); }
const [base, user, pass] = process.argv.slice(2);
let fails = 0;
const check = (d, c) => { console.log((c ? 'OK ' : 'FALHA ') + d); if (!c) fails++; };
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium' });
  const page = await (await browser.newContext({ acceptDownloads: true })).newPage();
  const problems = [];
  page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) problems.push(m.text()); });
  page.on('pageerror', (e) => problems.push('pageerror: ' + e.message));
  await page.goto(base + '/login.php');
  await page.fill('input[name=user]', user);
  await page.fill('input[name=pass]', pass);
  await Promise.all([page.waitForNavigation(), page.click('form button')]);
  await page.goto(base + '/tools.php');
  await page.click('button[data-gensecret]');
  const s1 = await page.inputValue('#mt-secret');
  await page.click('button[data-gensecret]');
  const s2 = await page.inputValue('#mt-secret');
  check('segredo com 32 caracteres do alfabeto permitido', /^[A-Za-z0-9._-]{32}$/.test(s1));
  check('segredos diferentes a cada clique', s1 !== s2);
  await page.fill('input[name=server_ip]', '10.99.0.1');
  await page.fill('input[name=name]', 'loja-x');
  await Promise.all([page.waitForNavigation(), page.click('button:text-is("Gerar script")')]);
  check('script gerado e botão Baixar visível', (await page.locator('button[data-download]').count()) === 1);
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('button[data-download]')]);
  check('arquivo se chama radpanel-loja-x.rsc', dl.suggestedFilename() === 'radpanel-loja-x.rsc');
  const txt = require('fs').readFileSync(await dl.path(), 'utf8');
  check('conteúdo é o script', txt.includes('/radius add service=') && txt.includes('called-id=loja-x'));
  check('sem violação de CSP nem erro de JS', problems.length === 0);
  if (problems.length) console.log(problems.join('\n'));
  await browser.close();
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.log('ERRO ' + e.message); process.exit(1); });
