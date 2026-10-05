#!/usr/bin/env bash
# Testes de clientes e cobrança. Uso: bash tests/test_customers.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
source tests/harness.sh
env_up customers 3470 8470 || exit 1
trap 'env_down customers' EXIT

t_login tadmin; t_login toper; t_login tview
TODAY=$(TZ=America/Sao_Paulo date +%F)
d() { TZ=America/Sao_Paulo date -d "$TODAY $1" +%F; }
utc_end() { date -u -d "@$(TZ=America/Sao_Paulo date -d "$1 23:59:59" +%s)" +%Y-%m-%dT%H:%M:%SZ; }
trig() { printf 'DELIMITER //\nCREATE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW BEGIN IF %s THEN SIGNAL SQLSTATE '"'"'45000'"'"' SET MESSAGE_TEXT='"'"'%s'"'"'; END IF; END//\n' "$1" "$2" "$3" "$4" | mariadb -S "$T_SOCK" radius; }
code() { curl -s -o /dev/null -w '%{http_code}' -b "$T_DIR/jar-$1" "$T_WEB/$2"; }
exp_of() { q "SELECT value FROM radcheck WHERE username='$1' AND attribute='Expiration'"; }
npay() { q "SELECT COUNT(*) FROM panel_payments WHERE customer_id=$1"; }
cust_id() { q "SELECT id FROM panel_customers WHERE name='$1' LIMIT 1"; }
mkuser() { # user expiration(optional)
  q "INSERT INTO radcheck (username,attribute,op,value) VALUES ('$1','Password.Cleartext',':=','x1234567')"
  [ -n "${2:-}" ] && q "INSERT INTO radcheck (username,attribute,op,value) VALUES ('$1','Expiration',':=','$2')"
  return 0
}
fmt_rs() { awk -v v="$1" 'BEGIN{split(v,a,"."); i=a[1]; s=""; while(length(i)>3){s="." substr(i,length(i)-2) s; i=substr(i,1,length(i)-3)} printf "R$ %s%s,%s\n", i, s, a[2]}'; }
tok_of() { grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//'; }
# pay JAR ID ACTION 'campos' -> status
pay() {
  local page tok non
  page=$(t_get "$1" "customer.php?id=$2")
  tok=$(echo "$page" | tok_of)
  non=$(echo "$page" | grep -o 'name="nonce" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
  curl -s -b "$T_DIR/jar-$1" -c "$T_DIR/jar-$1" -o "$T_DIR/last.html" -w '%{http_code}' \
    -d "csrf=$tok&id=$2&nonce=$non&action=$3&$4" "$T_WEB/customer.php"
}
flash_text() { t_get "${2:-toper}" "customer.php?id=$1" | grep -o 'class="flash [a-z]*">[^<]*' | sed 's/.*">//'; }
cflash() { t_get toper "customers.php" | grep -o 'class="flash [a-z]*">[^<]*' | sed 's/.*">//'; }

# --- dinheiro exato (lib pura, sem float)
cat >"$T_DIR/money.php" <<PHP
<?php require '$ROOT/lib/customers.php';
\$bad = 0;
function chk(\$a, \$b) { global \$bad; if (\$a !== \$b) { \$bad++; echo "ERRO: " . var_export(\$a, true) . " != " . var_export(\$b, true) . "\n"; } }
chk(money_parse('0,10') + money_parse('0,20'), money_parse('0.30'));
chk(money_parse('12,50'), 1250); chk(money_parse('12.50'), 1250); chk(money_parse('1.234,56'), 123456);
chk(money_parse('R\$ 12,5'), 1250); chk(money_parse('12'), 1200); chk(money_parse('0,01'), 1);
chk(money_parse('99999999,99'), 9999999999);
foreach (['', 'abc', '0', '0,00', '-5', '1,234.56', '12,505', '1.234', '100000000', '1,2,3', '1.2,5', '12,5x'] as \$b) {
  try { money_parse(\$b); chk("aceitou '\$b'", 'rejeitar'); } catch (RuntimeException \$e) {}
}
// 0.10 em centavos repetido 10x = 1,00 (float daria 0.9999...)
\$s = 0; for (\$i = 0; \$i < 10; \$i++) { \$s += money_parse('0,10'); } chk(\$s, 100);
chk(money_fmt(123456), 'R\$ 1.234,56'); chk(money_fmt(5), 'R\$ 0,05'); chk(money_fmt(100000000), 'R\$ 1.000.000,00');
chk(money_to_db(1250), '12.50'); chk(money_from_db('1234.50'), 123450); chk(money_from_db('0.1'), 10); chk(money_from_db('30.00'), 3000);
chk(money_from_db(money_to_db(9999999999)), 9999999999);
echo \$bad === 0 ? "OK\n" : "FALHAS \$bad\n";
PHP
out=$(php "$T_DIR/money.php" 2>&1)
ok "money_* exato (0,10+0,20=0,30; parse; fmt; rejeições)" "$out" "OK"
ok "php -l" "$(for f in public/customers.php public/customer.php lib/customers.php; do php -l $f; done | grep -vc 'No syntax errors')" 0

# --- papéis
ok "sem login = 302" "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/customers.php)" 302
ok "sem login detalhe = 302" "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/customer.php?id=1)" 302
ok "viewer não acessa clientes (dados pessoais) = 403" "$(code tview customers.php)" 403
ok "viewer não acessa relatório financeiro = 403" "$(code tview 'customers.php?tab=report')" 403
ok "viewer não vê preços" "$(code tview 'customers.php?tab=prices')" 403
ok "operator não vê preços" "$(code toper 'customers.php?tab=prices')" 403
ok "admin vê preços" "$(code tadmin 'customers.php?tab=prices')" 200
ok "viewer não cria (403)" "$(t_post tview customers.php customers.php 'action=create&name=Viewer+Tenta')" 403
ok "  nada gravado" "$(q "SELECT COUNT(*) FROM panel_customers")" 0
ok "POST sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d 'action=create&name=SemCsrf' $T_WEB/customers.php)" 400
ok "viewer não vê formulário de criação" "$(t_get tview customers.php | grep -c 'name="action" value="create"')" 0

# --- usuários RADIUS e planos
mkuser u_ana "$(utc_end "$(d '+5 days')")"
mkuser u_bia
mkuser u_cid
ok "admin salva plano" "$(t_post tadmin plans.php plans.php 'action=save&name=basico&down=10M&up=2M&timeout=3600&idle=300&interim=300')" 302
ok "operator não salva preço (403)" "$(t_post toper customers.php customers.php 'action=price_save&plan=basico&price=79,90&period_days=30')" 403
ok "admin preço inválido rejeitado" "$(t_post tadmin customers.php customers.php 'action=price_save&plan=basico&price=abc&period_days=30')" 302
ok "  nenhum preço" "$(q "SELECT COUNT(*) FROM panel_plan_prices")" 0
t_post tadmin customers.php customers.php 'action=price_save&plan=inexistente&price=10&period_days=30' >/dev/null
ok "  plano inexistente rejeitado" "$(q "SELECT COUNT(*) FROM panel_plan_prices")" 0
t_post tadmin customers.php customers.php 'action=price_save&plan=basico&price=79,90&period_days=30' >/dev/null
ok "  preço 79,90 gravado" "$(q "SELECT price FROM panel_plan_prices WHERE groupname='basico'")" "79.90"
q "INSERT INTO radusergroup (username,groupname,priority) VALUES ('u_ana','basico',1)"

# --- validações de cadastro
inv() { # descricao campos
  t_post toper customers.php customers.php "action=create&$2" >/dev/null
  ok "$1" "$(q "SELECT COUNT(*) FROM panel_customers")" "$3"
}
inv "nome vazio rejeitado" "name=&email=a@b.com" 0
inv "e-mail inválido rejeitado" "name=Teste&email=nao-e-email" 0
inv "telefone inválido rejeitado" "name=Teste&phone=abc123" 0
inv "telefone só símbolos rejeitado" "name=Teste&phone=%28%29" 0
inv "nome > 120 rejeitado" "name=$(printf 'A%.0s' $(seq 1 121))" 0
inv "documento > 30 rejeitado" "name=Teste&document=$(printf '1%.0s' $(seq 1 31))" 0
inv "usuário inexistente rejeitado" "name=Teste&username=nao_existe" 0
ok "  mensagem de usuário inexistente" "$(cflash | grep -c 'não existe')" 1
inv "usuário com caracteres inválidos rejeitado" "name=Teste&username=x%27%20OR%201=1--" 0
ok "operator cria cliente completo" "$(t_post toper customers.php customers.php 'action=create&name=Ana+Silva&email=ana.segredo%40exemplo.com&phone=%2B55+%2811%29+99988-7766&document=DOC123456789&address=Rua+Secreta+10&notes=obs+privada&username=u_ana')" 302
ANA=$(cust_id "Ana Silva")
ok "  cliente criado" "$(q "SELECT COUNT(*) FROM panel_customers")" 1
ok "  vínculo gravado" "$(q "SELECT username FROM panel_customers WHERE id=$ANA")" u_ana
ok "operator cria 2º cliente" "$(t_post toper customers.php customers.php 'action=create&name=Bia+Souza&username=u_bia')" 302
BIA=$(cust_id "Bia Souza")
inv "usuário já vinculado a outro cliente rejeitado" "name=Outro&username=u_ana" 2
ok "  mensagem de vínculo" "$(cflash | grep -c 'já está vinculado')" 1
inv "vínculo case-insensitive (U_ANA) rejeitado" "name=Outro2&username=U_ANA" 2
# edição: não pode roubar o usuário do outro
t_post toper customer.php customer.php "action=update&id=$BIA&name=Bia+Souza&username=u_ana" >/dev/null
ok "edição não rouba vínculo" "$(q "SELECT username FROM panel_customers WHERE id=$BIA")" u_bia
ok "edição válida" "$(t_post toper customer.php customer.php "action=update&id=$BIA&name=Bia+Souza&phone=11999990000&username=u_bia")" 302
ok "  telefone gravado" "$(q "SELECT phone FROM panel_customers WHERE id=$BIA")" 11999990000
ok "viewer não edita (403)" "$(t_post tview customers.php customer.php "action=update&id=$BIA&name=Hack")" 403
ok "  nome intacto" "$(q "SELECT name FROM panel_customers WHERE id=$BIA")" "Bia Souza"

# --- registrar pagamento (sem renovar) e dinheiro exato
OLD=$(exp_of u_ana)
ok "valor inválido 'abc' rejeitado" "$(pay toper $ANA pay "amount=abc&method=pix&paid_at=$TODAY")" 302
ok "valor 0 rejeitado" "$(pay toper $ANA pay "amount=0&method=pix&paid_at=$TODAY")" 302
ok "valor negativo rejeitado" "$(pay toper $ANA pay "amount=-5&method=pix&paid_at=$TODAY")" 302
ok "valor '12,505' rejeitado" "$(pay toper $ANA pay "amount=12,505&method=pix&paid_at=$TODAY")" 302
ok "forma inválida rejeitada" "$(pay toper $ANA pay "amount=10&method=bitcoin&paid_at=$TODAY")" 302
ok "data futura rejeitada" "$(pay toper $ANA pay "amount=10&method=pix&paid_at=$(d '+3 days')")" 302
ok "período invertido rejeitado" "$(pay toper $ANA pay "amount=10&method=pix&paid_at=$TODAY&period_from=$(d '+10 days')&period_to=$TODAY")" 302
ok "data inválida rejeitada" "$(pay toper $ANA pay "amount=10&method=pix&paid_at=2026-02-31")" 302
ok "  nenhum pagamento gravado" "$(npay $ANA)" 0
pay toper $ANA pay "amount=0,10&method=dinheiro&paid_at=$TODAY" >/dev/null
pay toper $ANA pay "amount=0,20&method=pix&paid_at=$TODAY" >/dev/null
ok "0,10 + 0,20 no banco = 0,30" "$(q "SELECT SUM(amount) FROM panel_payments WHERE customer_id=$ANA")" "0.30"
ok "  mostrado como R\$ 0,30" "$(t_get toper "customer.php?id=$ANA" | grep -c 'Total recebido: <strong>R\$ 0,30</strong>')" 1
pay toper $ANA pay "amount=1.234,56&method=transferencia&paid_at=$TODAY" >/dev/null
ok "1.234,56 gravado 1234.56" "$(q "SELECT amount FROM panel_payments WHERE customer_id=$ANA AND method='transferencia'")" "1234.56"
pay toper $ANA pay "amount=12.50&method=cartao&paid_at=$TODAY" >/dev/null
ok "12.50 gravado 12.50" "$(q "SELECT amount FROM panel_payments WHERE customer_id=$ANA AND method='cartao'")" "12.50"
ok "pagamento simples não mexe na validade" "$(exp_of u_ana)" "$OLD"
ok "  created_by = operador" "$(q "SELECT DISTINCT created_by FROM panel_payments WHERE customer_id=$ANA")" toper
ok "viewer não paga (403)" "$(pay tview $ANA pay "amount=10&method=pix&paid_at=$TODAY")" 403
ok "  contagem intacta" "$(npay $ANA)" 4
ok "pagamento sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d "id=$ANA&action=pay&amount=10&method=pix&paid_at=$TODAY" $T_WEB/customer.php)" 400

# --- pagar e renovar (RFC 3339, fuso America/Sao_Paulo)
TO=$(d '+40 days')
ok "pagar e renovar" "$(pay toper $ANA pay_renew "amount=79,90&method=pix&paid_at=$TODAY&period_from=$(d '+6 days')&period_to=$TO&notes=mensalidade")" 302
ok "  Expiration em RFC 3339 UTC (fim do dia em São Paulo)" "$(exp_of u_ana)" "$(utc_end "$TO")"
ok "  formato aceito pelo FreeRADIUS (…Z)" "$(exp_of u_ana | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" 1
ok "  fim do dia local = 02:59:59Z do dia seguinte" "$(exp_of u_ana | grep -c 'T02:59:59Z')" 1
ok "  pagamento gravado" "$(q "SELECT amount FROM panel_payments WHERE customer_id=$ANA AND notes='mensalidade'")" "79.90"
ok "  situação em dia até" "$(t_get toper "customer.php?id=$ANA" | grep -c "em dia até $(TZ=America/Sao_Paulo date -d "$TO" +%d/%m/%Y)")" 1
ok "  auditoria user.expires + customer.payment" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action IN ('user.expires','customer.payment') AND target IN ('u_ana','customer#$ANA')")" 6
# não encurta validade
ok "renovação com período menor não encurta" "$(pay toper $ANA pay_renew "amount=10&method=pix&paid_at=$TODAY&period_from=$TODAY&period_to=$(d '+10 days')")" 302
ok "  Expiration mantida" "$(exp_of u_ana)" "$(utc_end "$TO")"
ok "  mas o pagamento foi gravado" "$(q "SELECT COUNT(*) FROM panel_payments WHERE customer_id=$ANA AND amount=10.00")" 1
ok "renovar sem período rejeitado" "$(pay toper $ANA pay_renew "amount=10&method=pix&paid_at=$TODAY")" 302
ok "  sem novo pagamento" "$(q "SELECT COUNT(*) FROM panel_payments WHERE customer_id=$ANA AND amount=10.00")" 1
# cliente sem usuário
t_post toper customers.php customers.php 'action=create&name=Sem+Usuario' >/dev/null
SEM=$(cust_id "Sem Usuario")
ok "renovar cliente sem usuário rejeitado" "$(pay toper $SEM pay_renew "amount=10&method=pix&paid_at=$TODAY&period_to=$(d '+30 days')")" 302
ok "  nada gravado" "$(npay $SEM)" 0
ok "pagamento simples de cliente sem usuário ok" "$(pay toper $SEM pay "amount=10&method=pix&paid_at=$TODAY")" 302
ok "  gravado" "$(npay $SEM)" 1
ok "sem botão de renovar para cliente sem usuário" "$(t_get toper "customer.php?id=$SEM" | grep -c 'value="pay_renew"')" 0

# --- duplo envio (mesmo nonce)
page=$(t_get toper "customer.php?id=$BIA"); tk=$(echo "$page" | tok_of)
nn=$(echo "$page" | grep -o 'name="nonce" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
for i in 1 2; do
  curl -s -b $T_DIR/jar-toper -c $T_DIR/jar-toper -o /dev/null -d "csrf=$tk&id=$BIA&nonce=$nn&action=pay&amount=50&method=pix&paid_at=$TODAY" $T_WEB/customer.php
done
ok "duplo envio do mesmo formulário grava 1 pagamento" "$(npay $BIA)" 1
ok "pagamento sem nonce rejeitado" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -c $T_DIR/jar-toper -d "csrf=$(t_tok toper customers.php)&id=$BIA&action=pay&amount=50&method=pix&paid_at=$TODAY" $T_WEB/customer.php)" 302
ok "  continua 1" "$(npay $BIA)" 1

# --- atomicidade: falha no meio (trigger força erro ao regravar Expiration de u_fail)
mkuser u_fail "$(utc_end "$(d '+3 days')")"
t_post toper customers.php customers.php 'action=create&name=Falha+Total&username=u_fail' >/dev/null
FAIL=$(cust_id "Falha Total")
BEFORE=$(exp_of u_fail)
trig t_fail radcheck "NEW.username='u_fail' AND NEW.attribute='Expiration'" 'falha forçada' 
ok "pagar e renovar com falha forçada" "$(pay toper $FAIL pay_renew "amount=30&method=pix&paid_at=$TODAY&period_to=$(d '+60 days')")" 302
ok "  pagamento NÃO ficou gravado (rollback)" "$(npay $FAIL)" 0
ok "  Expiration intacta (DELETE também desfeito)" "$(exp_of u_fail)" "$BEFORE"
ok "  sem auditoria de pagamento" "$(q "SELECT COUNT(*) FROM panel_audit WHERE target='customer#$FAIL'")" 1
ok "  mensagem de erro genérica, sem vazar SQL" "$(flash_text $FAIL | grep -c -i -E 'falha forçada|SQLSTATE')" 0
q "DROP TRIGGER t_fail"
ok "sem o gatilho, a mesma operação funciona" "$(pay toper $FAIL pay_renew "amount=30&method=pix&paid_at=$TODAY&period_to=$(d '+60 days')")" 302
ok "  agora 1 pagamento e validade nova" "$(npay $FAIL)/$(exp_of u_fail)" "1/$(utc_end "$(d '+60 days')")"
# usuário vinculado que sumiu do radcheck: renovar falha por inteiro
mkuser u_gone "$(utc_end "$(d '+3 days')")"
t_post toper customers.php customers.php 'action=create&name=Usuario+Sumiu&username=u_gone' >/dev/null
GONE=$(cust_id "Usuario Sumiu")
q "DELETE FROM radcheck WHERE username='u_gone'"
ok "renovar com usuário removido do RADIUS" "$(pay toper $GONE pay_renew "amount=30&method=pix&paid_at=$TODAY&period_to=$(d '+60 days')")" 302
ok "  pagamento revertido" "$(npay $GONE)" 0
ok "  detalhe mostra 'usuário não existe mais'" "$(t_get toper "customer.php?id=$GONE" | grep -c 'não existe mais')" 1
ok "  editar mantendo vínculo antigo é permitido" "$(t_post toper customer.php customer.php "action=update&id=$GONE&name=Usuario+Sumiu+2&username=u_gone")" 302
ok "  nome atualizado" "$(q "SELECT name FROM panel_customers WHERE id=$GONE")" "Usuario Sumiu 2"

# --- usuário bloqueado não é desbloqueado
mkuser u_blk "$(utc_end "$(d '+2 days')")"
t_post toper customers.php customers.php 'action=create&name=Bloqueado&username=u_blk' >/dev/null
BLK=$(cust_id "Bloqueado")
t_post toper users.php users.php 'action=block&username=u_blk' >/dev/null
ok "usuário bloqueado (pré-condição)" "$(exp_of u_blk)" "2000-01-01T00:00:00Z"
NEWTO=$(d '+45 days')
ok "pagar e renovar usuário bloqueado" "$(pay toper $BLK pay_renew "amount=79,90&method=pix&paid_at=$TODAY&period_to=$NEWTO")" 302
ok "  pagamento gravado" "$(npay $BLK)" 1
ok "  continua bloqueado (Expiration 2000)" "$(exp_of u_blk)" "2000-01-01T00:00:00Z"
ok "  flag blocked mantida" "$(q "SELECT blocked FROM panel_user_meta WHERE username='u_blk'")" 1
ok "  mensagem informa o bloqueio" "$(flash_text $BLK | grep -c 'BLOQUEADO')" 1
t_post toper users.php users.php 'action=unblock&username=u_blk' >/dev/null
ok "  ao desbloquear manualmente, restaura a validade paga" "$(exp_of u_blk)" "$(utc_end "$NEWTO")"

# --- exclusão / arquivamento
ok "excluir cliente com pagamentos é recusado" "$(t_post toper customers.php customers.php "action=delete&id=$ANA")" 302
ok "  cliente permanece" "$(q "SELECT COUNT(*) FROM panel_customers WHERE id=$ANA")" 1
ok "  pagamentos permanecem" "$(npay $ANA)" 6
ok "  mensagem sugere arquivar" "$(cflash | grep -c 'Arquivar')" 1
ok "arquivar" "$(t_post toper customers.php customers.php "action=archive&id=$ANA")" 302
ok "  archived=1" "$(q "SELECT archived FROM panel_customers WHERE id=$ANA")" 1
ok "  some da lista padrão" "$(t_get toper customers.php | grep -c 'Ana Silva')" 0
ok "  aparece com 'mostrar arquivados'" "$(t_get toper 'customers.php?arch=1' | grep -c 'Ana Silva')" 1
ok "  pagamento em cliente arquivado recusado" "$(pay toper $ANA pay "amount=10&method=pix&paid_at=$TODAY")" 302
ok "  (nenhum novo pagamento)" "$(npay $ANA)" 6
t_post toper customers.php customers.php "action=unarchive&id=$ANA" >/dev/null
ok "desarquivar" "$(q "SELECT archived FROM panel_customers WHERE id=$ANA")" 0
ok "excluir cliente sem pagamentos" "$(t_post toper customers.php customers.php "action=delete&id=$GONE")" 302
ok "  cliente removido" "$(q "SELECT COUNT(*) FROM panel_customers WHERE id=$GONE")" 0
mkuser u_del
t_post toper customers.php customers.php 'action=create&name=Del&username=u_del' >/dev/null
t_post toper customers.php customers.php "action=delete&id=$(cust_id Del)" >/dev/null
ok "  excluir cliente NÃO exclui o usuário RADIUS" "$(q "SELECT COUNT(*) FROM radcheck WHERE username='u_del'")" 1
ok "  e libera o vínculo" "$(q "SELECT COUNT(*) FROM panel_customers WHERE username='u_del'")" 0
ok "viewer não exclui (403)" "$(t_post tview customers.php customers.php "action=delete&id=$BIA")" 403
ok "FK impede apagar cliente com pagamento direto no banco" "$(mariadb -S $T_SOCK radius -e "DELETE FROM panel_customers WHERE id=$ANA" 2>&1 | grep -c -i 'foreign key')" 1
ok "grants: painel não altera/apaga pagamentos" "$(mariadb -S $T_SOCK -h127.0.0.1 -P3470 -uradpanel -ptestdbpass radius -e "DELETE FROM panel_payments" 2>&1 | grep -c -i 'denied')" 1

# --- XSS
XN='<script>alert(1)</script>'
ok "XSS no nome (grava escapado, rejeita nada)" "$(t_post toper customers.php customers.php "action=create&name=%3Cscript%3Ealert(1)%3C%2Fscript%3E&email=x%40y.com&notes=%3Cscript%3Ealert(2)%3C%2Fscript%3E")" 302
XID=$(q "SELECT id FROM panel_customers WHERE name LIKE '%script%' LIMIT 1")
pay toper $XID pay "amount=5&method=pix&paid_at=$TODAY&notes=%3Cscript%3Ealert(3)%3C%2Fscript%3E%22%3E%3Cimg+src%3Dx+onerror%3Dalert(4)%3E" >/dev/null
for p in customers.php "customers.php?q=script" "customer.php?id=$XID" "customers.php?arch=1"; do
  b=$(t_get toper "$p")
  ok "XSS escapado em $p" "$(echo "$b" | grep -c -F '<script>alert')" 0
  ok "  sem <img onerror> cru em $p" "$(echo "$b" | grep -c -F '<img src=x')" 0
done
ok "  nome escapado visível" "$(t_get toper "customer.php?id=$XID" | grep -c -F '&lt;script&gt;alert(1)&lt;/script&gt;' | awk '{print ($1>0)}')" 1
ok "  observação do pagamento escapada" "$(t_get toper "customer.php?id=$XID" | grep -c -F '&lt;script&gt;alert(3)')" 1

# --- injeção SQL na busca / parâmetros
for s in "'" "%27%20OR%201%3D1--" "%3B%20DROP%20TABLE%20panel_customers"; do
  ok "busca com $s não quebra" "$(code toper "customers.php?q=$s")" 200
done
ok "tabela intacta" "$(q "SELECT COUNT(*) > 0 FROM panel_customers")" 1
ok "detalhe com id inválido = 404" "$(code toper 'customer.php?id=abc')" 404
ok "detalhe com id inexistente = 404" "$(code toper 'customer.php?id=999999')" 404

# --- paginação e busca
mariadb -S "$T_SOCK" radius -e "INSERT INTO panel_customers (name, phone) VALUES $(for i in $(seq 1 120); do printf "('Pg Cliente %03d','1190000%04d')," $i $i; done | sed 's/,$//')"
mariadb -S "$T_SOCK" radius -e "INSERT INTO panel_customers (name) VALUES ('100% Fibra')"
TOTAL=$(q "SELECT COUNT(*) FROM panel_customers WHERE archived=0")
rows() { grep -o 'Abrir</a>' | wc -l; }
ok "página 1 tem 50 linhas" "$(t_get toper customers.php | rows)" 50
ok "página 2 tem 50 linhas" "$(t_get toper 'customers.php?page=2' | rows)" 50
ok "última página tem o resto" "$(t_get toper "customers.php?page=$(( (TOTAL + 49) / 50 ))" | rows)" "$(( TOTAL - 50 * ((TOTAL + 49) / 50 - 1) ))"
ok "página além do fim = vazia, sem erro" "$(code toper 'customers.php?page=9999')" 200
ok "página absurda não quebra" "$(code toper 'customers.php?page=-5')" 200
ok "paginador presente" "$(t_get toper customers.php | grep -c 'class="pager"')" 1
ok "busca por nome (10 resultados)" "$(t_get toper 'customers.php?q=Pg+Cliente+05' | rows)" 10
ok "busca por telefone" "$(t_get toper 'customers.php?q=11900000007' | rows)" 1
ok "busca por usuário RADIUS" "$(t_get toper 'customers.php?q=u_bia' | rows)" 1
ok "busca por e-mail" "$(t_get toper 'customers.php?q=x%40y.com' | rows)" 1
ok "busca '%' literal casa só o nome com %" "$(t_get toper 'customers.php?q=%25' | rows)" 1
ok "busca '_' literal não vira curinga" "$(t_get toper 'customers.php?q=Pg_Cliente' | rows)" 0
ok "busca mantida no paginador" "$(t_get toper 'customers.php?q=Pg' | grep -c 'q=Pg&amp;arch=0&amp;page=2')" 1

# --- relatório financeiro (valores conferidos por SQL independente)
MONTH=$(TZ=America/Sao_Paulo date +%m/%Y)
SUMM=$(q "SELECT SUM(amount) FROM panel_payments WHERE DATE_FORMAT(paid_at,'%Y-%m')=DATE_FORMAT(CURDATE(),'%Y-%m')")
rep=$(t_get toper 'customers.php?tab=report')
ok "relatório: receita do mês corrente em R\$" "$(echo "$rep" | grep -c -F "<td>$MONTH</td><td class=\"money\">$(fmt_rs "$SUMM")</td>")" 1
ok "relatório: total 12 meses" "$(echo "$rep" | grep -c -F "<tr class=\"total\"><td>Total</td><td class=\"money\">$(fmt_rs "$(q "SELECT SUM(amount) FROM panel_payments")")</td>")" 1
PIX=$(q "SELECT SUM(amount) FROM panel_payments WHERE method='pix'")
ok "relatório: receita por forma (pix)" "$(echo "$rep" | grep -c -F "<tr><td>PIX</td><td class=\"money\">$(fmt_rs "$PIX")</td>")" 1
ok "relatório: 12 meses listados" "$(echo "$rep" | grep -c '<td class="barcell">')" 12
# pagamento antigo entra no mês certo e fora da janela não conta
q "INSERT INTO panel_payments (customer_id,amount,method,paid_at,created_by) VALUES ($BIA,100.10,'outro','$(d '-400 days')','t')"
q "INSERT INTO panel_payments (customer_id,amount,method,paid_at,created_by) VALUES ($BIA,0.10,'outro','$(d '-60 days')','t'),($BIA,0.20,'outro','$(d '-60 days')','t')"
M60=$(TZ=America/Sao_Paulo date -d "$TODAY -60 days" +%m/%Y)
rep=$(t_get toper 'customers.php?tab=report')
ok "relatório: 0,10+0,20 do mesmo mês somam R\$ 0,30" "$(echo "$rep" | grep -c -F "<td>$M60</td><td class=\"money\">R\$ 0,30</td>")" 1
ok "relatório: pagamento de 400 dias atrás fora da janela" "$(echo "$rep" | grep -c -F 'R$ 100,10')" 0
# inadimplentes
mkuser u_late "$(utc_end "$(d '-10 days')")"
t_post toper customers.php customers.php 'action=create&name=Atrasado&username=u_late' >/dev/null
q "INSERT INTO radusergroup (username,groupname,priority) VALUES ('u_late','basico',1)"
LATE=$(cust_id Atrasado)
ok "inadimplente aparece (N=0)" "$(t_get toper 'customers.php?tab=report' | grep -c "customer.php?id=$LATE\"")" 1
ok "  valor do plano R\$ 79,90" "$(t_get toper 'customers.php?tab=report' | grep -A6 "customer.php?id=$LATE\"" | grep -c 'R\$ 79,90')" 1
ok "N=5: ainda aparece (venceu há 10)" "$(t_get toper 'customers.php?tab=report&days=5' | grep -c "customer.php?id=$LATE\"")" 1
ok "N=30: não aparece" "$(t_get toper 'customers.php?tab=report&days=30' | grep -c "customer.php?id=$LATE\"")" 0
ok "cliente em dia não é inadimplente" "$(t_get toper 'customers.php?tab=report' | grep -c "customer.php?id=$ANA\"")" 0
ok "nenhum bloqueado ainda na lista" "$(t_get toper 'customers.php?tab=report' | grep -c 'tag bad')" 0
t_post toper users.php users.php 'action=block&username=u_late' >/dev/null
ok "  após bloquear, aparece com tag bloqueado (validade anterior)" "$(t_get toper 'customers.php?tab=report' | grep -A8 "customer.php?id=$LATE\"" | grep -c 'bloqueado')" 1
ok "days inválido não quebra" "$(code toper 'customers.php?tab=report&days=abc')" 200
ok "days negativo não quebra" "$(code toper 'customers.php?tab=report&days=-9')" 200

