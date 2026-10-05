-- Portal do cliente: views e procedure com SQL SECURITY DEFINER.
-- Idempotente. Rodar como usuário privilegiado (o DEFINER passa a ser quem roda);
-- esse usuário precisa de SELECT/UPDATE em radcheck e SELECT em panel_user_meta.
-- Requer sql/panel.sql já aplicado (panel_user_meta).

-- Só a linha Password.Cleartext + a validade; nenhum outro atributo de radcheck é exposto.
CREATE OR REPLACE SQL SECURITY DEFINER VIEW portal_user_auth AS
  SELECT p.username AS username,
         p.value    AS password,
         (SELECT e.value FROM radcheck e
           WHERE e.username = p.username AND e.attribute = 'Expiration'
           ORDER BY e.id LIMIT 1) AS expiration
    FROM radcheck p
   WHERE p.attribute = 'Password.Cleartext';

DROP PROCEDURE IF EXISTS portal_set_password;

DELIMITER $$
-- Troca a senha do cliente somente se a senha atual confere (comparação binária).
-- Só toca a linha Password.Cleartext do usuário informado; nenhum outro atributo/usuário.
-- Recusa: nova < 8 caracteres, nova igual à atual, usuário bloqueado.
-- Devolve um result set com uma coluna "changed" (0 ou número de linhas alteradas).
CREATE PROCEDURE portal_set_password(IN u VARCHAR(64), IN old VARCHAR(253), IN new VARCHAR(253))
  SQL SECURITY DEFINER
BEGIN
  DECLARE n INT DEFAULT 0;
  IF u <> '' AND CHAR_LENGTH(new) >= 8 AND BINARY new <> BINARY old THEN
    UPDATE radcheck
       SET value = new
     WHERE BINARY username = BINARY u
       AND attribute = 'Password.Cleartext'
       AND BINARY value = BINARY old
       AND NOT EXISTS (SELECT 1 FROM panel_user_meta m WHERE m.username = u AND m.blocked = 1);
    SET n = ROW_COUNT();
  END IF;
  SELECT n AS changed;
END$$
DELIMITER ;
