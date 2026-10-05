<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/limits.php';
$admin = require_role('viewer');
$canWrite = role_at_least($admin, 'admin');

$pdo = db();

// Atributos de resposta gerenciados por esta página (radgroupreply).
const PLAN_ATTRS = ['Session-Timeout', 'Idle-Timeout', 'Acct-Interim-Interval', ATTR_RATE];

function valid_secs(string $s): bool
{
    return $s === '' || (bool)preg_match('/^[0-9]{1,9}$/', $s);
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    require_role('admin');
    csrf_check();
    $action = post('action');
    $name = post('name');
    try {
        if (!valid_plan($name)) {
            throw new RuntimeException('Nome do plano inválido (letras, números e _ . -).');
        }
        if ($action === 'save') {
            $down = post('down');
            $up = post('up');
            $timeout = post('timeout');
            $idle = post('idle');
            $interim = post('interim');
            if (!valid_rate($down) || !valid_rate($up)) {
                throw new RuntimeException('Velocidade inválida. Exemplos: 512k, 10M.');
            }
            if (($down === '') !== ($up === '')) {
                throw new RuntimeException('Informe download e upload, ou deixe os dois vazios.');
            }
            foreach ([$timeout, $idle, $interim] as $v) {
                if (!valid_secs($v)) {
                    throw new RuntimeException('Tempos devem ser números inteiros em segundos.');
                }
            }
            $lim = lim_from_input($_POST, false);
            ru_tx($pdo, function () use ($pdo, $name, $down, $up, $timeout, $idle, $interim, $lim) {
                lim_save_plan($pdo, $name, $lim);
                $ph = implode(',', array_fill(0, count(PLAN_ATTRS), '?'));
                $pdo->prepare("DELETE FROM radgroupreply WHERE groupname = ? AND attribute IN ($ph)")
                    ->execute(array_merge([$name], PLAN_ATTRS));
                $ins = $pdo->prepare('INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES (?, ?, ":=", ?)');
                if ($down !== '') {
                    // Mikrotik: "rx/tx" visto do roteador = upload/download do cliente.
                    $ins->execute([$name, ATTR_RATE, $up . '/' . $down]);
                }
                foreach (['Session-Timeout' => $timeout, 'Idle-Timeout' => $idle, 'Acct-Interim-Interval' => $interim] as $a => $v) {
                    if ($v !== '') {
                        $ins->execute([$name, $a, $v]);
                    }
                }
            });
            audit('plan.save', $name, compact('down', 'up', 'timeout', 'idle', 'interim') + ['limits' => lim_audit_detail($lim)]);
            flash('Plano salvo.');
        } elseif ($action === 'delete') {
            // Verificação e exclusão na mesma transação (com lock nas linhas do plano) e sem deixar preço órfão.
            ru_tx($pdo, function () use ($pdo, $name) {
                $st = $pdo->prepare('SELECT COUNT(*) FROM (SELECT id FROM radusergroup WHERE groupname = ? FOR UPDATE) t');
                $st->execute([$name]);
                if ((int)$st->fetchColumn() > 0) {
                    throw new RuntimeException('Há usuários neste plano. Mude o plano deles antes de excluir.');
                }
                $pdo->prepare('DELETE FROM radgroupreply WHERE groupname = ?')->execute([$name]);
                $pdo->prepare('DELETE FROM radgroupcheck WHERE groupname = ?')->execute([$name]);
                $pdo->prepare('DELETE FROM panel_plan_prices WHERE groupname = ?')->execute([$name]);
            });
            audit('plan.delete', $name);
            flash('Plano excluído.');
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'plans'), 'err');
    }
    redirect('plans.php');
}

$rows = $pdo->query(
    'SELECT p.groupname,
            (SELECT COUNT(*) FROM radusergroup u WHERE u.groupname = p.groupname) AS users
     FROM (SELECT groupname FROM radgroupreply UNION SELECT groupname FROM radgroupcheck) p
     ORDER BY p.groupname'
)->fetchAll();