# --- detalhe: consumo do mês
q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,acctstarttime,acctsessiontime,acctinputoctets,acctoutputoctets) VALUES ('s1','u1','u_bia',NOW(),3661,1048576,2097152)"
q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,acctstarttime,acctsessiontime,acctinputoctets,acctoutputoctets) VALUES ('s2','u2','u_bia','2020-01-01 10:00:00',100,999999999,999999999)"
det=$(t_get toper "customer.php?id=$BIA")
ok "detalhe: consumo do mês (tempo)" "$(echo "$det" | grep -c '1h 01m 01s')" 1
ok "detalhe: consumo do mês (download 2,00 MB)" "$(echo "$det" | grep -c '2,00 MB')" 1
ok "detalhe: sessão antiga ignorada" "$(echo "$det" | grep -c -E '953,67 MB|GB')" 0
ok "detalhe viewer = 403 (dados pessoais; sem corpo)" "$(code tview "customer.php?id=$BIA")" 403
ok "  e o corpo da resposta 403 não traz dados do cliente" "$(t_get tview "customer.php?id=$BIA" | grep -c -E "name=\"amount\"|value=\"update\"|Bia")" 0
ok "detalhe operator: tem formulário de pagamento" "$(t_get toper "customer.php?id=$BIA" | grep -c 'name="amount"')" 1
ok "detalhe: botão renovar com o texto pedido" "$(t_get toper "customer.php?id=$BIA" | grep -c '>Registrar pagamento e renovar validade</button>')" 1
ok "detalhe: sugere preço do plano (79,90)" "$(t_get toper "customer.php?id=$ANA" | grep -c 'value="79,90"')" 1

