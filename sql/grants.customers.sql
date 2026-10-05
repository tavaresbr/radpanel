-- Permissões mínimas do módulo de clientes. Pagamentos são somente-inserção (sem UPDATE/DELETE).
GRANT SELECT, INSERT, UPDATE, DELETE ON {{DB_NAME}}.panel_customers   TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON {{DB_NAME}}.panel_plan_prices TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT ON {{DB_NAME}}.panel_payments TO '{{DB_USER}}'@'localhost';
