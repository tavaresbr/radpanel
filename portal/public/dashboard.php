<?php
declare(strict_types=1);
require __DIR__ . '/../lib/portal.php';

$cust = require_customer();
$user = $cust['username'];   // sempre da sessão, nunca de parâmetro

try {
    $pdo = db();

    $st = $pdo->prepare('SELECT blocked FROM panel_user_meta WHERE username = ?');
    $st->execute([$user]);
    $blocked = (int)($st->fetchColumn() ?: 0) === 1;

    $st = $pdo->prepare('SELECT groupname FROM radusergroup WHERE username = ? ORDER BY priority, groupname LIMIT 1');
    $st->execute([$user]);
    $plan = $st->fetchColumn() ?: null;
    $rate = null;
    if ($plan !== null) {
        $st = $pdo->prepare('SELECT value FROM radgroupreply WHERE groupname = ? AND attribute = ? ORDER BY id LIMIT 1');
        $st->execute([$plan, ATTR_RATE]);
        $rate = $st->fetchColumn() ?: null;
    }

    $exp = $cust['expiration'];
    $ets = expiration_ts($exp);
    $expired = !$blocked && $ets !== null && $ets < time();

    $usage = static function (string $since) use ($pdo, $user): array {
        $st = $pdo->prepare(
            'SELECT COALESCE(SUM(acctinputoctets),0) AS up, COALESCE(SUM(acctoutputoctets),0) AS down,
                    COALESCE(SUM(acctsessiontime),0) AS secs
               FROM radacct WHERE username = ? AND acctstarttime >= ?'
        );
        $st->execute([$user, $since]);
        return $st->fetch();
    };
    $month = $usage(date('Y-m-01 00:00:00'));
    $today = $usage(date('Y-m-d 00:00:00'));

    $st = $pdo->prepare(
        'SELECT acctstarttime, acctstoptime, acctsessiontime, acctinputoctets, acctoutputoctets
           FROM radacct WHERE username = ? ORDER BY acctstarttime DESC, radacctid DESC LIMIT 10'
    );
    $st->execute([$user]);
    $sessions = $st->fetchAll();
} catch (Throwable $e) {
    log_exception($e, 'portal.dashboard');
    portal_header('Minha conta');
    echo '<div class="flash err">Erro interno. Tente novamente mais tarde.</div>';
    portal_footer();
    exit;
}

$fd = static fn(?string $d): string => $d ? date('d/m/Y H:i', (int)strtotime($d)) : '-';

portal_header('Minha conta');
?>
<h1>Olá, <?= h($user) ?></h1>

<?php if ($blocked): ?>
<div class="flash err">Conta bloqueada. Procure o atendimento.</div>
<?php elseif ($expired): ?>
<div class="flash err">Sua conta expirou em <?= h(fmt_expiration($exp)) ?>. Procure o atendimento para renovar.</div>
<?php endif; ?>

<div class="card">
<table>
<tr><th>Estado</th><td>
<?php if ($blocked): ?><span class="tag bad">Bloqueado</span>
<?php elseif ($expired): ?><span class="tag bad">Expirado</span>
<?php else: ?><span class="tag good">Ativo</span><?php endif; ?></td></tr>
<tr><th>Plano</th><td><?= $plan !== null ? h((string)$plan) : '<span class="muted">-</span>' ?></td></tr>
<?php if ($rate !== null): ?><tr><th>Velocidade (subida/descida)</th><td><?= h((string)$rate) ?></td></tr><?php endif; ?>
<tr><th>Validade</th><td><?= $blocked ? '<span class="muted">-</span>' : h(fmt_expiration($exp)) ?></td></tr>
</table>
</div>

<div class="grid">
<div class="card stat"><span>Consumo no mês</span><b><?= h(fmt_bytes((int)$month['up'] + (int)$month['down'])) ?></b>
<span><?= h(fmt_secs((int)$month['secs'])) ?> conectado</span></div>
<div class="card stat"><span>Consumo hoje</span><b><?= h(fmt_bytes((int)$today['up'] + (int)$today['down'])) ?></b>
<span><?= h(fmt_secs((int)$today['secs'])) ?> conectado</span></div>
</div>

<h2>Últimas conexões</h2>
<div class="card scroll">
<?php if (!$sessions): ?><p class="muted">Nenhuma conexão registrada.</p><?php else: ?>
<table><tr><th>Início</th><th>Fim</th><th>Duração</th><th>Download</th><th>Upload</th></tr>
<?php foreach ($sessions as $s): ?>
<tr><td class="nowrap"><?= h($fd($s['acctstarttime'])) ?></td>
<td class="nowrap"><?= $s['acctstoptime'] ? h($fd($s['acctstoptime'])) : 'em andamento' ?></td>
<td class="nowrap"><?= h(fmt_secs((int)$s['acctsessiontime'])) ?></td>
<td class="nowrap"><?= h(fmt_bytes((int)$s['acctoutputoctets'])) ?></td>
<td class="nowrap"><?= h(fmt_bytes((int)$s['acctinputoctets'])) ?></td></tr>
<?php endforeach; ?></table>
<?php endif; ?>
</div>
<?php if (!$blocked): ?><p><a href="password.php">Alterar senha</a></p><?php endif; ?>
<p class="muted">Esqueceu a senha ou precisa de ajuda? Procure o atendimento.</p>
<?php portal_footer();