# --- auditoria sem dados pessoais
ok "auditoria: criação/edição/pagamento/exclusão registradas" "$(q "SELECT COUNT(DISTINCT action) FROM panel_audit WHERE action IN ('customer.create','customer.update','customer.payment','customer.delete','customer.archive','customer.price')")" 6
ok "auditoria sem e-mail" "$(q "SELECT COUNT(*) FROM panel_audit WHERE CONCAT(action,target,IFNULL(detail,'')) LIKE '%@exemplo%' OR detail LIKE '%x@y.com%'")" 0
ok "auditoria sem telefone/documento/endereço/notas" "$(q "SELECT COUNT(*) FROM panel_audit WHERE CONCAT(target,IFNULL(detail,'')) REGEXP '99988|11999990000|DOC123456789|Rua Secreta|obs privada|segredo'")" 0
ok "auditoria sem nome de cliente" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action LIKE 'customer.%' AND CONCAT(target,IFNULL(detail,'')) REGEXP 'Ana|Silva|Bia|Souza'")" 0
ok "auditoria de edição lista só nomes de campos" "$(q "SELECT detail FROM panel_audit WHERE action='customer.update' AND target='customer#$BIA' ORDER BY id LIMIT 1")" '{"changed":["phone"]}'
ok "auditoria de pagamento tem id/valor em centavos" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='customer.payment' AND detail LIKE '%\"amount_cents\":7990%'")" 2

