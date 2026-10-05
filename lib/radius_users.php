<?php
declare(strict_types=1);

/*
 * Única camada de escrita nas tabelas do RADIUS (radcheck/radreply/radusergroup...).
 * Todas as funções: validam, usam transação, registram auditoria e lançam
 * RuntimeException com mensagem amigável.
 */

/** Executa $fn dentro de uma transação (reaproveita a atual, se houver). */
function ru_tx(PDO $pdo, callable $fn)
{
    if ($pdo->inTransaction()) {
        return $fn();
    }
    $pdo->beginTransaction();
    try {
        $r = $fn();
        $pdo->commit();
        return $r;
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }
}

function ru_exists(PDO $pdo, string $user): bool
{
    $st = $pdo->prepare('SELECT 1 FROM radcheck WHERE username = ? LIMIT 1');
    $st->execute([$user]);
    return (bool)$st->fetchColumn();
}

function ru_require_exists(PDO $pdo, string $user): void
{
    if (!ru_exists($pdo, $user)) {
        throw new RuntimeException('Usuário não encontrado.');
    }
}

function ru_check_password(string $pass, int $min = 4): void
{
    $len = strlen($pass);
    if ($len < $min || $len > 128) {
        throw new RuntimeException("Senha deve ter de $min a 128 caracteres.");
    }
}

/** Define (ou remove, se $value for null/vazio) um item de checagem do usuário. */
function ru_set_check(PDO $pdo, string $user, string $attr, ?string $value, string $op = ':='): void
{
    ru_tx($pdo, function () use ($pdo, $user, $attr, $value, $op) {
        $pdo->prepare('DELETE FROM radcheck WHERE username = ? AND attribute = ?')->execute([$user, $attr]);
        if ($value !== null && $value !== '') {
            $pdo->prepare('INSERT INTO radcheck (username, attribute, op, value) VALUES (?, ?, ?, ?)')
                ->execute([$user, $attr, $op, $value]);
        }
    });
}

function ru_get_check(PDO $pdo, string $user, string $attr): ?string
{
    $st = $pdo->prepare('SELECT value FROM radcheck WHERE username = ? AND attribute = ? LIMIT 1');
    $st->execute([$user, $attr]);
    $v = $st->fetchColumn();
    return $v === false ? null : (string)$v;
}

/** Define o único plano do usuário (vazio remove). */
function ru_set_plan(PDO $pdo, string $user, string $plan): void
{
    if ($plan !== '' && !valid_plan($plan)) {
        throw new RuntimeException('Plano inválido.');
    }
    ru_tx($pdo, function () use ($pdo, $user, $plan) {
        $pdo->prepare('DELETE FROM radusergroup WHERE username = ?')->execute([$user]);
        if ($plan !== '') {
            $pdo->prepare('INSERT INTO radusergroup (username, groupname, priority) VALUES (?, ?, 1)')
                ->execute([$user, $plan]);
        }
    });
}

/**
 * Cria usuário. $expiresDate: 'Y-m-d' (fim do dia no fuso local) ou null.
 * $extra: itens de checagem adicionais [attr => [op, value]].
 */
function ru_create(
    PDO $pdo,
    string $user,
    string $pass,
    string $plan = '',
    ?string $expiresDate = null,
    array $extra = [],
    bool $audit = true
): void {
    if (!valid_username($user)) {
        throw new RuntimeException('Nome de usuário inválido (use letras, números e _ . @ -).');
    }
    ru_check_password($pass);
    $expires = ($expiresDate !== null && $expiresDate !== '') ? expiration_from_date($expiresDate) : null;

    $lock = 'radpanel_user_' . md5($user);
    $got = $pdo->prepare('SELECT GET_LOCK(?, 5)');
    $got->execute([$lock]);
    if ((int)$got->fetchColumn() !== 1) {
        throw new RuntimeException('Servidor ocupado, tente de novo.');
    }
    try {
        ru_tx($pdo, function () use ($pdo, $user, $pass, $plan, $expires, $extra) {
            if (ru_exists($pdo, $user)) {
                throw new RuntimeException('Usuário já existe.');
            }
            ru_set_check($pdo, $user, ATTR_PASSWORD, $pass);
            ru_set_check($pdo, $user, ATTR_EXPIRATION, $expires);
            foreach ($extra as $attr => [$op, $value]) {
                ru_set_check($pdo, $user, (string)$attr, (string)$value, (string)$op);
            }
            ru_set_plan($pdo, $user, $plan);
        });
    } finally {
        $rel = $pdo->prepare('SELECT RELEASE_LOCK(?)');
        $rel->execute([$lock]);
    }
    if ($audit) {
        audit('user.create', $user, ['plan' => $plan, 'expires' => $expiresDate]);
    }
}

