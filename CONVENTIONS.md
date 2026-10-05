# RadPanel — convenções para quem acrescenta funções

Raiz do projeto: `/tmp/claude-0/-home-user-freeradius-server/d2f71bf8-4747-5f02-8539-4d2ab4896955/scratchpad/radpanel`
(abaixo, `radpanel/`). PHP 8.3, `declare(strict_types=1)`, PDO/MariaDB 10.11, Apache em produção, textos da interface em português do Brasil.
O FreeRADIUS é o 4.0 (fork em `/home/user/freeradius-server`, somente leitura para você — NÃO altere nada ali).

## Regras de ouro
1. **Só crie/edite os arquivos que a sua tarefa lista.** Outros agentes trabalham em paralelo nos demais. Não edite `lib/core.php`, `lib/auth.php`, `lib/audit.php`, `lib/radius_users.php`, `lib/layout.php`, `public/style.css`, `public/app.js`, `sql/panel.sql`, `sql/grants.core.sql`, `tests/harness.sh`. Se precisar de algo novo nesses, **não edite**: descreva a necessidade no seu relatório final.
2. Toda página admin começa com:
   ```php
   require __DIR__ . '/../lib/bootstrap.php';
   require __DIR__ . '/../lib/layout.php';
   $admin = require_role('viewer'|'operator'|'admin');   // validar no servidor, também em cada POST
   ```
   Papéis: viewer < operator < admin. Escritas: `require_role('operator')` ou `'admin'` **antes** de `csrf_check()`. Ações destrutivas ou de configuração do servidor: admin.
3. **CSP estrita**: `default-src 'self'; style-src 'self'; img-src 'self'`. Proibido `style="..."`, `<style>`, `onclick=`, `<script>` inline, `javascript:` e `data:` URIs. CSS em `public/<modulo>.css` (passe em `page_header($t, $active, ['css' => ['<modulo>.css']])`), JS em `public/<modulo>.js` (`page_footer(['js' => [...]])`), ligado por atributos `data-*`. Confirmação de exclusão: `<form data-confirm="Texto?">` (já tratado em `app.js`). Gráficos: SVG gerado no servidor, sem `style` inline (use atributos de apresentação e classes do seu CSS).
4. **Escritas no RADIUS** (radcheck/radreply/radusergroup/radgroup*) passam por `lib/radius_users.php` (`ru_create`, `ru_set_check`, `ru_set_plan`, `ru_block`, `ru_delete`, `ru_tx`, `ru_plans`...). Para criar usuários em massa use `ru_create(..., audit: false)` dentro de `ru_tx` e registre UM `audit()` do lote.
5. **Auditoria**: toda ação que altera estado chama `audit('modulo.acao', 'alvo', ['detalhe' => ...])`. Nunca coloque senha/segredo/código de voucher no detalhe (`audit_scrub` mascara chaves `password`, `secret`, `code`, mas não confie nisso).
6. **Segurança**: só consultas preparadas; `h()` em toda saída; todo POST: `csrf_check()`; erros inesperados: `log_exception($e, 'modulo')` + mensagem genérica via `flash(..., 'err')`; mensagens amigáveis só em `RuntimeException`. Redirecionamentos: `redirect('pagina.php?x=y')` (só caminhos relativos). Exportações/impressões de dado sensível: respostas `no-store` (já é padrão) e acesso por papel.
7. **Formatos do FreeRADIUS 4.0**: `Password.Cleartext`, `Expiration` em RFC 3339 UTC (`expiration_from_date('Y-m-d')`), `Session-Timeout`, `Idle-Timeout`, `Acct-Interim-Interval`, `Mikrotik.Rate-Limit`. Itens de checagem de limite usam prefixo `control.` (ex.: `control.Max-Daily-Session`, `control.Max-Quota-Octets`). MAC: `Calling-Station-Id` `==` `AA-BB-CC-DD-EE-FF` (use `normalize_mac`). Data local → `expiration_from_date`; leitura: `expiration_ts`, `fmt_expiration`.
8. **Banco**: se precisar de tabela nova, crie `sql/<modulo>.sql` (idempotente: `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`) e `sql/grants.<modulo>.sql` com o mesmo formato de `sql/grants.core.sql` (`{{DB_NAME}}`, `{{DB_USER}}`, host `'localhost'`), **só o mínimo** (ex.: `panel_audit` só INSERT/SELECT). O harness carrega tudo automaticamente.
9. **Menu**: `NAV_ITEMS` em `lib/layout.php` já lista `vouchers`, `reports`, `customers`, `tools`, `admins`, `audit`, `nas`, `sessions`, `plans`, `users`. Cada uma aparece quando o arquivo `public/<chave>.php` existir; use exatamente esses nomes de arquivo.
10. Nada de dependências externas (sem Composer, sem CDN). Sem `exec`/`shell_exec` com string de shell: se precisar executar programa, `proc_open` com array de argumentos e `escapeshellarg` não é suficiente — passe argv.

## Testes (obrigatórios)
Use `tests/harness.sh` (leia o topo do arquivo): `source tests/harness.sh; env_up NOME DBPORT WEBPORT`. **Use o NOME e as portas que a sua tarefa indica** (outros agentes rodam ao mesmo tempo). Escreva `tests/test_<modulo>.sh` no modelo de `tests/test_core.sh` (use `ok`, `summary`, `t_login`, `t_post`, `t_get`, `q`; sempre `trap 'env_down NOME' EXIT`). Rode com `timeout 170 bash tests/test_<modulo>.sh > /tmp/claude-0/<modulo>.out 2>&1 < /dev/null` e leia o arquivo de saída (comandos longos ficam em segundo plano). **Nunca use `pkill -f`** (casa com o próprio shell); o harness desliga por pid. Antes de terminar, confirme que não sobrou `mariadbd`/`php -S` seu: `pgrep -a mariadbd; pgrep -af 'php -S'`.
Teste de verdade: papéis (viewer/operator/admin), CSRF ausente, entradas maliciosas (`'`, `;`, `<script>`), limites, estados vazios, e que nenhum HTML de saída tem `style=`/`onclick=`/`<script>` inline (`grep -E 'style="|onclick=|<script>[^<]'`). Lint: `php -l` em todos os seus arquivos.
O que não puder testar aqui (precisa do `radiusd`, de um NAS real, e-mail, etc.) deve ser dito com clareza no relatório como **NÃO TESTADO**, nunca como funcionando.

## Relatório final (curto, em português)
Liste: arquivos criados/editados; tabelas/grants novos; o que foi testado (contagem de PASS/FAIL e comando); o que ficou **NÃO TESTADO** e por quê; qualquer mudança necessária em arquivos que você não pode editar (ex.: `layout.php`, instalador); decisões de segurança relevantes. Não cole o código no relatório.
