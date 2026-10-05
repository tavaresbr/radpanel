# Validação das linhas SQL do painel contra um radiusd 4.0 real

Servidor: fork `/home/user/freeradius-server` (commit `a7588cf3`, "4.0.65535 DEVELOPER BUILD"), compilado neste sandbox
(Ubuntu 24.04) em `/tmp/claude-0/fr-install`; banco MariaDB 10.11 temporário do `tests/harness.sh`.
Resultado do roteiro `tests/test_radius_rows.sh`: **39 PASS / 0 FAIL com a correção do achado 1; 25 PASS / 14 FAIL com o fork como está**.

## Resumo (o que importa)

| # | Achado | Gravidade |
|---|--------|-----------|
| 1 | **O fork, como está, não consegue ler `Expiration` do SQL**: `Data read from SQL cannot be parsed.` -> `-sql (fail)` -> **Access-Reject para o usuário inteiro** (mesmo com senha certa). Afeta qualquer item `date` em `radcheck`. É bug do servidor (`value.c`), não do painel. | CRÍTICO (todo usuário criado com validade, e todo bloqueado/desbloqueado, não autentica) |
| 2 | Com o bug corrigido, o formato gravado pelo painel (`2028-01-01T02:59:59Z`) é aceito e a validade funciona (futuro = Accept, passado = Reject, bloqueio = Reject). | OK |
| 3 | `radreply` do usuário com `Session-Timeout := N` **não** vale quando o plano tem `Session-Timeout := M` em `radgroupreply`: o do plano sobrescreve. Se o painel (ou o operador) quiser limite individual, o plano deve gravar com operador `=`. | Divergência de projeto |
| 4 | `control.Max-Daily-Session`, `control.Max-Monthly-Session`, `control.Max-All-Session` e `control.Max-Quota-*-Octets` gravados em `radcheck` **derrubam o login (Reject)** se o atributo não estiver definido no servidor (`Data read from SQL cannot be parsed`). `Max-*-Session` passam a ser definidos ao habilitar `sqlcounter` (stock); `Max-Quota-*-Octets` não existem no stock: dependem do `server-config/` do painel. | Divergência/dependência |
| 5 | `Expiration` no radcheck só aceita: RFC 3339 com `Z` ou offset, `Mon DD YYYY [hh:mm:ss]` (interpretado como UTC) e inteiro Unix. **Não** aceita `2027-12-31`, `2027-12-31 23:59:59`, nem `2027-12-31T23:59:59` (sem fuso). | Informativo |

## Achado 1 — detalhe e correção

Reprodução (sem correção): painel cria `u_ok` com validade; `radclient` com senha certa dá `Access-Reject`; no log do radiusd:

```
ERROR : Data read from SQL cannot be parsed.
ERROR :     Expiration
ERROR :     :=
ERROR :     2028-01-01T02:59:59Z
-sql (fail)
The 'recv Access-Request' section returned fail - rejecting the request
```

Causa: `src/lib/util/value.c`, `fr_value_box_from_substr()`: para tipos de tamanho fixo (aqui `date`) o texto é copiado para um buffer
temporário e o `sbuff` de entrada **não avança** (há até um `@todo` dizendo isso), então a função devolve 0 mesmo com sucesso.
`map_afrom_fields()` (`src/lib/server/map.c`, ramo `bare_word_only`, usado pelo `rlm_sql` para itens de *check*) chama
`fr_value_box_from_str()` e trata `slen <= 0` como erro. Resultado: nenhum atributo `date` é lido de `radcheck`
(qualquer valor, qualquer formato, com ou sem prefixo `control.`). O `radclient` e o arquivo `users`/policies não passam por esse caminho, por isso o bug só aparece com SQL.

Correção testada (cópia em `/tmp/claude-0/fr-src`; o repositório original NÃO foi alterado). Patch em `/tmp/claude-0/fr-value-date.patch`:

```diff
--- src/lib/util/value.c
+++ src/lib/util/value.c
@@ -6119,6 +6119,13 @@ (ramo "It's a fixed size src->dst_type")
 		memcpy(buffer, fr_sbuff_current(in), fr_sbuff_remaining(in));
 		buffer[fr_sbuff_remaining(in)] = '\0';
+
+		/* consumimos toda a entrada: avisar o chamador (senão devolve 0 em sucesso para date/ifid) */
+		fr_sbuff_advance(&our_in, fr_sbuff_remaining(&our_in));
 	}
```

Com isso (só `libfreeradius-util.so` muda) tudo abaixo passa. Contorno SEM mexer no servidor: existe a opção oculta `expand_rhs = yes` no módulo `sql`
(faz o `rlm_sql` usar o ramo "entre aspas"); aí o valor no banco precisa estar **entre aspas duplas** (`"2028-01-01T02:59:59Z"`), o que o painel não grava hoje
e mudaria o formato de `Expiration`; por isso a recomendação é corrigir o servidor (a correção é de 1 linha) ou, se o servidor do usuário
for um fork próprio dele, aplicar o patch no fork.
Se a opção do usuário for não tocar no servidor: o painel teria de gravar `Expiration` entre aspas **e** o módulo `sql` precisaria de `expand_rhs = yes` (efeito colateral: passa a expandir `%{...}` em todos os valores de check).

