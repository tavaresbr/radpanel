# RadPanel — painel de administração para FreeRADIUS 4.0

Painel web (PHP 8.3 + Apache + MariaDB) para gerenciar um hotspot que autentica no FreeRADIUS 4.0.
Criado para o servidor `150.230.64.46` (Ubuntu 24.04, ARM). **Antes de usar em produção, leia a seção
"Bug do fork" e "O que NÃO foi testado".**

## O que tem

| Área | O que faz | Papel mínimo |
|---|---|---|
| Início | contadores, consumo de hoje, últimas rejeições | viewer |
| Usuários | criar, trocar senha, plano, validade, bloquear, excluir, **limites** (tempo, franquia, MAC, simultâneas) | viewer vê, operator edita |
| Vouchers | gerar lote (até 1000), imprimir (códigos aparecem **uma vez**), revogar lote | operator |
| Planos | velocidade (MikroTik), tempo de sessão, ociosidade, interim, limites do plano | viewer vê, admin edita |
| Sessões | online agora, histórico, consumo por usuário, **derrubar sessão** (Disconnect) | viewer vê, operator derruba |
| Relatórios | gráficos e tabelas (dia, mês, top, NAS, plano, rejeições, hora) e **CSV** | viewer vê, operator exporta |
| Clientes | cadastro, pagamentos manuais, "pagar e renovar", relatório financeiro, inadimplentes | operator |
| Equipamentos | cadastro de NAS, gera `clients.d/*.conf`, botão "Aplicar (reiniciar serviço)" | admin |
| Ferramentas | gerador de script MikroTik, estado do backup | admin |
| VPN WireGuard | túnel para roteadores com IP dinâmico (peers, script do MikroTik, cadastro do equipamento) | admin |
| Administradores | criar/rebaixar/excluir admins, papéis, redefinir senha | admin |
| Auditoria | quem fez o quê (sem senhas) | admin |
| **Portal do cliente** | cliente vê plano, validade, consumo e troca a própria senha | (domínio separado) |

## Instalar

No seu PC (PowerShell), copie o pacote e conecte (ajuste os caminhos):

```powershell
scp -i "C:\caminho\da\sua-chave" "C:\Users\adm\Downloads\radpanel-v2.tar.gz" ubuntu@150.230.64.46:~
ssh -i "C:\caminho\da\sua-chave" ubuntu@150.230.64.46
```

No servidor:

```bash
tar xzf radpanel-v2.tar.gz
sudo bash radpanel/install-panel.sh
```

O instalador pergunta: domínio do painel (vazio = só acesso local por túnel SSH), domínio do portal do cliente
(opcional, **precisa ser outro nome**), e-mail do Let's Encrypt, nome do administrador e se quer o backup diário.
Pode rodar de novo sem perder nada (mantém `config.php`, senha do banco e administradores).

Antes: se usar domínio, ele precisa apontar (registro A) para o IP do servidor, e as portas **TCP 80 e 443**
precisam estar liberadas na Security List da Oracle.

O instalador instala o `php-mbstring` e confere as extensões PHP; no fim testa `login.php` localmente e, se der erro 500,
mostra o fim do log. Para diagnosticar na mão: `sudo tail -n 25 /var/log/apache2/radpanel-error.log`
(`mb_substr() indefinida` = falta `sudo apt install -y php-mbstring` e `sudo systemctl restart apache2`).

Sem domínio: `ssh -L 8080:127.0.0.1:8080 -i SUA_CHAVE ubuntu@150.230.64.46` e abra `http://127.0.0.1:8080/`.

Onde fica: código em `/opt/radpanel` (fora da pasta web), configuração em `/etc/radpanel/` (modo 640),
backups em `/var/backups/radpanel`.

## Ativar um equipamento (assistente)

Menu **Ativar equipamento**: leva um MikroTik, passo a passo, até autenticar neste servidor. Em cada etapa o painel confere o estado real e só libera a próxima:
1. túnel WireGuard (chave pública do roteador; só para IP dinâmico) · 2. conexão do túnel (confere o último contato) · 3. cadastro e segredo (sugerido, aleatório) ·
4. aplicar no servidor (reinicia o FreeRADIUS, validado antes) · 5. script do RADIUS para colar no roteador · 6. teste: "ativo" quando o roteador registra a primeira sessão.
Recriou a interface `wg-radius` no MikroTik (a chave pública mudou)? Na etapa 1 use **Trocar a chave**: o IP do túnel continua o mesmo.
Para IP fixo as etapas 1 e 2 não existem. Os equipamentos em andamento aparecem na tela inicial do assistente, com a etapa em que pararam.
Observação: "ativo" depende de uma sessão com contabilidade (accounting) ligada, então conecte um aparelho ao hotspot e entre com um usuário do painel.

## Atualizar (depois que há versão nova no git)

```bash
sudo /opt/radpanel/bin/update.sh
```

