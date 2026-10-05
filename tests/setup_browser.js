// Percorre o assistente "Ativar equipamento" num Chromium real. Uso: T_SOCK=... HS_FILE=... node tests/setup_browser.js URL USUARIO SENHA
// Sai com 0 se tudo ok, 1 se alguma checagem falhar, 2 se o Playwright/Chromium não existir.
const fs = require('fs');
const { execFileSync } = require('child_process');
let chromium;
try { ({ chromium } = require(process.env.PW_MODULE || '/opt/node-tools/node_modules/playwright')); } catch (e) { console.log('SEM-PLAYWRIGHT'); process.exit(2); }
const [base, user, pass] = process.argv.slice(2);
const crypto = require('crypto');
let fails = 0;
const check = (d, c) => { console.log((c ? 'OK ' : 'FALHA ') + d); if (!c) fails++; };
const sql = (q) => execFileSync('mariadb', ['-S', process.env.T_SOCK, 'radius', '-e', q]);

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium', args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('dialog', (d) => d.accept());
  const body = async () => (await page.locator('main').innerText());

  await page.goto(base + '/login.php');
  await page.fill('input[name=user]', user);
  await page.fill('input[name=pass]', pass);
  await Promise.all([page.waitForNavigation(), page.click('form button')]);

  await page.goto(base + '/setup.php');
  await page.fill('input[name=name]', 'BR1');
  await Promise.all([page.waitForNavigation(), page.click('button:has-text("Começar")')]);
  check('etapa 1 aberta', (await body()).includes('1. Túnel: chave do roteador'));
  check('barra de etapas mostra 6 etapas', (await page.locator('ol.steps li').count()) === 6);
  check('botão Copiar presente na etapa 1', (await page.locator('.copybtn').count()) >= 1);
  const key = crypto.randomBytes(32).toString('base64');
  await page.fill('input[name=pubkey]', key);
  await Promise.all([page.waitForNavigation(), page.click('button:has-text("Adicionar ao túnel")')]);
  check('etapa 2: ainda sem conexão', (await body()).includes('ainda sem conexão'));
  check('etapa 2: sem botão Continuar', (await page.locator('a:has-text("Continuar")').count()) === 0);
  await page.locator('.copybtn').first().click();
  let label = '';
  try { await page.waitForFunction(() => document.querySelector('.copybtn').textContent === 'Copiado!', null, { timeout: 3000 }); label = 'Copiado!'; } catch (e) { label = await page.locator('.copybtn').first().textContent(); }
  check('Copiar mostra "Copiado!"', label === 'Copiado!');
  // interface recriada no roteador: a chave muda e o painel troca mantendo o IP
  await Promise.all([page.waitForNavigation(), page.click('a:has-text("Trocar a chave (etapa 1)")')]);
  check('etapa 1 com peer: formulário de trocar a chave', (await page.locator('button:has-text("Trocar a chave")').count()) === 1);
  const key2 = crypto.randomBytes(32).toString('base64');
  await page.fill('input[name=pubkey]', key2);
  await Promise.all([page.waitForNavigation(), page.click('button:has-text("Trocar a chave")')]);
  check('trocar a chave: volta à etapa 2', (await body()).includes('2. Túnel: ligar o roteador ao servidor') && (await body()).includes('Chave trocada'));
  fs.writeFileSync(process.env.HS_FILE, key2 + '\t' + Math.floor(Date.now() / 1000) + '\n');
  await Promise.all([page.waitForNavigation(), page.click('a:has-text("Verificar de novo")')]);
  check('etapa 2: conectado', (await body()).includes('conectado'));
  await Promise.all([page.waitForNavigation(), page.click('a:has-text("Continuar")')]);
  check('etapa 3 aberta', (await body()).includes('3. Cadastrar o equipamento'));
  await Promise.all([page.waitForNavigation(), page.click('button:has-text("Cadastrar")')]);
  check('etapa 4 aberta', (await body()).includes('4. Aplicar no servidor'));
  await Promise.all([page.waitForNavigation(), page.click('button:has-text("Aplicar")')]);
  check('etapa 4: feito após aplicar', (await body()).includes('feito'));
  await Promise.all([page.waitForNavigation(), page.click('a:has-text("Continuar")')]);
  check('etapa 5: script do RADIUS copiável', (await page.locator('pre[data-copy]').count()) === 1 && (await page.locator('pre').innerText()).includes('/radius add'));
  await Promise.all([page.waitForNavigation(), page.click('a:has-text("Já colei")')]);
  const text6 = await body();
  check('etapa 6: aguardando', text6.includes('aguardando'));
  const m = text6.match(/IP (10\.99\.0\.\d+)/);
  check('etapa 6: mostra o IP do túnel', !!m);
  sql("INSERT INTO radacct (acctsessionid, acctuniqueid, username, nasipaddress, acctstarttime, acctupdatetime) VALUES ('b1','u-browser','teste','" + (m ? m[1] : '0.0.0.0') + "',NOW(),NOW())");
  await Promise.all([page.waitForNavigation(), page.click('a:has-text("Verificar de novo")')]);
  check('etapa 6: equipamento ativo', (await body()).includes('equipamento ativo'));
  // apagar e começar do zero (o diálogo de confirmação é aceito)
  await page.goto(base + '/setup.php');
  const row = page.locator('tr', { hasText: 'BR1' });
  check('lista tem o BR1 com o botão Apagar', (await row.locator('button:has-text("Apagar e começar do zero")').count()) === 1);
  await Promise.all([page.waitForNavigation(), row.locator('button:has-text("Apagar e começar do zero")').click()]);
  check('mensagem de apagado', (await body()).includes('BR1 apagado'));
  check('BR1 sumiu da lista', (await page.locator('tr', { hasText: 'BR1' }).count()) === 0);
  check('sem erro de CSP nem de JavaScript', errors.length === 0);
  if (errors.length) console.log(errors.join('\n'));
  await browser.close();
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.log('FALHA exceção: ' + e.message); process.exit(1); });
