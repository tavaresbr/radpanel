<?php
declare(strict_types=1);

/*
 * Vouchers: cada voucher é um usuário RADIUS (usuário = PREFIXO+CÓDIGO, senha = outro código
 * aleatório, de mesmo tamanho). Lote atômico: qualquer falha desfaz tudo.
 * Validade: data fixa da conta (opcional, Expiration) e/ou tempo de uso após o primeiro login
 * (opcional, control.Expire-After em segundos — sqlcounter expire_on_login; NÃO TESTADO sem radiusd).
 * "Usado" = existe registro em radacct para o usuário.
 */

const VOUCHER_MAX_QTY = 1000;

function voucher_validate(PDO $pdo, array $in): array
{
    $qty = filter_var($in['qty'] ?? '', FILTER_VALIDATE_INT);
    if ($qty === false || $qty < 1 || $qty > VOUCHER_MAX_QTY) {
        throw new RuntimeException('Quantidade deve ser de 1 a ' . VOUCHER_MAX_QTY . '.');
    }
    $prefix = strtoupper((string)($in['prefix'] ?? ''));
    if (!preg_match('/^[A-Z0-9]{0,6}$/', $prefix)) {
        throw new RuntimeException('Prefixo: até 6 caracteres, somente A-Z e 0-9.');
    }
    $len = filter_var($in['len'] ?? '', FILTER_VALIDATE_INT);
    if ($len === false || $len < 6 || $len > 12) {
        throw new RuntimeException('Tamanho do código deve ser de 6 a 12.');
    }
    $plan = (string)($in['plan'] ?? '');
    if (!valid_plan($plan) || !in_array($plan, ru_plans($pdo), true)) {
        throw new RuntimeException('Plano inexistente.');
    }
    $date = (string)($in['expires'] ?? '');
    if ($date !== '') {
        if (!valid_date($date)) {
            throw new RuntimeException('Data de validade inválida.');
        }
        if ($date < date('Y-m-d')) {
            throw new RuntimeException('A data de validade já passou.');
        }
    }
    $minRaw = (string)($in['minutes'] ?? '');
    $minutes = null;
    if ($minRaw !== '') {
        $minutes = filter_var($minRaw, FILTER_VALIDATE_INT);
        if ($minutes === false || $minutes < 1 || $minutes > 525600) {
            throw new RuntimeException('Tempo de uso deve ser de 1 a 525600 minutos.');
        }
    }
    $label = (string)($in['label'] ?? '');
    $notes = (string)($in['notes'] ?? '');
    if (mb_strlen($label) > 100 || mb_strlen($notes) > 255) {
        throw new RuntimeException('Rótulo (até 100) ou observação (até 255) longos demais.');
    }
    return [
        'qty' => $qty, 'prefix' => $prefix, 'len' => $len, 'plan' => $plan,
        'expires' => $date === '' ? null : $date, 'minutes' => $minutes,
        'label' => $label, 'notes' => $notes,
    ];
}

/** Gera o lote. Retorna [batch_id, [[usuario, senha], ...]]. Tudo ou nada. */
function voucher_generate(PDO $pdo, array $p, array $admin): array
{
    return ru_tx($pdo, function () use ($pdo, $p, $admin) {
        $pdo->prepare(
            'INSERT INTO panel_voucher_batches (label, created_by, plan, qty, expires_date, minutes_after_login, notes)
             VALUES (?, ?, ?, ?, ?, ?, ?)'
        )->execute([$p['label'], $admin['username'], $p['plan'], $p['qty'], $p['expires'], $p['minutes'], $p['notes']]);
        $batch = (int)$pdo->lastInsertId();

        $extra = [];
        if ($p['minutes'] !== null) {
            $extra['control.Expire-After'] = [':=', (string)($p['minutes'] * 60)];
        }
        $insV = $pdo->prepare('INSERT INTO panel_vouchers (batch_id, username) VALUES (?, ?)');
        $codes = [];
        $seen = [];
        for ($i = 0; $i < $p['qty']; $i++) {
            $user = '';
            for ($try = 0; $try < 20; $try++) {
                $cand = $p['prefix'] . random_code($p['len']);
                if (!isset($seen[$cand]) && !ru_exists($pdo, $cand)) {
                    $user = $cand;
                    break;
                }
            }
            if ($user === '') {
                throw new RuntimeException('Não foi possível gerar códigos únicos; aumente o tamanho do código.');
            }
            $seen[$user] = true;
            $pass = random_code($p['len']);
            ru_create($pdo, $user, $pass, $p['plan'], $p['expires'], $extra, false);
            $insV->execute([$batch, $user]);
            $codes[] = [$user, $pass];
        }
        return [$batch, $codes];
    });
}

/** Revoga o lote: remove os não usados (e os usados, se $withUsed). Retorna [removidos, mantidos usados]. */
function voucher_revoke(PDO $pdo, int $batch, bool $withUsed): array
{
    return ru_tx($pdo, function () use ($pdo, $batch, $withUsed) {
        $st = $pdo->prepare(
            'SELECT v.username, EXISTS(SELECT 1 FROM radacct a WHERE a.username = v.username) AS used
             FROM panel_vouchers v WHERE v.batch_id = ?'
        );
        $st->execute([$batch]);
        $rows = $st->fetchAll();
        $del = $pdo->prepare('DELETE FROM panel_vouchers WHERE username = ?');
        $removed = 0;
        $kept = 0;
        foreach ($rows as $r) {
            if ((int)$r['used'] === 1 && !$withUsed) {
                $kept++;
                continue;
            }
            if (ru_exists($pdo, $r['username'])) {
                ru_delete($pdo, $r['username'], false);
            }
            $del->execute([$r['username']]);
            $removed++;
        }
        return [$removed, $kept];
    });
}
