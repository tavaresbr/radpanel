# RadPanel

Painel de administração web (PHP 8.3 + Apache + MariaDB) para um hotspot que autentica no **FreeRADIUS 4.0**.
Usuários, vouchers em lote, planos, limites de uso (tempo, franquia, MAC, sessões simultâneas), sessões e consumo,
relatórios com CSV, clientes e cobrança manual, equipamentos (NAS), auditoria, backup e um portal de autoatendimento do cliente.

**Guia completo (instalação, limites, riscos e o que não foi testado): [LEIA-ME.md](LEIA-ME.md).**

```bash
sudo bash install-panel.sh        # Ubuntu 24.04; pode ser repetido sem perder dados
bash tests/run_all.sh             # testes automatizados (precisam de MariaDB e, em parte, de um radiusd compilado)
```

## Leia antes de usar em produção

- O fork do FreeRADIUS 4.0 usado no desenvolvimento (commit `a7588cf`) tem um bug que impede a leitura de campos de data do SQL:
  usuário com validade (`Expiration`) recebe `Access-Reject`. O patch de uma linha está em
  [`server-config/fork-fix-expiration.patch`](server-config/fork-fix-expiration.patch); veja a seção "Bug do fork" do guia.
- Os limites de uso só valem depois de `bin/apply-server-config.sh` (faz backup, valida com `radiusd -CX` e restaura se falhar).
- Não foi testado com equipamentos reais (MikroTik/UniFi), nem com HTTPS/Let's Encrypt em produção.

## Origem do código (divulgação de IA)

Este código foi **gerado com apoio de IA (Claude Code)**, com agentes que escreveram módulos em paralelo, revisão de segurança
independente e testes automatizados por módulo (1320 testes, 0 falhas na última execução completa). Ele **não** é uma contribuição
ao projeto FreeRADIUS e não deve ser enviado a ele como tal. Quem for usar deve revisar o código e testar no seu ambiente.

## Licença

GPL-2.0 (veja [LICENSE](LICENSE)).