Busca a versão nova no git (como o dono do clone, nunca como root; recusa se houver alterações locais ou histórico diferente), roda o instalador
**sem perguntas** (usa as respostas salvas em `/etc/radpanel/install.env`) e mantém configuração, banco, administradores e certificado.
Depois aperte **Ctrl+F5** no navegador para recarregar CSS e JavaScript. `FORCE_APT=1` reinstala também os pacotes do sistema.
A primeira vez (que grava as respostas) ainda é `cd ~/radpanel && git pull && sudo bash install-panel.sh`; para o instalador perguntar de novo: `FRESH=1`.
Não há atualização automática: você decide quando aplicar.

## Roteador com IP dinâmico (túnel WireGuard)

O FreeRADIUS só aceita o equipamento pelo IP cadastrado; se o IP do roteador muda, o hotspot para de autenticar (DDNS não ajuda: o
FreeRADIUS resolve nomes só ao iniciar). A solução é um túnel WireGuard: o MikroTik (RouterOS 7.1 ou mais novo) liga até o servidor e
ganha um IP fixo interno `10.99.0.N`; esse é o IP que vai em Equipamentos. RADIUS, accounting e Disconnect passam dentro do túnel.

1. No servidor (uma vez): `sudo bash /opt/radpanel/bin/wg-setup.sh` (instala o WireGuard, cria `wg0` em `10.99.0.1`, abre UDP 51820 e deixa
   1812/1813 só dentro do túnel).
2. Na Security List da Oracle: libere **UDP 51820** (as portas 1812/1813 deixam de precisar ser públicas).
3. No painel, menu **VPN WireGuard**: siga os passos 1 e 2 da tela (o MikroTik gera a própria chave; só a chave **pública** vem para o painel).
   Cole no MikroTik o script gerado, depois use **Cadastrar** na lista (cria o equipamento com o IP do túnel) e clique em **Aplicar** em Equipamentos.
4. Em **Ferramentas**, gere o script do RADIUS com servidor `10.99.0.1` e "IP do túnel" `10.99.0.N`.

Não testado em equipamento real: o túnel com MikroTik, `wg-quick` no Ubuntu do servidor e as regras iptables (os testes usam `wg` e `sudo` falsos).
Se o firewall do MikroTik bloqueia entrada, o script traz (comentada) a regra para o servidor poder derrubar sessões.

## Limites de uso (franquia, tempo, MAC, simultâneas)

O painel só **grava** os limites. Quem os faz valer é o FreeRADIUS, e só depois de aplicar a configuração do painel:

```bash
sudo SERVICE=freeradius /opt/radpanel/bin/apply-server-config.sh --restart
```

O script faz backup datado, copia os arquivos, valida com `radiusd -CX` e **restaura o backup se falhar**.
**Não grave limites antes disso**: o servidor rejeita o usuário que tiver um limite que ele não conhece.

Observações: vale para PAP/CHAP (hotspot). EAP/PEAP precisa do mesmo bloco no site `inner-tunnel`.
O "dia" e o "mês" dos contadores usam o fuso do sistema; deixe o servidor e o `timezone` do `config.php` iguais.
Franquia de dados e `Total-Limit` só valem em MikroTik.

## Bug do fork (validade de usuários) — IMPORTANTE

O fork em `tavaresbr/freeradius-server` (commit `a7588cf`, 4.0 "DEVELOPER BUILD") **não consegue ler campos de data
do SQL**. Qualquer usuário com `Expiration` no banco recebe `Access-Reject` mesmo com a senha certa (log:
`Data read from SQL cannot be parsed`). Isso atinge validade de usuário, vouchers com data, "pagar e renovar" e o
ciclo bloquear → desbloquear de quem tem validade. **Usuários sem validade funcionam.**

Correção de uma linha (em `src/lib/util/value.c`), testada compilando o fork num ambiente de teste (com ela, o roteiro de
validação do servidor passou 39 de 39; sem ela, 25 de 39). No servidor, dentro do seu clone do fork:

```bash
cd ~/freeradius-server
patch -p1 --dry-run < ~/radpanel/server-config/fork-fix-expiration.patch   # confira que aplica limpo
patch -p1 < ~/radpanel/server-config/fork-fix-expiration.patch
make -j4 && sudo make install && sudo systemctl restart freeradius
```

Teste: crie um usuário com validade futura no painel e rode `radtest USUARIO SENHA 127.0.0.1 0 SEGREDO`:
deve dar `Access-Accept`; com validade no passado, `Access-Reject`.

Se preferir não alterar o servidor, **não use datas de validade** (nem vouchers com data, nem renovação).
Isto é um problema do fork, não do painel; considere reportar ao projeto FreeRADIUS. O repositório original
**não foi modificado** por este trabalho.

## Segurança — o que saber

