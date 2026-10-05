-- Clientes e cobrança simples (sem gateway). Dados pessoais: acesso só por papel.
CREATE TABLE IF NOT EXISTS panel_customers (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name VARCHAR(120) NOT NULL,
  email VARCHAR(120) NOT NULL DEFAULT '',
  phone VARCHAR(30) NOT NULL DEFAULT '',
  document VARCHAR(30) NOT NULL DEFAULT '',
  address VARCHAR(255) NOT NULL DEFAULT '',
  notes VARCHAR(1000) NOT NULL DEFAULT '',
  username VARCHAR(64) DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY username (username),
  KEY name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

ALTER TABLE panel_customers
  ADD COLUMN IF NOT EXISTS archived TINYINT(1) NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS panel_plan_prices (
  groupname VARCHAR(64) NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  period_days SMALLINT UNSIGNED NOT NULL DEFAULT 30,
  PRIMARY KEY (groupname)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS panel_payments (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  customer_id INT UNSIGNED NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  method ENUM('dinheiro','pix','cartao','transferencia','outro') NOT NULL,
  paid_at DATE NOT NULL,
  period_from DATE DEFAULT NULL,
  period_to DATE DEFAULT NULL,
  notes VARCHAR(255) NOT NULL DEFAULT '',
  created_by VARCHAR(64) NOT NULL DEFAULT '-',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY customer_id (customer_id, period_to),
  KEY paid_at (paid_at),
  CONSTRAINT fk_payments_customer FOREIGN KEY (customer_id) REFERENCES panel_customers (id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
