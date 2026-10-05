RadPanel - limites no FreeRADIUS 4.0
====================================

Copie (bin/apply-server-config.sh faz isto sozinho, com backup e validacao):

  mods-available/panel_counters                      -> raddb/mods-available/
  policy.d/panel_limits                              -> raddb/policy.d/
  mods-config/sql/counter/mysql/panel_*.conf (6)     -> raddb/mods-config/sql/counter/mysql/
  ln -s ../mods-available/panel_counters raddb/mods-enabled/panel_counters

Insercao manual no site default (raddb/sites-available/default), secao "recv Access-Request":

  recv Access-Request {
      filter_username
      chap
      mschap
      digest
      eap {
          ok = return
          updated = return
      }
      files
      # BEGIN radpanel (prepare)
      panel_limits_prepare        # normaliza Calling-Station-Id ANTES do sql
      # END radpanel
      -sql
      -ldap
      expiration
      # BEGIN radpanel
      panel_limits                # limites: DEPOIS do sql (precisa do control carregado), antes do pap
      # END radpanel
      pap
  }

Chaves gravadas pelo painel (radcheck do usuario / radgroupcheck do plano):

  control.Max-Daily-Session, control.Max-Monthly-Session, control.Max-All-Session   (segundos)
  control.Max-Quota-Daily-Octets | Max-Quota-Monthly-Octets | Max-Quota-Total-Octets (bytes, um periodo)
  control.Simultaneous-Use                                                          (inteiro)
  Calling-Station-Id == AA-BB-CC-DD-EE-FF                                           (so usuario)

Usuario usa ":=", plano usa "=" (define somente se ainda nao existir; assim o limite do usuario,
lido primeiro pelo rlm_sql, prevalece - um ":=" do grupo o sobrescreveria).

Limitacoes: Total-Limit/Total-Limit-Gigawords so valem em MikroTik; EAP que retorna antes do sql
(PEAP/TTLS externo) exige o mesmo bloco no site inner-tunnel.
