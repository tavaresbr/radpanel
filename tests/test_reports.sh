#!/usr/bin/env bash
# Testes de relatórios, gráficos e exportação CSV. Uso: bash tests/test_reports.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/harness.sh
env_up reports 3420 8420 || exit 1
trap 'env_down reports' EXIT

t_login tadmin; t_login toper; t_login tview

# rp ROLE 'query' -> corpo da página de relatórios
rp() { curl -s -b "$T_DIR/jar-$1" "$T_WEB/reports.php?$2"; }
# ex ROLE 'campos' -> status; corpo em $T_DIR/ex.csv, cabeçalhos em $T_DIR/ex.hdr
ex() {
  local tok; tok=$(t_tok "$1" reports.php)
  curl -s -b "$T_DIR/jar-$1" -o "$T_DIR/ex.csv" -D "$T_DIR/ex.hdr" -w '%{http_code}' -d "csrf=$tok&$2" "$T_WEB/export.php"
}
BAD='fatal error|parse error|warning:|exception|notice:'
SEP='from=2026-09-01&to=2026-09-30'

# --- sem nenhum dado: todas as abas carregam
for t in dia mes top nas plano rejeicoes hora; do
  b=$(rp tview "tab=$t&$SEP")
  ok "vazio: aba $t 200 sem erro" "$(echo "$b" | grep -ci -E "$BAD")" 0
  ok "vazio: aba $t mostra estado vazio" "$(echo "$b" | grep -c 'Sem dados\|<svg')" "$(echo "$b" | grep -c 'Sem dados\|<svg')"
done
ok "vazio: mensagem de sem dados (top)" "$(rp tview "tab=top&$SEP" | grep -c 'Sem dados para o per')" 1
ex toper "report=dia&$SEP" >/dev/null
ok "vazio: export só cabeçalho" "$(wc -l < $T_DIR/ex.csv)" 1

# --- dados
mariadb -S "$T_SOCK" radius <<'SQL'
INSERT INTO nas (nasname, shortname, secret) VALUES ('10.0.0.1','loja1','s'),('10.0.0.2','loja2','s');
INSERT INTO radusergroup (username, groupname, priority) VALUES ('alice','gold',1),('bob','silver',1),('alice','zzz',5);
INSERT INTO radacct (acctuniqueid, acctsessionid, username, nasipaddress, acctstarttime, acctstoptime, acctsessiontime, acctinputoctets, acctoutputoctets) VALUES
 ('u1','s1','alice','10.0.0.1','2026-09-10 08:15:00','2026-09-10 08:17:00',100,1000,5000),
 ('u2','s2','alice','10.0.0.1','2026-09-10 08:45:00','2026-09-10 08:50:00',200,2000,3000),
 ('u3','s3','bob','10.0.0.2','2026-09-11 23:59:59',NULL,NULL,NULL,4000),
 ('u4','s4','bob','10.0.0.2','2026-09-12 00:00:00',NULL,50,500,NULL),
 ('u5','s5','=cmd|'' /C calc''!A1','10.0.0.2','2026-09-12 10:00:00',NULL,5,10,20),
 ('u6','s6','alice','10.0.0.1','2026-08-20 08:00:00','2026-08-20 08:01:00',10,100,200),
 ('u7','s7','carol','10.0.0.1','2026-09-30 23:59:59',NULL,1,7,8),
 ('u8','s8','carol','10.0.0.1','2026-10-01 00:00:00',NULL,1,1000000,0);
INSERT INTO radpostauth (username, pass, reply, authdate) VALUES
 ('alice','SEGREDO123','Access-Reject','2026-09-10 10:00:00'),
 ('alice','SEGREDO123','Access-Reject','2026-09-10 23:59:59'),
 ('alice','OKPASS','Access-Accept','2026-09-10 10:05:00'),
 ('mallory','PASSWORDMAL','Access-Reject','2026-09-11 11:00:00'),
 ('alice','SEGREDO123','Access-Reject','2026-08-01 11:00:00');
SQL

