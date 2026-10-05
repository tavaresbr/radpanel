<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/vouchers.php';
$admin = require_role('operator');
$pdo = db();

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    require_role('operator');
    csrf_check();
    $action = post('action');
    try {
        if ($action === 'generate') {
            set_time_limit(120);
            $p = voucher_validate($pdo, [
                'qty' => post('qty'), 'prefix' => post('prefix'), 'len' => post('len'), 'plan' => post('plan'),
                'expires' => post('expires'), 'minutes' => post('minutes'),
                'label' => post('label'), 'notes' => post('notes'),
            ]);
            [$batch, $codes] = voucher_generate($pdo, $p, $admin);
            // Um único audit por lote, sem códigos.
            audit('voucher.batch', 'batch#' . $batch, [
                'qty' => $p['qty'], 'plan' => $p['plan'], 'prefix' => $p['prefix'], 'length' => $p['len'],
                'expires' => $p['expires'], 'minutes_after_login' => $p['minutes'], 'label' => $p['label'],
            ]);
            $_SESSION['voucher_print'][$batch] = [
                'codes' => $codes, 'plan' => $p['plan'], 'label' => $p['label'],
                'expires' => $p['expires'], 'minutes' => $p['minutes'],
            ];
            redirect('vouchers_print.php?batch=' . $batch);
        } elseif ($action === 'revoke') {
            $batch = (int)post('batch');
            $st = $pdo->prepare('SELECT id FROM panel_voucher_batches WHERE id = ?');
            $st->execute([$batch]);
            if (!$st->fetchColumn()) {
                throw new RuntimeException('Lote não encontrado.');
            }
            $withUsed = post('with_used') === '1';
            [$removed, $kept] = voucher_revoke($pdo, $batch, $withUsed);
            audit('voucher.revoke', 'batch#' . $batch, ['removed' => $removed, 'kept_used' => $kept, 'with_used' => $withUsed]);
            unset($_SESSION['voucher_print'][$batch]);
            flash("Lote #$batch revogado: $removed voucher(s) removido(s)" . ($kept ? ", $kept usado(s) mantido(s)." : '.'));
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        if ($e instanceof RuntimeException && !($e instanceof PDOException)) {
            flash($e->getMessage(), 'err');
        } else {
            log_exception($e, 'vouchers');
            flash('Erro ao processar o lote; nada foi gravado.', 'err');
        }
    }
    redirect('vouchers.php');
}

$plans = ru_plans($pdo);
$batches = $pdo->query(
    'SELECT b.id, b.label, b.created_at, b.created_by, b.plan, b.qty, b.expires_date, b.minutes_after_login,
            (SELECT COUNT(*) FROM panel_vouchers v WHERE v.batch_id = b.id) AS remaining,
            (SELECT COUNT(*) FROM panel_vouchers v WHERE v.batch_id = b.id
               AND EXISTS(SELECT 1 FROM radacct a WHERE a.username = v.username)) AS used
     FROM panel_voucher_batches b ORDER BY b.id DESC LIMIT 200'
)->fetchAll();

page_header('Vouchers', 'vouchers', ['css' => ['vouchers.css']]);
?>
<div class="card">
<form method="post" class="row">
  <?= csrf_field() ?><input type="hidden" name="action" value="generate">
  <label>Quantidade (1–1000)<input name="qty" type="number" min="1" max="1000" value="20" required></label>
  <label>Prefixo (A-Z0-9, até 6)<input name="prefix" maxlength="6" pattern="[A-Za-z0-9]{0,6}" size="8"></label>
  <label>Tamanho do código (6–12)<input name="len" type="number" min="6" max="12" value="8" required></label>
  <label>Plano<?= plan_select($plans, '', 'plan') ?></label>
  <label>Conta válida até (opcional)<input name="expires" type="date"></label>
  <label>Tempo de uso após 1º login, min (opcional)<input name="minutes" type="number" min="1" max="525600"></label>
  <label>Rótulo<input name="label" maxlength="100"></label>
  <label>Observação<input name="notes" maxlength="255"></label>
  <button>Gerar lote</button>
</form>
<p class="muted">Cada voucher é um usuário com senha própria (outro código aleatório do mesmo tamanho).
Os códigos aparecem <strong>uma única vez</strong>, na página de impressão. Depois só é possível ver contagem e uso.
O tempo de uso após o primeiro login grava <code>control.Expire-After</code> (sqlcounter <code>expire_on_login</code>) — NÃO TESTADO sem radiusd.</p>
</div>

<div class="scroll"><table>
<tr><th>Lote</th><th>Rótulo</th><th>Plano</th><th>Qtd</th><th>Usados</th><th>Restantes</th><th>Validade</th><th>Criado</th><th>Por</th><th></th></tr>
<?php foreach ($batches as $b): ?>
<tr>
  <td>#<?= (int)$b['id'] ?></td>
  <td><?= h($b['label']) ?></td>
  <td><?= h($b['plan']) ?></td>
  <td><?= (int)$b['qty'] ?></td>
  <td><?= (int)$b['used'] ?></td>
  <td><?= (int)$b['remaining'] ?></td>
  <td class="nowrap"><?= $b['expires_date'] ? h(date('d/m/Y', strtotime($b['expires_date']))) : '—' ?><?= $b['minutes_after_login'] ? ' · ' . (int)$b['minutes_after_login'] . ' min após 1º login' : '' ?></td>
  <td class="nowrap"><?= h(date('d/m/Y H:i', strtotime($b['created_at']))) ?></td>
  <td><?= h($b['created_by']) ?></td>
  <td>
    <?php if ((int)$b['remaining'] > 0): ?>
    <form method="post" class="inline" data-confirm="Revogar este lote? Os vouchers removidos deixam de funcionar.">
      <?= csrf_field() ?><input type="hidden" name="action" value="revoke">
      <input type="hidden" name="batch" value="<?= (int)$b['id'] ?>">
      <label class="nowrap"><input type="checkbox" name="with_used" value="1"> remover também os usados</label>
      <button class="danger">Revogar lote</button>
    </form>
    <?php endif; ?>
  </td>
</tr>
<?php endforeach; if (!$batches): ?>
<tr><td colspan="10" class="muted">Nenhum lote gerado.</td></tr>
<?php endif; ?>
</table></div>
<?php page_footer();