## Resultados por item (com a correção do achado 1; saída completa em `/tmp/claude-0/fr-rows-patched.out` e `/tmp/claude-0/fr-rows-asis.out` para o fork sem correção)

(a) `Password.Cleartext := senha1234`: senha certa **Access-Accept**; errada **Access-Reject**; usuário inexistente **Access-Reject**.
Reject = `length 38`, só `Message-Authenticator`, sem `Reply-Message`.

(b) `Expiration := 2028-01-01T02:59:59Z` (o painel converte 2027-12-31 23:59:59 America/Sao_Paulo para UTC): **Accept**.
Pelo painel `expires=2020-01-01` grava `2020-01-02T02:59:59Z`: **Reject**. Formatos gravados direto no SQL (futuro / passado):
- `Dec 31 2027 23:59:59` (formato antigo): **aceito** (Accept; `Dec 31 2020 23:59:59` = Reject). Interpretado como UTC.
- `2027-12-31T23:59:59-03:00`: aceito (offset respeitado). `1893455999` (Unix): aceito.
- `2027-12-31`, `2027-12-31 23:59:59`, `2027-12-31T23:59:59` (sem fuso): **erro de parse -> Reject para todos** (mesmo futuro).
Sem a correção do achado 1 nenhum destes funciona.

(c) Bloqueio do painel = `Expiration := 2000-01-01T00:00:00Z`: **Reject**; desbloqueio restaura a validade anterior: **Accept**.

(d) Plano `basico` (10M/2M, timeout 3600, idle 300, interim 120) via `radusergroup` -> `radgroupreply`. Resposta Access-Accept real:
```
Vendor-Specific = { Mikrotik = { Rate-Limit = "2M/10M" } }
Session-Timeout = 3600
Idle-Timeout = 300
Acct-Interim-Interval = 120
```
(`Mikrotik.Rate-Limit` = `up/down` como o painel grava; o radclient imprime como `Vendor-Specific = { Mikrotik = { Rate-Limit ...` ). Usuário sem plano: nenhum desses atributos.

(e) `Session-Timeout`:
- plano 3600 + `Expiration` longe (2028): **3600**; `Expiration` em 3 h: **3600**; `Expiration` em 30 min: **1800** (a policy `expiration` faz `reply.Session-Timeout <= (Expiration - agora)`, i.e. o MENOR vale).
- usuário sem plano com `Expiration` em 30 min: **1800** (a policy define o Session-Timeout sozinha).
- `radreply` do usuário `Session-Timeout := 600` (ou `= 600`, ou `:= 99999`) com plano `:= 3600`: resposta **3600** em todos os casos (o plano sobrescreve; achado 3). O painel hoje NÃO grava `Session-Timeout` de usuário (só do plano), então não é problema atual, mas qualquer ajuste individual feito à mão em `radreply` será ignorado. Se o plano for gravado com op `=`, o do usuário prevalece (600) e sem `radreply` vale o do plano (3600) — testado.

(f) Accounting (`radclient ... acct`): Start, Interim-Update (`Acct-Input-Octets=1000`, `Output=5000`, `Session-Time=60`) e Stop (2000/9000/120, `Acct-Terminate-Cause=User-Request`)
respondem `Accounting-Response` e geram **1 linha** em `radacct` (Interim/Stop atualizam a mesma linha via `acctuniqueid`), com `framedipaddress`, `callingstationid`, `acctinputoctets`, `acctoutputoctets`, `acctstoptime`.
`sessions.php`: aba *online* mostra a sessão (usuário e IP) entre Start e Stop e não mostra depois do Stop; abas *histórico* e *consumo por usuário* mostram o usuário. 

Extra (g): `Calling-Station-Id == AA-BB-CC-DD-EE-FF` em `radcheck`: MAC igual = Accept, diferente = Reject, **ausente = Reject**.
`control.Simultaneous-Use := 1` é lido sem erro (a checagem de sessões simultâneas não foi exercitada).

## Marcado: o painel grava e o servidor NÃO entende (ou depende de algo)

1. `Expiration` (qualquer valor) — **servidor do fork não lê data do SQL** (achado 1). Correção: patch acima no servidor.
2. `control.Max-Quota-Daily-Octets`, `control.Max-Quota-Monthly-Octets`, `control.Max-Quota-Total-Octets` — **atributos inexistentes no servidor stock**
   (Access-Reject para o usuário que tiver qualquer um deles). Precisam ser declarados pelo `server-config/` do painel (dictionary/counters); não testado aqui.