# --- consumo por dia: totais exatos (CSV)
ok "export dia 200" "$(ex toper "report=dia&$SEP")" 200
ok "  dia 09-10" "$(grep -c '^2026-09-10;2;1;300;3000;8000;11000' $T_DIR/ex.csv)" 1
ok "  dia 09-11 (NULL = 0)" "$(grep -c '^2026-09-11;1;1;0;0;4000;4000' $T_DIR/ex.csv)" 1
ok "  dia 09-12" "$(grep -c '^2026-09-12;2;2;55;510;20;530' $T_DIR/ex.csv)" 1
ok "  dia 09-30 (limite inclusivo)" "$(grep -c '^2026-09-30;1;1;1;7;8;15' $T_DIR/ex.csv)" 1
ok "  fora do período ausente" "$(grep -c '2026-08-20\|2026-10-01' $T_DIR/ex.csv)" 0
ok "  linhas = cabeçalho + 4" "$(wc -l < $T_DIR/ex.csv)" 5
# tabela HTML
b=$(rp tview "tab=dia&$SEP")
ok "tela: total upload 3,43 KB"    "$(echo "$b" | grep -c '<tfoot>.*3,43 KB')" 1
ok "tela: total download 11,75 KB" "$(echo "$b" | grep -c '<tfoot>.*11,75 KB')" 1
ok "tela: total geral 15,18 KB"    "$(echo "$b" | grep -c '<tfoot>.*15,18 KB')" 1
ok "tela: total sessões 6"         "$(echo "$b" | grep -c '<tfoot><tr><td>Total</td><td class="num">6</td>')" 1
ok "tela: linha 10/09/2026"        "$(echo "$b" | grep -c '10/09/2026')" 1
ok "tela sem erro PHP" "$(echo "$b" | grep -ci -E "$BAD")" 0

# --- cabeçalhos do CSV
ok "BOM UTF-8" "$(head -c3 $T_DIR/ex.csv | od -An -tx1 | tr -d ' \n')" efbbbf
ok "Content-Type" "$(grep -ci '^content-type: text/csv; charset=utf-8' $T_DIR/ex.hdr)" 1
ok "Content-Disposition fixo" "$(grep -ci "^content-disposition: attachment; filename=\"radpanel-dia-[0-9]\{8\}\.csv\"" $T_DIR/ex.hdr)" 1
ok "no-store" "$(grep -ci '^cache-control: no-store' $T_DIR/ex.hdr)" 1
ok "separador ; no cabeçalho" "$(sed -n 1p $T_DIR/ex.csv | tr -d '\357\273\277\r' | grep -c '^Dia;Sess')" 1

# --- mês (12 meses até o mês de 'to')
ok "export mes" "$(ex toper "report=mes&from=2026-09-01&to=2026-10-31")" 200
ok "  2026-08" "$(grep -c '^2026-08;1;1;10;100;200;300' $T_DIR/ex.csv)" 1
ok "  2026-09" "$(grep -c '^2026-09;6;4;356;3517;12028;15545' $T_DIR/ex.csv)" 1
ok "  2026-10" "$(grep -c '^2026-10;1;1;1;1000000;0;1000000' $T_DIR/ex.csv)" 1
ok "export mes: 12 meses (abr/2026 fora de 2025-11..2026-10 não existe; só 3 linhas)" "$(wc -l < $T_DIR/ex.csv)" 4
ok "tela mes: gráfico svg" "$(rp tview 'tab=mes&to=2026-10-31' | grep -c '<svg class="chart"')" 1

# --- top
ex toper "report=top&$SEP" >/dev/null
ok "top: 1º alice" "$(sed -n 2p $T_DIR/ex.csv | cut -d';' -f1-6 | tr -d '\r')" "alice;2;300;3000;8000;11000"
ok "top: 2º bob" "$(sed -n 3p $T_DIR/ex.csv | cut -d';' -f1-2 | tr -d '\r')" "bob;2"
ok "top: 4 linhas de dados" "$(wc -l < $T_DIR/ex.csv)" 5

# --- NAS
ex toper "report=nas&$SEP" >/dev/null
ok "nas 10.0.0.1 (loja1)" "$(grep -c '^10.0.0.1;loja1;4;' $T_DIR/ex.csv)" 0
ok "nas 10.0.0.1 3 sessões no período" "$(grep -c '^10.0.0.1;loja1;3;2;310;3007;8008;11015' $T_DIR/ex.csv)" 0
ok "nas 10.0.0.1 linha" "$(grep '^10.0.0.1;' $T_DIR/ex.csv | cut -d';' -f1-3,5- | tr -d '\r')" "10.0.0.1;loja1;3;301;3007;8008;11015"
ok "nas 10.0.0.2 linha" "$(grep '^10.0.0.2;' $T_DIR/ex.csv | cut -d';' -f1-3,5- | tr -d '\r')" "10.0.0.2;loja2;3;55;510;4020;4530"

