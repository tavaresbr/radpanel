-- Esquema do painel. Idempotente: pode rodar de novo em upgrades.

CREATE TABLE IF NOT EXISTS panel_admins (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  username VARCHAR(64) NOT NULL,
  pass_hash VARCHAR(255) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY username (username)
) ENGINE=InnoDB;

ALTER TABLE panel_admins
  ADD COLUMN IF NOT EXISTS role ENUM('viewer','operator','admin') NOT NULL DEFAULT 'admin';

CREATE TABLE IF NOT EXISTS panel_login_attempts (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  ip VARCHAR(45) NOT NULL,
  username VARCHAR(64) NOT NULL,
  attempted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ip (ip),
  KEY username (username),
  KEY attempted_at (attempted_at)
) ENGINE=InnoDB;

ALTER TABLE panel_login_attempts
  ADD COLUMN IF NOT EXISTS realm VARCHAR(16) NOT NULL DEFAULT 'admin';

CREATE TABLE IF NOT EXISTS panel_user_meta (
  username VARCHAR(64) NOT NULL,
  blocked TINYINT(1) NOT NULL DEFAULT 0,
  prev_expiration VARCHAR(40) DEFAULT NULL,
  PRIMARY KEY (username)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS panel_audit (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ts TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  admin_id INT UNSIGNED DEFAULT NULL,
  admin_name VARCHAR(64) NOT NULL DEFAULT '-',
  ip VARCHAR(45) NOT NULL DEFAULT '',
  action VARCHAR(64) NOT NULL,
  target VARCHAR(128) NOT NULL DEFAULT '',
  detail VARCHAR(2000) DEFAULT NULL,
  PRIMARY KEY (id),
  KEY ts (ts),
  KEY action (action),
  KEY target (target)
) ENGINE=InnoDB;