3. `control.Max-Daily-Session`, `control.Max-Monthly-Session`, `control.Max-All-Session` — só existem se o módulo `sqlcounter` estiver habilitado
   (`mods-enabled/sqlcounter`, instâncias `dailycounter`, `monthlycounter`, `noresetcounter`). Sem ele, Reject. O ENFORCAMENTO dos contadores (consulta a `radacct`, `Session-Timeout` restante) NÃO foi testado: as instâncias só foram habilitadas para ver se o atributo é lido; não foram ligadas ao `recv Access-Request`.
   Sugestão: o instalador/`server-config` do painel deve habilitar `sqlcounter` e listar as instâncias no `recv Access-Request`; e antes de gravar qualquer limite o painel deveria avisar que, sem isso, o usuário **perde o login** (falha total, não só o limite).
4. `Session-Timeout`/`Idle-Timeout`... de **usuário** em `radreply` perdem para o plano `:=` (achado 3). Sugestão: gravar `radgroupreply` do plano com op `=` para esses atributos.

## Ambiente, como reproduzir

Compilação (sandbox; sem `.git` na cópia, por isso criou-se `VERSION_COMMIT`):
```
rsync -a --exclude=.git /home/user/freeradius-server/ /tmp/claude-0/fr-src/
apt install build-essential autoconf libssl-dev libtalloc-dev libpcre2-dev libmariadb-dev libcurl4-openssl-dev libreadline-dev \
  libcap-dev libjson-c-dev libpcap-dev libsqlite3-dev libgdbm-dev libhiredis-dev cmake
# libkqueue v2.6.3 (o do Ubuntu é 2.3.1): git clone --branch v2.6.3 ... ; cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu . ; make install
cd /tmp/claude-0/fr-src && git -C /home/user/freeradius-server rev-parse --short=8 HEAD | tr -d '\n' > VERSION_COMMIT
./configure --prefix=/tmp/claude-0/fr-install && make -j4 && make install        # ~2 min, log em /tmp/claude-0/fr-build.log
```
Obs.: sem `.git` e sem `VERSION_COMMIT`, o `make` falha com `build/autoconf.mk: missing separator`. Compilou radiusd, radclient, radtest, `rlm_sql`, `rlm_sql_mysql`, `rlm_sqlcounter`, `rlm_pap`, `rlm_eap`; ignorados pelo configure: firebird, oracle, postgresql, unixodbc, unbound, winbind etc.

Teste:
```
cd radpanel
bash tests/test_radius_rows.sh                 # fork como está  -> 25 PASS / 14 FAIL (achado 1)
FR_PATCHED=1 bash tests/test_radius_rows.sh    # com libfreeradius-util corrigida -> 39 PASS / 0 FAIL
```
`FR_PATCHED=1` põe `/tmp/claude-0/fr-patched-lib` (a `libfreeradius-util.so` corrigida) em `LD_LIBRARY_PATH` só para o radiusd; a instalação original em `fr-install` não foi modificada.
Para depurar: `FR_KEEP=1` mantém `/tmp/claude-0/fr-test-NOME` (log do radiusd em `radiusd.log`, `-xx`).

`tests/fr_env.sh` (funções `fr_up NOME SQLPORT AUTHPORT`, `fr_down NOME`, `fr_restart`, `fr_auth USER PASS [attr...]`, `fr_code`, `fr_acct TIPO USER SESSAO [attr...]`):
copia o raddb instalado, aponta `confdir/localstatedir` para o diretório de teste, habilita `sql` (`dialect = "mysql"`, 127.0.0.1:SQLPORT), portas auth/acct alternativas só em 127.0.0.1,
remove EAP/inner-tunnel/proxy (evita certificados), cliente `127.0.0.1` segredo `testing123`, valida com `radiusd -C`, sobe `radiusd -f -P` e espera o Status-Server.
Desvio da tarefa: o radiusd usa o usuário de banco **`radiusd`/`testdbpass`** (criado pelo `fr_up` com SELECT/INSERT/UPDATE/DELETE em `radius.*`) e não `radpanel`, porque os grants mínimos do `radpanel`
(`sql/grants.*.sql`) não permitem INSERT em `radacct`/`radpostauth` (o primeiro teste mostrou `INSERT command denied ... radpostauth`) — em produção também deve ser um usuário próprio do radiusd.
Recomendação para o instalador: o usuário do radiusd e seus grants (radacct, radpostauth, radcheck/radreply/radgroup*/radusergroup SELECT; contadores) precisam ser criados pelo `install-panel.sh`.

## NÃO TESTADO

CoA/Disconnect-Request (`coa.php`), EAP/PEAP, enforcamento real de `sqlcounter` e de `Simultaneous-Use` (precisa de `session`/checkrad), limites de franquia, `radtest` (só `radclient`), proxy, e o `radiusd` com o `server-config/` do painel (não presente quando rodei).