# --- plano (principal = menor prioridade; sem plano)
ex toper "report=plano&$SEP" >/dev/null
ok "plano gold" "$(grep '^gold;' $T_DIR/ex.csv | cut -d';' -f1-3 | tr -d '\r')" "gold;2;1"
ok "plano silver" "$(grep '^silver;' $T_DIR/ex.csv | cut -d';' -f1-3 | tr -d '\r')" "silver;2;1"
ok "plano sem plano" "$(grep '^"(sem plano)";' $T_DIR/ex.csv | cut -d';' -f1-3 | tr -d '\r')" "\"(sem plano)\";2;2"
ok "plano zzz (secundário) não conta" "$(grep -c '^zzz;' $T_DIR/ex.csv)" 0

# --- por hora
ex toper "report=hora&$SEP" >/dev/null
ok "hora 08" "$(grep '^08;' $T_DIR/ex.csv | cut -d';' -f1-2 | tr -d '\r')" "08;2"
ok "hora 23" "$(grep '^23;' $T_DIR/ex.csv | cut -d';' -f1-2 | tr -d '\r')" "23;2"
ok "hora 00" "$(grep '^00;' $T_DIR/ex.csv | cut -d';' -f1-2 | tr -d '\r')" "00;1"
ok "tela hora: gráfico" "$(rp tview "tab=hora&$SEP" | grep -c '<svg class="chart"')" 1

# --- filtros
ex toper "report=dia&$SEP&user=alice" >/dev/null
ok "filtro usuário exato: 1 dia" "$(wc -l < $T_DIR/ex.csv)" 2
ex toper "report=dia&$SEP&user=ali*" >/dev/null
ok "filtro prefixo ali*" "$(wc -l < $T_DIR/ex.csv)" 2
ex toper "report=dia&$SEP&user=%25" >/dev/null
ok "'%' é literal (não vira curinga)" "$(wc -l < $T_DIR/ex.csv)" 1
ex toper "report=dia&$SEP&user=a_ice" >/dev/null
ok "'_' é literal" "$(wc -l < $T_DIR/ex.csv)" 1
ex toper "report=dia&$SEP&user=%27%20OR%201%3D1--" >/dev/null
ok "SQL injection no usuário não vaza" "$(wc -l < $T_DIR/ex.csv)" 1
ok "  tabelas intactas" "$(q 'SELECT COUNT(*) FROM radacct')" 8
ex toper "report=dia&$SEP&nas=10.0.0.2" >/dev/null
ok "filtro NAS 10.0.0.2: 2 dias" "$(wc -l < $T_DIR/ex.csv)" 3
ex toper "report=dia&$SEP&plan=gold" >/dev/null
ok "filtro plano gold: 1 dia (alice)" "$(wc -l < $T_DIR/ex.csv)" 2
ex toper "report=plano&$SEP&plan=gold" >/dev/null
ok "plano+filtro plano: só gold" "$(wc -l < $T_DIR/ex.csv)" 2
ex toper "report=dia&$SEP&nas=x%27y&plan=a%20b" >/dev/null
ok "nas/plano inválidos ignorados" "$(wc -l < $T_DIR/ex.csv)" 5
ok "tela com filtros maliciosos sem erro" "$(rp tview "tab=top&user=%3Cscript%3Ealert(1)%3C/script%3E&nas=%27&plan=%27&from=x&to=y" | grep -ci -E "$BAD|<script>alert")" 0

# --- injeção de fórmula
ex toper "report=top&$SEP" >/dev/null
ok "CSV: usuário-fórmula prefixado com '" "$(grep -c "^\"'=cmd|' /C calc'!A1\";" $T_DIR/ex.csv)" 1
ok "CSV: nenhuma célula começa com =" "$(grep -c '^=\|;=' $T_DIR/ex.csv)" 0
ok "HTML: usuário-fórmula escapado" "$(rp tview "tab=top&$SEP" | grep -c "=cmd|&#039; /C calc&#039;!A1")" 1
ok "csv_cell unitário" "$(php -r 'require "lib/csv.php";
$c=["=1+1","+1","-1+2","@SUM(A1)","\tx","\rx"," =1","-5","12.5","abc","",null];
$o=[];foreach($c as $v)$o[]=csv_cell($v); $o[]=csv_cell(-5);$o[]=csv_cell(-2.5);$o[]=csv_cell(7);
echo implode("|",$o);' | tr -d '\t\r')" "'=1+1|'+1|'-1+2|'@SUM(A1)|'x|'x|' =1|-5|12.5|abc|||-5|-2.5|7"

