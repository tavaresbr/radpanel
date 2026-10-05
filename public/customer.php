<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/customers.php';
$admin = require_role('operator');
$canWrite = role_at_least($admin, 'operator');
$pdo = db();

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    require_role('operator');
    csrf_check();
    $id = (int)post('id');
    $action = post('action');
    try {
        if ($action === 'update') {
            $changed = cust_update($pdo, $id, [
                'name' => post('name'), 'email' => post('email'), 'phone' => post('phone'),
                'document' => post('document'), 'address' => post('address'),
                'notes' => post('notes'), 'username' => post('username'),
            ]);
            flash($changed ? 'Cliente atualizado.' : 'Nada foi alterado.');
        } elseif ($action === 'pay' || $action === 'pay_renew') {
            $nonce = (string)($_SESSION['pay_nonce'][$id] ?? '');
            if ($nonce === '' || !hash_equals($nonce, post('nonce'))) {
                throw new RuntimeException('Formulário de pagamento expirado ou já enviado. Confira o histórico e tente de novo.');
            }
            $renew = $action === 'pay_renew';
            $res = cust_pay($pdo, $id, [
                'amount' => post('amount'), 'method' => post('method'), 'paid_at' => post('paid_at'),
                'period_from' => post('period_from'), 'period_to' => post('period_to'), 'notes' => post('notes'),
            ], $renew, $admin['username']);
            unset($_SESSION['pay_nonce'][$id]);
            $msg = 'Pagamento registrado.';
            if ($res['renewed']) {
                $msg .= ' Validade do usuário renovada.';
            } elseif ($res['note'] === 'blocked') {
                $msg .= ' ATENÇÃO: o usuário está BLOQUEADO e continua bloqueado; desbloqueie em Usuários se for o caso (a nova validade será restaurada).';
            } elseif ($res['note'] === 'already_later') {
                $msg .= ' A validade atual do usuário já é posterior ao período pago; não foi alterada.';
            }
            flash($msg);
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'customer'), 'err');
    }
    redirect('customer.php?id=' . $id);
}

$id = (int)($_GET['id'] ?? 0);
$c = $id > 0 ? cust_get($pdo, $id) : null;
if (!$c) {
    http_response_code(404);
    page_header('Cliente não encontrado', 'customers', ['css' => ['customers.css']]);
    echo '<p><a href="customers.php">Voltar à lista</a></p>';
    page_footer();
    exit;
}

$user = $c['username'] !== null ? (string)$c['username'] : null;
$info = $user !== null ? cust_user_info($pdo, $user) : null;
$prices = cust_prices($pdo);

// Consumo do mês corrente (radacct).
$usage = null;
if ($user !== null) {
    $st = $pdo->prepare(
        'SELECT COUNT(*) n, COALESCE(SUM(acctsessiontime),0) t, COALESCE(SUM(acctinputoctets),0) i, COALESCE(SUM(acctoutputoctets),0) o
         FROM radacct WHERE username = ? AND acctstarttime >= ?'
    );
    $st->execute([$user, date('Y-m-01 00:00:00')]);
    $usage = $st->fetch();
}

// Pagamentos.
$st = $pdo->prepare('SELECT id, amount, method, paid_at, period_from, period_to, notes, created_by FROM panel_payments WHERE customer_id = ? ORDER BY paid_at DESC, id DESC LIMIT 200');
$st->execute([$id]);
$payments = $st->fetchAll();
$totalPaid = cust_sum_cents($pdo, 'SELECT COALESCE(SUM(amount),0) FROM panel_payments WHERE customer_id = ?', [$id]);
$paidUntil = cust_paid_until($pdo, $id);
$today = date('Y-m-d');

// Sugestões do formulário de pagamento.
$plan = $info['plan'] ?? '';
$suggest = $prices[$plan] ?? null;
$sFrom = ($paidUntil !== null && $paidUntil >= $today) ? date('Y-m-d', strtotime($paidUntil . ' +1 day')) : $today;
$sDays = $suggest['days'] ?? 30;
$sTo = date('Y-m-d', strtotime($sFrom . ' +' . ($sDays - 1) . ' days'));
if ($canWrite) {
    if (empty($_SESSION['pay_nonce'][$id])) {
        $_SESSION['pay_nonce'][$id] = bin2hex(random_bytes(16));
    }
}