# --- CSP / HTML limpo
h=$(curl -s -D - -o /dev/null -b $T_DIR/jar-toper $T_WEB/customer.php?id=$ANA)
ok "CSP presente no detalhe" "$(echo "$h" | grep -ci "style-src 'self'")" 1
ok "no-store no detalhe" "$(echo "$h" | grep -ci 'cache-control: no-store')" 1
for who in toper tview tadmin; do
  for p in customers.php 'customers.php?tab=report' "customer.php?id=$ANA" "customer.php?id=$XID" 'customers.php?arch=1&q=a'; do
    b=$(t_get $who "$p")
    ok "HTML limpo ($who $p)" "$(echo "$b" | grep -c -E 'style="|onclick=|<script>[^<]|javascript:|data:|<style')" 0
    ok "  sem erro PHP ($who $p)" "$(echo "$b" | grep -ci -E 'fatal error|parse error|warning:|exception|notice:')" 0
  done
done
b=$(t_get tadmin 'customers.php?tab=prices')
ok "HTML limpo (prices)" "$(echo "$b" | grep -c -E 'style="|onclick=|<script>[^<]|javascript:|data:|<style')" 0
ok "prices lista o plano" "$(echo "$b" | grep -c 'basico')" 3
ok "prices mostra 79,90" "$(echo "$b" | grep -c 'value="79,90"')" 1
ok "log do PHP sem erros" "$(grep -ci -E 'fatal|warning|notice|deprecated' $T_DIR/php.log)" 0
ok "remover preço (admin)" "$(t_post tadmin customers.php customers.php 'action=price_delete&plan=basico')" 302
ok "  removido" "$(q "SELECT COUNT(*) FROM panel_plan_prices")" 0
ok "operator não remove preço (403)" "$(t_post toper customers.php customers.php 'action=price_delete&plan=basico')" 403
# --- PDOException não vaza texto SQL (gatilho força erro de banco no INSERT)
trig t_boom panel_customers "NEW.name='Boom'" 'segredo_sql_interno tabela panel_customers' 
ok "criação com erro de banco redireciona" "$(t_post toper customers.php customers.php 'action=create&name=Boom')" 302
fl=$(cflash)
ok "  mensagem genérica" "$(echo "$fl" | grep -c 'Erro ao salvar no banco')" 1
ok "  sem texto SQL na página" "$(echo "$fl" | grep -c -i -E 'segredo_sql|SQLSTATE|panel_customers|45000')" 0
ok "  nada gravado" "$(q "SELECT COUNT(*) FROM panel_customers WHERE name='Boom'")" 0
ok "  erro real foi para o log" "$(grep -c 'segredo_sql_interno' $T_DIR/php.log)" 1
q "DROP TRIGGER t_boom"
summary