function ru_set_password(PDO $pdo, string $user, string $pass, int $min = 4): void
{
    ru_check_password($pass, $min);
    ru_tx($pdo, function () use ($pdo, $user, $pass) {
        ru_require_exists($pdo, $user);
        ru_set_check($pdo, $user, ATTR_PASSWORD, $pass);
    });
    audit('user.password', $user);
}

function ru_set_plan_audited(PDO $pdo, string $user, string $plan): void
{
    ru_tx($pdo, function () use ($pdo, $user, $plan) {
        ru_require_exists($pdo, $user);
        ru_set_plan($pdo, $user, $plan);
    });
    audit('user.plan', $user, ['plan' => $plan]);
}

/** Devolve true se o usuário está bloqueado e a validade só vale quando for desbloqueado. */
function ru_set_expiration(PDO $pdo, string $user, string $date): bool
{
    $value = $date === '' ? null : expiration_from_date($date);
    $blocked = ru_tx($pdo, function () use ($pdo, $user, $value) {
        ru_require_exists($pdo, $user);
        // Bloqueado = Expiration no passado. Mexer na validade NÃO pode desbloquear: guarda o valor
        // novo para ser restaurado quando alguém desbloquear.
        $st = $pdo->prepare('SELECT blocked FROM panel_user_meta WHERE username = ? FOR UPDATE');
        $st->execute([$user]);
        if ((int)$st->fetchColumn() === 1) {
            $pdo->prepare('UPDATE panel_user_meta SET prev_expiration = ? WHERE username = ?')->execute([$value, $user]);
            return true;
        }
        ru_set_check($pdo, $user, ATTR_EXPIRATION, $value);
        return false;
    });
    audit('user.expires', $user, ['date' => $date, 'blocked' => $blocked]);
    return $blocked;
}

function ru_is_blocked(PDO $pdo, string $user): bool
{
    $st = $pdo->prepare('SELECT blocked FROM panel_user_meta WHERE username = ?');
    $st->execute([$user]);
    return (bool)$st->fetchColumn();
}

function ru_block(PDO $pdo, string $user): void
{
    $changed = ru_tx($pdo, function () use ($pdo, $user) {
        ru_require_exists($pdo, $user);
        if (ru_is_blocked($pdo, $user)) {
            return false; // já bloqueado: não sobrescreve a validade anterior
        }
        $prev = ru_get_check($pdo, $user, ATTR_EXPIRATION);
        $pdo->prepare(
            'INSERT INTO panel_user_meta (username, blocked, prev_expiration) VALUES (?, 1, ?)
             ON DUPLICATE KEY UPDATE blocked = 1, prev_expiration = VALUES(prev_expiration)'
        )->execute([$user, $prev]);
        ru_set_check($pdo, $user, ATTR_EXPIRATION, BLOCK_DATE_UTC);
        return true;
    });
    if ($changed) {
        audit('user.block', $user);
    }
}

function ru_unblock(PDO $pdo, string $user): void
{
    $changed = ru_tx($pdo, function () use ($pdo, $user) {
        ru_require_exists($pdo, $user);
        if (!ru_is_blocked($pdo, $user)) {
            return false;
        }
        $st = $pdo->prepare('SELECT prev_expiration FROM panel_user_meta WHERE username = ?');
        $st->execute([$user]);
        $prev = $st->fetchColumn();
        ru_set_check($pdo, $user, ATTR_EXPIRATION, ($prev === false || $prev === null) ? null : (string)$prev);
        $pdo->prepare('UPDATE panel_user_meta SET blocked = 0, prev_expiration = NULL WHERE username = ?')
            ->execute([$user]);
        return true;
    });
    if ($changed) {
        audit('user.unblock', $user);
    }
}

/** Remove o usuário das tabelas de configuração (mantém o histórico em radacct). */
function ru_delete(PDO $pdo, string $user, bool $audit = true): void
{
    ru_tx($pdo, function () use ($pdo, $user) {
        ru_require_exists($pdo, $user);
        foreach (['radcheck', 'radreply', 'radusergroup', 'panel_user_meta', 'panel_vouchers'] as $t) {
            $pdo->prepare("DELETE FROM $t WHERE username = ?")->execute([$user]);
        }
    });
    if ($audit) {
        audit('user.delete', $user);
    }
}

/** Planos existentes (grupos com alguma linha de check/reply). */
function ru_plans(PDO $pdo): array
{
    return $pdo->query(
        'SELECT groupname FROM (SELECT groupname FROM radgroupreply UNION SELECT groupname FROM radgroupcheck) p
         ORDER BY groupname'
    )->fetchAll(PDO::FETCH_COLUMN);
}
