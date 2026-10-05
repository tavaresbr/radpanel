-- Permissões do usuário do painel. {{DB_NAME}} e {{DB_USER}} são substituídos pelo instalador.
-- Cada módulo novo acrescenta o seu arquivo sql/grants.<modulo>.sql com o mesmo formato.
-- Privilégio mínimo: só o que o código usa (a escrita nas tabelas do RADIUS é DELETE+INSERT, sem UPDATE).
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.radcheck      TO '{{DB_USER}}'@'localhost';
GRANT SELECT, DELETE         ON {{DB_NAME}}.radreply      TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.radgroupcheck TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.radgroupreply TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.radusergroup  TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.nas           TO '{{DB_USER}}'@'localhost';
GRANT SELECT ON {{DB_NAME}}.radacct TO '{{DB_USER}}'@'localhost';
-- radpostauth.pass guarda a senha DIGITADA (inclusive as erradas): nunca conceder a coluna.
GRANT SELECT (id, username, reply, authdate) ON {{DB_NAME}}.radpostauth TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON {{DB_NAME}}.panel_admins         TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.panel_login_attempts TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON {{DB_NAME}}.panel_user_meta      TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT ON {{DB_NAME}}.panel_audit TO '{{DB_USER}}'@'localhost';