page_header('Cliente #' . $id, 'customers', ['css' => ['customers.css']]);
?>
<p class="noprint"><a href="customers.php">&larr; Clientes</a></p>
<div class="cols">
<div class="card">
  <h2>Dados</h2>
  <dl class="kv">
    <dt>Nome</dt><dd><?= h($c['name']) ?><?= $c['archived'] ? ' <span class="tag">arquivado</span>' : '' ?></dd>
    <dt>E-mail</dt><dd><?= h($c['email']) ?: '—' ?></dd>
    <dt>Telefone</dt><dd><?= h($c['phone']) ?: '—' ?></dd>
    <dt>Documento</dt><dd><?= h($c['document']) ?: '—' ?></dd>
    <dt>Endereço</dt><dd><?= h($c['address']) ?: '—' ?></dd>
    <dt>Observações</dt><dd><?= nl2br(h($c['notes'])) ?: '—' ?></dd>
    <dt>Cadastro</dt><dd><?= h(date('d/m/Y H:i', strtotime((string)$c['created_at']))) ?></dd>
  </dl>
</div>

<div class="card">
  <h2>Usuário RADIUS</h2>
  <?php if ($info === null): ?>
    <p class="muted">Nenhum usuário vinculado.</p>
  <?php else: ?>
  <dl class="kv">
    <dt>Usuário</dt><dd><a href="users.php?q=<?= h(rawurlencode((string)$user)) ?>"><?= h((string)$user) ?></a></dd>
    <dt>Estado</dt><dd><span class="tag <?= $info['state'] === 'active' ? 'good' : 'bad' ?>"><?= h($info['state_label']) ?></span></dd>
    <?php if ($info['exists']): ?>
    <dt>Plano</dt><dd><?= h($info['plan']) ?: '(sem plano)' ?><?= $suggest ? ' · ' . h(money_fmt($suggest['cents'])) . ' / ' . (int)$suggest['days'] . ' dias' : '' ?></dd>
    <dt>Validade</dt><dd><?= h(fmt_expiration($info['expiration'])) ?></dd>
    <?php endif; ?>
  </dl>
  <?php if ($info['state'] === 'blocked'): ?>
  <p class="muted">Usuário bloqueado: registrar pagamento não o desbloqueia automaticamente.</p>
  <?php endif; ?>
  <?php if ($usage !== null): ?>
  <h2>Consumo em <?= h(date('m/Y')) ?></h2>
  <dl class="kv">
    <dt>Sessões</dt><dd><?= (int)$usage['n'] ?></dd>
    <dt>Tempo</dt><dd><?= h(fmt_secs((int)$usage['t'])) ?></dd>
    <dt>Download</dt><dd><?= h(fmt_bytes((int)$usage['o'])) ?></dd>
    <dt>Upload</dt><dd><?= h(fmt_bytes((int)$usage['i'])) ?></dd>
  </dl>
  <?php endif; endif; ?>
</div>

<div class="card">
  <h2>Situação financeira</h2>
  <?php if ($paidUntil === null): ?>
    <p><span class="tag warn">sem pagamentos com período</span></p>
  <?php elseif ($paidUntil >= $today): ?>
    <p><span class="tag good">em dia até <?= h(date('d/m/Y', strtotime($paidUntil))) ?></span></p>
  <?php else: ?>
    <p><span class="tag bad">vencido desde <?= h(date('d/m/Y', strtotime($paidUntil))) ?></span></p>
  <?php endif; ?>
  <p>Total recebido: <strong><?= h(money_fmt($totalPaid)) ?></strong> em <?= count($payments) ?> pagamento(s).</p>
</div>
</div>

<?php if ($canWrite): ?>
<h2>Registrar pagamento</h2>
<div class="card">
<?php if ($c['archived']): ?>
  <p class="muted">Cliente arquivado: desarquive para registrar pagamentos.</p>