$planLimits = lim_read_all_plans($pdo);
$attrs = [];
foreach ($pdo->query('SELECT groupname, attribute, value FROM radgroupreply') as $a) {
    $attrs[$a['groupname']][$a['attribute']] = $a['value'];
}

page_header('Planos', 'plans', ['css' => ['limits.css']]);
?>
<?php if ($canWrite): ?>
<div class="card">
<p class="muted">Velocidade usa <code><?= h(ATTR_RATE) ?></code> (MikroTik). Outros equipamentos
ignoram esse atributo e precisam do atributo do próprio fabricante.</p>
<form method="post" class="row">
  <?= csrf_field() ?><input type="hidden" name="action" value="save">
  <label>Nome<input name="name" required maxlength="64"></label>
  <label>Download<input name="down" placeholder="10M" size="6"></label>
  <label>Upload<input name="up" placeholder="2M" size="6"></label>
  <label>Tempo máx. sessão (s)<input name="timeout" inputmode="numeric" size="8"></label>
  <label>Ociosidade (s)<input name="idle" inputmode="numeric" size="8"></label>
  <label>Intervalo accounting (s)<input name="interim" inputmode="numeric" size="8" placeholder="300"></label>
  <fieldset class="limits-set">
    <legend>Limites (opcionais; vazio = sem limite)</legend>
    <label>Tempo diário (s)<input name="daily" inputmode="numeric" size="8"></label>
    <label>Tempo mensal (s)<input name="monthly" inputmode="numeric" size="8"></label>
    <label>Tempo total (s)<input name="total" inputmode="numeric" size="9"></label>
    <label>Franquia de dados<input name="quota" inputmode="decimal" size="7"></label>
    <label>Unidade<select name="quota_unit"><option>GB</option><option>MB</option></select></label>
    <label>Período da franquia<select name="quota_period"><?php foreach (LIM_PERIODS as $k => $v): ?><option value="<?= h($k) ?>"<?= $k === 'monthly' ? ' selected' : '' ?>><?= h($v) ?></option><?php endforeach; ?></select></label>
    <label>Sessões simultâneas<input name="simult" inputmode="numeric" size="4"></label>
  </fieldset>
  <button>Salvar plano</button>
</form>
<p class="muted">Limite definido no próprio usuário (tela Limites do usuário) prevalece sobre o do plano.
Salvar com um nome existente substitui os valores desse plano.</p>
</div>
<?php endif; ?>

<div class="scroll"><table>
<tr><th>Plano</th><th>Velocidade (up/down)</th><th>Sessão</th><th>Ociosidade</th><th>Interim</th><th>Limites</th><th>Usuários</th><?php if ($canWrite): ?><th></th><?php endif; ?></tr>
<?php foreach ($rows as $r): $a = $attrs[$r['groupname']] ?? []; ?>
<tr>
  <td><?= h($r['groupname']) ?></td>
  <td><?= h($a[ATTR_RATE] ?? '—') ?></td>
  <td><?= isset($a['Session-Timeout']) ? h(fmt_secs((int)$a['Session-Timeout'])) : '—' ?></td>
  <td><?= isset($a['Idle-Timeout']) ? h($a['Idle-Timeout'] . ' s') : '—' ?></td>
  <td><?= isset($a['Acct-Interim-Interval']) ? h($a['Acct-Interim-Interval'] . ' s') : '—' ?></td>
  <td><?php $ls = isset($planLimits[$r['groupname']]) ? lim_summary($planLimits[$r['groupname']]) : [];
      echo $ls ? h(implode(' · ', $ls)) : '—'; ?></td>
  <td><?= (int)$r['users'] ?></td>
  <?php if ($canWrite): ?>
  <td>
    <form method="post" class="inline" data-confirm="Excluir este plano?">
      <?= csrf_field() ?><input type="hidden" name="action" value="delete">
      <input type="hidden" name="name" value="<?= h($r['groupname']) ?>">
      <button class="danger">Excluir</button>
    </form>
  </td>
  <?php endif; ?>
</tr>
<?php endforeach; if (!$rows): ?>
<tr><td colspan="8" class="muted">Nenhum plano criado.</td></tr>
<?php endif; ?>
</table></div>
<?php page_footer();
