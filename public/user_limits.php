<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/limits.php';
$admin = require_role('viewer');
$canWrite = role_at_least($admin, 'operator');
$pdo = db();

$user = trim((string)($_POST['username'] ?? $_GET['u'] ?? ''));
if (!valid_username($user)) {
    flash('Usuário inválido.', 'err');
    redirect('users.php');
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    require_role('operator');
    csrf_check();
    try {
        if (post('action') !== 'save') {
            throw new RuntimeException('Ação desconhecida.');
        }
        $lim = lim_from_input($_POST, true);
        lim_save_user($pdo, $user, $lim);
        audit('user.limits', $user, lim_audit_detail($lim));
        flash('Limites salvos.');
    } catch (Throwable $e) {
        flash(friendly_error($e, 'user_limits'), 'err');
    }
    redirect('user_limits.php?' . http_build_query(['u' => $user]));
}

if (!ru_exists($pdo, $user)) {
    flash('Usuário não encontrado.', 'err');
    redirect('users.php');
}

$lim = lim_read_user($pdo, $user);
$st = $pdo->prepare('SELECT groupname FROM radusergroup WHERE username = ? ORDER BY priority LIMIT 1');
$st->execute([$user]);
$plan = $st->fetchColumn();
$plan = $plan === false ? null : (string)$plan;
$pl = $plan !== null ? lim_read_plan($pdo, $plan) : lim_read_plan($pdo, "\0none");
$use = lim_usage($pdo, $user);
[$qVal, $qUnit] = lim_quota_split($lim['quota']);

/** Barra de consumo (elemento <progress>, sem estilo inline). */
function lim_bar(int $used, ?int $limit): string
{
    if ($limit === null || $limit <= 0) {
        return '';
    }
    $pct = min(100, (int)floor($used * 100 / $limit));
    return ' <progress class="use' . ($used >= $limit ? ' over' : '') . '" max="100" value="' . $pct . '"></progress> ' . $pct . '%';
}

/** Limite efetivo: o do usuário prevalece sobre o do plano. */
function lim_eff($u, $p, callable $fmt): string
{
    if ($u !== null) {
        return '<span class="eff">' . h($fmt($u)) . '</span> (usuário)';
    }
    if ($p !== null) {
        return '<span class="eff">' . h($fmt($p)) . '</span> (plano)';
    }
    return '<span class="muted">sem limite</span>';
}

page_header('Limites de ' . $user, 'users', ['css' => ['limits.css']]);
?>
<p><a href="users.php?<?= h(http_build_query(['q' => $user])) ?>">&larr; Usuários</a>
 · Plano: <?= $plan !== null ? h($plan) : '<span class="muted">(sem plano)</span>' ?></p>

<?php if ($canWrite): ?>
<div class="card">
<form method="post" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="save">
  <input type="hidden" name="username" value="<?= h($user) ?>">
  <div class="limits-form">
    <label>Tempo diário (s)<input name="daily" inputmode="numeric" maxlength="6" value="<?= h((string)$lim['daily']) ?>"></label>
    <label>Tempo mensal (s)<input name="monthly" inputmode="numeric" maxlength="8" value="<?= h((string)$lim['monthly']) ?>"></label>
    <label>Tempo total (s)<input name="total" inputmode="numeric" maxlength="10" value="<?= h((string)$lim['total']) ?>"></label>
    <label>Franquia de dados
      <span class="pair"><input name="quota" inputmode="decimal" maxlength="12" value="<?= h($qVal) ?>">
      <select name="quota_unit"><?php foreach (array_keys(LIM_UNITS) as $u): ?><option<?= $u === $qUnit ? ' selected' : '' ?>><?= h($u) ?></option><?php endforeach; ?></select></span></label>
    <label>Período da franquia
      <select name="quota_period"><?php foreach (LIM_PERIODS as $k => $v): ?><option value="<?= h($k) ?>"<?= $k === $lim['quota_period'] ? ' selected' : '' ?>><?= h($v) ?></option><?php endforeach; ?></select></label>
    <label>Sessões simultâneas<input name="simult" inputmode="numeric" maxlength="3" value="<?= h((string)$lim['simult']) ?>"></label>
    <label>MAC fixo (opcional)<input name="mac" maxlength="17" placeholder="AA-BB-CC-DD-EE-FF" value="<?= h((string)$lim['mac']) ?>"></label>
  </div>
  <p class="muted">Campo vazio = sem limite no usuário (vale o do plano, se houver). O limite do usuário prevalece sobre o do plano.</p>
  <button>Salvar limites</button>
</form>
</div>
<?php endif; ?>

<div class="scroll"><table>
<tr><th>Limite</th><th>Efetivo</th><th>Consumo atual</th></tr>
<?php foreach ([['daily', 'Tempo diário', 'daily'], ['monthly', 'Tempo mensal', 'monthly'], ['total', 'Tempo total', 'total']] as [$f, $label, $per]): ?>
<tr><td><?= h($label) ?></td>
  <td><?= lim_eff($lim[$f], $pl[$f], 'fmt_secs') ?></td>
  <td><?= h(fmt_secs($use['time'][$per])) ?><?= lim_bar($use['time'][$per], $lim[$f] ?? $pl[$f]) ?></td></tr>
<?php endforeach; ?>
<?php
$qe = $lim['quota'] ?? null;
$qp = $lim['quota_period'];
if ($qe === null) {
    $qe = $pl['quota'];
    $qp = $pl['quota_period'];
}
?>
<tr><td>Franquia de dados</td>
  <td><?= $qe === null ? '<span class="muted">sem limite</span>'
        : '<span class="eff">' . h(fmt_bytes($qe)) . ' (' . h(strtolower(LIM_PERIODS[$qp])) . ')</span> ('
          . ($lim['quota'] !== null ? 'usuário' : 'plano') . ')' ?></td>
  <td><?php foreach (LIM_PERIODS as $k => $v): ?><?= h($v) ?>: <?= h(fmt_bytes($use['bytes'][$k])) ?><?= $k === $qp ? lim_bar($use['bytes'][$k], $qe) : '' ?><br><?php endforeach; ?></td></tr>
<tr><td>Sessões simultâneas</td>
  <td><?= lim_eff($lim['simult'], $pl['simult'], static fn($v) => (string)$v) ?></td>
  <td><?= (int)$use['open'] ?> aberta(s)</td></tr>
<tr><td>MAC fixo</td>
  <td><?= $lim['mac'] !== null ? '<span class="eff">' . h($lim['mac']) . '</span>' : '<span class="muted">livre</span>' ?></td>
  <td class="muted">—</td></tr>
</table></div>
<p class="muted">Consumo: tempo e dados vêm do accounting (<code>radacct</code>); dados somam entrada + saída das
sessões iniciadas no período. Sessões abertas contam só se atualizaram nas últimas 24 h.</p>
<?php page_footer();