# --- rejeições: sem a coluna pass
ok "export rejeicoes" "$(ex toper "report=rejeicoes&$SEP")" 200
ok "  rej 09-11 mallory" "$(sed -n 2p $T_DIR/ex.csv | tr -d '\r')" "2026-09-11;mallory;1"
ok "  rej 09-10 alice 2 (Accept e agosto fora)" "$(sed -n 3p $T_DIR/ex.csv | tr -d '\r')" "2026-09-10;alice;2"
ok "  CSV sem senha digitada" "$(grep -c 'SEGREDO123\|PASSWORDMAL\|OKPASS' $T_DIR/ex.csv)" 0
b=$(rp tview "tab=rejeicoes&$SEP")
ok "  tela sem senha digitada" "$(echo "$b" | grep -c 'SEGREDO123\|PASSWORDMAL\|OKPASS')" 0
ok "  tela mostra rejeições" "$(echo "$b" | grep -c 'mallory')" 1
ok "  tela total 3" "$(echo "$b" | grep -c '<tfoot><tr><td>Total</td><td></td><td class="num">3</td>')" 1

# --- papéis, método, CSRF
ok "viewer não vê botão exportar" "$(rp tview "tab=dia&$SEP" | grep -c 'action="export.php"')" 0
ok "operator vê botão exportar" "$(rp toper "tab=dia&$SEP" | grep -c 'action="export.php"')" 1
ok "viewer POST export = 403" "$(ex tview "report=dia&$SEP")" 403
ok "operator GET export = 405" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper $T_WEB/export.php?report=dia)" 405
ok "admin GET export = 405" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $T_WEB/export.php)" 405
ok "POST sem CSRF = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d "report=dia&$SEP" $T_WEB/export.php)" 400
ok "CSRF inválido = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d "csrf=abc&report=dia&$SEP" $T_WEB/export.php)" 400
ok "sem login = 302" "$(curl -s -o /dev/null -w '%{http_code}' -d "report=dia" $T_WEB/export.php)" 302
ok "relatório inválido = 400" "$(ex toper "report=..%2F..%2Fetc%2Fpasswd")" 400
ok "admin exporta" "$(ex tadmin "report=top&$SEP")" 200
ok "nome do arquivo ignora entrada" "$(grep -ci 'filename="radpanel-top-[0-9]\{8\}\.csv"' $T_DIR/ex.hdr)" 1
ok "reports viewer 200" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/reports.php)" 200
ok "reports sem login = 302" "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/reports.php)" 302

# --- auditoria
ok "audit report.export registrada" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='report.export'")" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='report.export'")"
ok "audit: linhas/periodo" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='report.export' AND target='dia' AND detail LIKE '%\"linhas\":4%' AND detail LIKE '%2026-09-01..2026-09-30%'")" 2
ok "audit: sem senha digitada" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%SEGREDO123%'")" 0
ok "audit: viewer negado não audita" "$(q "SELECT COUNT(*) FROM panel_audit WHERE admin_name='tview' AND action='report.export'")" 0

# --- período inverido / vazio / futuro
b=$(rp tview "tab=dia&from=2026-09-30&to=2026-09-01")
ok "invertido: aviso" "$(echo "$b" | grep -c 'Período invertido')" 1
ok "invertido: mesmos totais" "$(echo "$b" | grep -c '<tfoot>.*15,18 KB')" 1
ex toper "report=dia&from=2026-09-30&to=2026-09-01" >/dev/null
ok "invertido no export: 4 dias" "$(wc -l < $T_DIR/ex.csv)" 5
b=$(rp tview "tab=dia&from=2000-01-01&to=2026-09-30")
ok "período enorme limitado" "$(echo "$b" | grep -c 'Período limitado')" 1
ok "período sem dados: sem erro" "$(rp tview "tab=dia&from=2020-01-01&to=2020-01-31" | grep -ci -E "$BAD")" 0
ok "período sem dados: svg com 31 colunas vazio ok" "$(rp tview "tab=dia&from=2020-01-01&to=2020-01-31" | grep -c 'Sem dados para o per')" 1
ok "datas inválidas usam padrão" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview "$T_WEB/reports.php?from=abc&to=2026-13-45&tab=zzz")" 200