- Papéis (viewer/operator/admin) são checados no servidor em cada ação; todo POST tem token CSRF; senhas de admin em argon2id;
  limite de tentativas de login; sessão invalida ao trocar senha/papel; páginas com `no-store`; CSP estrita (sem script/estilo inline).
- O portal do cliente usa **outro usuário MySQL** com privilégio mínimo e outra sessão.
- **Risco aceito no portal:** para conferir a senha do cliente ele lê as senhas em texto claro por uma *view*
  (o FreeRADIUS precisa delas em texto para CHAP). Uma falha de injeção SQL no portal exporia as senhas; por isso só há
  consultas preparadas e o acesso é restrito a essa view.
- O painel (usuário `www-data`) só tem **passagem** (ACL `--x`) na pasta `raddb` do FreeRADIUS e grava somente em `raddb/clients.d`; não lê certificados, `clients.conf` nem `mods-enabled/sql`. O instalador confere isso (`bin/raddb-access.sh`).
- Segredos de equipamentos ficam ocultos; revelar exige POST, é só admin e fica na auditoria.
- Troque o segredo `testing123` do `clients.conf` e apague o usuário `teste` antes de produção.
- Backup: `sudo /opt/radpanel/bin/backup.sh` (cron diário 03:17, mantém 14, arquivos 600 root).

## Limites conhecidos (revisão de segurança independente)

Uma revisão independente do código não achou injeção SQL, XSS, injeção de comando nem quebra da política de conteúdo.
Corrigido por ela: validade de usuário bloqueado desbloqueava na prática; redes largas (`0.0.0.0/0`) e segredos com `${`/`%{`
em equipamentos; cadastro de NAS apagado sem remover o arquivo de cliente; grants excessivos (o painel não lê mais a senha
digitada em `radpostauth` nem faz `UPDATE` nas tabelas do RADIUS); validação do reinício agora roda como `freerad`, não root.
O que ficou **de propósito** (decida se aceita):

- **Bloquear/excluir/revogar NÃO derruba a sessão que já está online.** Ela cai quando o NAS reautentica ou o tempo de sessão
  acaba. Para derrubar na hora use *Sessões → Derrubar* (precisa de Disconnect habilitado no NAS).
- **Força bruta distribuída:** o limite de login é por IP (IPv6 agrupado por /64) + usuário e por IP. Não há trava global por usuário
  porque ela permitiria a qualquer pessoa trancar o administrador para fora. Use senha longa e, se puder, restrinja o painel
  por IP na Security List.
- **Portal lê todas as senhas por uma view** (necessário para conferir a senha do cliente). Mantenha a credencial do portal protegida.
  Se houver execução de código no portal, o `config.php` do painel (mesmo usuário Unix `www-data`) também fica ao alcance.
- **`require_message_authenticator = auto`** nos clientes gerados: aceita NAS que não enviam Message-Authenticator (comum em
  MikroTik antigo) mas protege menos contra o ataque Blast-RADIUS; use `yes` se todos os seus equipamentos enviarem.
- O operador pode atribuir qualquer plano e redefinir qualquer senha de usuário do hotspot (por desenho); visualizador vê os nomes
  de usuário (metade da credencial dos vouchers) na lista de usuários.
- Códigos de voucher aparecem **uma vez** (ficam na sessão até serem vistos); recarregar a página de impressão antes de imprimir os perde:
  gere de novo o lote.

## O que NÃO foi testado (honestamente)

Testado com Apache real, MariaDB 10.11 e um `radiusd` 4.0 compilado do seu fork em ambiente de teste (centenas de
testes automatizados por módulo). **Não** foi possível testar:

- **MikroTik/UniFi reais:** script RouterOS gerado, efeito de `Total-Limit`, Disconnect/CoA (`radclient` real contra um NAS;
  o NAS precisa aceitar Disconnect do IP do servidor na UDP 3799).
- **Let's Encrypt/HTTPS e o vhost do portal** em produção (o instalador foi rodado só com `SKIP_CERTBOT`).
- **`--restart`** do script de limites e `systemctl restart freeradius` pelo painel (o `sudo` restrito foi verificado).
- **EAP/PEAP**, concorrência real de vários operadores, navegador real (aparência, impressão dos vouchers), Excel com o CSV.
- Desempenho com milhões de linhas em `radacct`.

## Não implementado

Pagamento online (gateways), recuperação de senha por e-mail/SMS, mapa de hotspots, pools de IP, estorno de pagamento
(pagamentos são só de acréscimo, de propósito), franquia de dados por sessão no CoA.

## Estrutura

`public/` páginas do painel · `portal/` portal do cliente · `lib/` código compartilhado · `sql/` esquema e permissões ·
`server-config/` arquivos para o FreeRADIUS (contadores, política de limites, sudoers, patch) · `bin/` scripts (admin, backup,
aplicar configuração, reinício validado) · `tests/` testes automatizados (`bash tests/run_all.sh`).