<?php else: ?>
<form method="post" class="row">
  <?= csrf_field() ?><input type="hidden" name="id" value="<?= $id ?>">
  <input type="hidden" name="nonce" value="<?= h((string)$_SESSION['pay_nonce'][$id]) ?>">
  <label>Valor (R$)<input name="amount" size="10" inputmode="decimal" required value="<?= $suggest ? h(money_input($suggest['cents'])) : '' ?>"></label>
  <label>Forma<select name="method">
    <?php foreach (CUST_METHODS as $k => $label): ?><option value="<?= h($k) ?>"><?= h($label) ?></option><?php endforeach; ?>
  </select></label>
  <label>Data do pagamento<input name="paid_at" type="date" required value="<?= h($today) ?>" max="<?= h($today) ?>"></label>
  <label>Período de<input name="period_from" type="date" value="<?= h($sFrom) ?>"></label>
  <label>Período até<input name="period_to" type="date" value="<?= h($sTo) ?>"></label>
  <label class="wide">Observação<input name="notes" maxlength="255"></label>
  <button name="action" value="pay">Registrar pagamento</button>
  <?php if ($user !== null): ?>
  <button name="action" value="pay_renew">Registrar pagamento e renovar validade</button>
  <?php endif; ?>
</form>
<p class="muted">"Registrar pagamento e renovar validade" grava o pagamento e estende a validade do usuário até o fim do período, numa única operação (se algo falhar, nada é gravado). Nunca encurta a validade nem desbloqueia usuário bloqueado.</p>
<?php endif; ?>
</div>
<?php endif; ?>

<h2>Pagamentos</h2>
<div class="scroll"><table>
<tr><th>Data</th><th class="money">Valor</th><th>Forma</th><th>Período</th><th>Observação</th><th>Por</th></tr>
<?php foreach ($payments as $p): ?>
<tr>
  <td class="nowrap"><?= h(date('d/m/Y', strtotime($p['paid_at']))) ?></td>
  <td class="money"><?= h(money_fmt(money_from_db((string)$p['amount']))) ?></td>
  <td><?= h(CUST_METHODS[$p['method']] ?? $p['method']) ?></td>
  <td class="nowrap"><?= $p['period_to'] ? h(date('d/m/Y', strtotime((string)$p['period_from'])) . ' – ' . date('d/m/Y', strtotime((string)$p['period_to']))) : '—' ?></td>
  <td><?= h($p['notes']) ?></td>
  <td><?= h($p['created_by']) ?></td>
</tr>
<?php endforeach; if (!$payments): ?>
<tr><td colspan="6" class="muted">Nenhum pagamento registrado.</td></tr>
<?php endif; ?>
</table></div>

<?php if ($canWrite): ?>
<h2>Editar cliente</h2>
<div class="card">
<form method="post" class="row">
  <?= csrf_field() ?><input type="hidden" name="action" value="update"><input type="hidden" name="id" value="<?= $id ?>">
  <label class="wide">Nome *<input name="name" maxlength="120" required value="<?= h($c['name']) ?>"></label>
  <label class="wide">E-mail<input name="email" type="email" maxlength="120" value="<?= h($c['email']) ?>"></label>
  <label>Telefone<input name="phone" maxlength="30" pattern="[0-9+() \-]*" value="<?= h($c['phone']) ?>"></label>
  <label>CPF / CNPJ<input name="document" maxlength="18" inputmode="numeric" autocomplete="off" data-doc value="<?= h($c['document']) ?>"></label>
  <label class="wide">Usuário RADIUS<input name="username" maxlength="64" pattern="[A-Za-z0-9_.@\-]*" value="<?= h((string)$c['username']) ?>"></label>
  <label class="wide">Endereço<input name="address" maxlength="255" value="<?= h($c['address']) ?>"></label>
  <label class="wide">Observações<input name="notes" maxlength="1000" value="<?= h($c['notes']) ?>"></label>
  <button>Salvar</button>
</form>
</div>
<div class="noprint">
<form method="post" action="customers.php" class="inline">
  <?= csrf_field() ?><input type="hidden" name="id" value="<?= $id ?>">
  <input type="hidden" name="action" value="<?= $c['archived'] ? 'unarchive' : 'archive' ?>">
  <button><?= $c['archived'] ? 'Desarquivar' : 'Arquivar' ?> cliente</button>
</form>
<form method="post" action="customers.php" class="inline" data-confirm="Excluir este cliente? (Só é possível sem pagamentos; o usuário RADIUS não é removido.)">
  <?= csrf_field() ?><input type="hidden" name="id" value="<?= $id ?>">
  <input type="hidden" name="action" value="delete"><button class="danger">Excluir cliente</button>
</form>
</div>
<?php endif; ?>
<?php page_footer(['js' => ['customers.js']]);