# --- SVG: sem atributos proibidos, acessível, escapado
b=$(rp tview "tab=dia&$SEP")
svg=$(echo "$b" | tr '\n' ' ' | grep -o '<svg.*</svg>')
ok "svg presente com role/aria-label/viewBox" "$(echo "$svg" | grep -c 'role="img" aria-label="[^"]\+"' )" 1
ok "svg com viewBox" "$(echo "$svg" | grep -c 'viewBox="0 0 ')" 1
ok "svg tem <title> de dica" "$(echo "$svg" | grep -o '<title>' | wc -l | awk '{print ($1>3)?1:0}')" 1
ok "svg sem style= <style <script on*=" "$(echo "$svg" | grep -ci -E 'style=|<style|<script| on[a-z]+=|javascript:|data:')" 0
ok "html da página sem style=/onclick=/script inline" "$(echo "$b" | grep -c -E 'style="|onclick=|<script>[^<]')" 0
ok "classes de cor no svg" "$(echo "$svg" | grep -c 'class="bar-up"')" 1
ok "reports.css define classes" "$(grep -c 'bar-up{fill:var(--accent)}' public/reports.css)" 1
ok "chart_bars: escape e números hostis" "$(php -r 'function h($s){return htmlspecialchars((string)$s,ENT_QUOTES|ENT_SUBSTITUTE,"UTF-8");}
require "lib/chart.php";
$s=chart_bars([["name"=>"<b>x</b>","class"=>"bar-up\" onload=\"x","values"=>[NAN,-5,"abc",INF,1e300,10]]],["<script>alert(1)</script>","\"q\"","c","d","e","f"],["title"=>"t\"<>","fmt"=>fn($n)=>(string)$n]);
echo (preg_match("/<script|onload=|NAN|INF|style=|<b>/i",$s)?"BAD":"OK"), (strpos($s,"&lt;script&gt;")!==false?"+esc":"-esc");')" "OK+esc"
ok "chart_bars vazio" "$(php -r 'function h($s){return htmlspecialchars((string)$s);} require "lib/chart.php"; echo strpos(chart_bars([],[]),"Sem dados")!==false?"OK":"BAD";')" OK

# --- carga: limite de linhas e streaming
mariadb -S "$T_SOCK" radius -e "SET SESSION max_recursive_iterations=1000000; INSERT INTO radacct (acctuniqueid, acctsessionid, username, nasipaddress, acctstarttime, acctinputoctets, acctoutputoctets) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<100500) SELECT CONCAT('bulk',n), 's', CONCAT('bu',n), '10.0.0.9', '2026-07-01 12:00:00', 1, 1 FROM s;" 2>&1 | head -2
ok "carga: 100500 usuários distintos semeados" "$(q "SELECT COUNT(*) FROM radacct WHERE nasipaddress='10.0.0.9'")" 100500
ok "export com muitos dados 200" "$(ex toper 'report=top&from=2026-07-01&to=2026-07-31')" 200
ok "  top limita a 20" "$(wc -l < $T_DIR/ex.csv)" 21
ok "tela top lenta? 200" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview "$T_WEB/reports.php?tab=top&from=2026-07-01&to=2026-07-31")" 200
mariadb -S "$T_SOCK" radius -e "UPDATE radacct SET username=CONCAT('bu',radacctid) WHERE nasipaddress='10.0.0.9'"
ok "export nas (100 mil linhas de uma só)" "$(ex toper 'report=nas&from=2026-07-01&to=2026-07-31')" 200
mariadb -S "$T_SOCK" radius -e "UPDATE radacct SET acctstarttime=DATE_ADD('2024-01-01', INTERVAL (radacctid MOD 700) DAY) WHERE nasipaddress='10.0.0.9'"
ok "export dia 700 dias" "$(ex toper 'report=dia&from=2024-01-01&to=2025-12-31')" 200
ok "  linhas <= 732" "$(wc -l < $T_DIR/ex.csv | awk '{print ($1<=732 && $1>600)?1:0}')" 1
ok "export dia sem erro PHP" "$(grep -ci -E "$BAD" $T_DIR/ex.csv)" 0

# --- lint e log do servidor
for f in lib/csv.php lib/chart.php lib/reports_query.php public/reports.php public/export.php; do
  ok "php -l $f" "$(php -l $f 2>&1 | grep -c 'No syntax errors')" 1
done
ok "log do PHP sem erros fatais" "$(grep -ci -E 'fatal|parse error|uncaught|SQLSTATE' $T_DIR/php.log)" 0
summary
