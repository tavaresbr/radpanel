-- Permissões mínimas do módulo de vouchers (lotes nunca são alterados depois de criados).
GRANT SELECT, INSERT ON {{DB_NAME}}.panel_voucher_batches TO '{{DB_USER}}'@'localhost';
GRANT SELECT, INSERT, DELETE ON {{DB_NAME}}.panel_vouchers TO '{{DB_USER}}'@'localhost';
