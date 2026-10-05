-- Vouchers: lotes e vouchers. "Usado" é calculado a partir de radacct (primeira sessão contabilizada).
CREATE TABLE IF NOT EXISTS panel_voucher_batches (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  label VARCHAR(100) NOT NULL DEFAULT '',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by VARCHAR(64) NOT NULL DEFAULT '-',
  plan VARCHAR(64) NOT NULL DEFAULT '',
  qty INT UNSIGNED NOT NULL,
  expires_date DATE DEFAULT NULL,
  minutes_after_login INT UNSIGNED DEFAULT NULL,
  notes VARCHAR(255) NOT NULL DEFAULT '',
  PRIMARY KEY (id),
  KEY created_at (created_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS panel_vouchers (
  batch_id INT UNSIGNED NOT NULL,
  username VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (username),
  KEY batch_id (batch_id)
) ENGINE=InnoDB;
