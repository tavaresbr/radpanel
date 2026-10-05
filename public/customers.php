<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/customers.php';
$admin = require_role('operator');
$canWrite = role_at_least($admin, 'operator');
$isAdmin = role_at_least($admin, 'admin');
$pdo = db();

function cust_fail(Throwable $e): void
{
    flash(friendly_error($e, 'customers'), 'err');
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    $action = post('action');
    $adminOnly = in_array($action, ['price_save', 'price_delete'], true);
    require_role($adminOnly ? 'admin' : 'operator');
    csrf_check();
    $to = 'customers.php';
    try {
        switch ($action) {
            case 'create':
                $id = cust_create($pdo, [
                    'name' => post('name'), 'email' => post('email'), 'phone' => post('phone'),
                    'document' => post('document'), 'address' => post('address'),
                    'notes' => post('notes'), 'username' => post('username'),
                ]);
                flash('Cliente cadastrado.');
                $to = 'customer.php?id=' . $id;
                break;
            case 'delete':
                cust_delete($pdo, (int)post('id'));
                flash('Cliente excluído (o usuário RADIUS foi mantido).');
                break;
            case 'archive':
            case 'unarchive':
                cust_set_archived($pdo, (int)post('id'), $action === 'archive');
                flash($action === 'archive' ? 'Cliente arquivado.' : 'Cliente desarquivado.');
                break;
            case 'price_save':
                cust_set_price($pdo, post('plan'), post('price'), post('period_days'));
                flash('Preço do plano salvo.');
                $to = 'customers.php?tab=prices';
                break;
            case 'price_delete':
                cust_delete_price($pdo, post('plan'));
                flash('Preço removido.');
                $to = 'customers.php?tab=prices';
                break;
            default:
                throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        cust_fail($e);
        $to = $adminOnly ? 'customers.php?tab=prices' : 'customers.php';
    }
    redirect($to);
}

$tab = (string)($_GET['tab'] ?? 'list');
if (!in_array($tab, ['list', 'prices', 'report'], true)) {
    $tab = 'list';
}
if ($tab === 'prices' && !$isAdmin) {
    http_response_code(403);
    exit('Acesso negado: seu perfil não permite esta aba.');
}

page_header('Clientes', 'customers', ['css' => ['customers.css']]);
echo '<div class="tabs noprint"><a' . ($tab === 'list' ? ' class="on"' : '') . ' href="customers.php">Clientes</a>'
    . '<a' . ($tab === 'report' ? ' class="on"' : '') . ' href="customers.php?tab=report">Relatório financeiro</a>'
    . ($isAdmin ? '<a' . ($tab === 'prices' ? ' class="on"' : '') . ' href="customers.php?tab=prices">Preços dos planos</a>' : '')
    . '</div>';

if ($tab === 'list') {
    $q = mb_substr(trim((string)($_GET['q'] ?? '')), 0, 64);
    $showArch = ($_GET['arch'] ?? '') === '1';
    $page = max(1, (int)($_GET['page'] ?? 1));
    $where = [];
    $params = [];
    if (!$showArch) {
        $where[] = 'archived = 0';
    }
    if ($q !== '') {
        $like = '%' . like_escape($q) . '%';
        $where[] = '(name LIKE ? OR email LIKE ? OR phone LIKE ? OR username LIKE ?)';
        array_push($params, $like, $like, $like, $like);
    }
    $w = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $st = $pdo->prepare("SELECT COUNT(*) FROM panel_customers $w");
    $st->execute($params);
    $total = (int)$st->fetchColumn();
    $st = $pdo->prepare(
        "SELECT id, name, email, phone, username, archived FROM panel_customers $w
         ORDER BY name, id LIMIT " . PER_PAGE . ' OFFSET ' . page_offset($page)
    );
    $st->execute($params);
    $rows = $st->fetchAll();
    ?>
<form method="get" class="row gap noprint">
  <label>Buscar (nome, e-mail, telefone, usuário)<input name="q" value="<?= h($q) ?>" maxlength="64"></label>
  <label class="nowrap"><span>&nbsp;</span><span><input type="checkbox" name="arch" value="1"<?= $showArch ? ' checked' : '' ?>> mostrar arquivados</span></label>
  <button>Buscar</button>
</form>
<p class="muted"><?= $total ?> cliente(s).</p>
<div class="scroll"><table>
<tr><th>Nome</th><th>E-mail</th><th>Telefone</th><th>Usuário RADIUS</th><th></th></tr>
<?php foreach ($rows as $c): ?>
<tr>
  <td><a href="customer.php?id=<?= (int)$c['id'] ?>"><?= h($c['name']) ?></a><?= $c['archived'] ? ' <span class="tag">arquivado</span>' : '' ?></td>
  <td><?= h($c['email']) ?></td>
  <td class="nowrap"><?= h($c['phone']) ?></td>
  <td><?= $c['username'] !== null ? h($c['username']) : '<span class="muted">—</span>' ?></td>
  <td class="nowrap">
    <a href="customer.php?id=<?= (int)$c['id'] ?>">Abrir</a>
    <?php if ($canWrite): ?>
    <form method="post" class="inline">
      <?= csrf_field() ?><input type="hidden" name="id" value="<?= (int)$c['id'] ?>">
      <input type="hidden" name="action" value="<?= $c['archived'] ? 'unarchive' : 'archive' ?>">
      <button class="link"><?= $c['archived'] ? 'Desarquivar' : 'Arquivar' ?></button>
    </form>
    <form method="post" class="inline" data-confirm="Excluir este cliente? (Só é possível sem pagamentos; o usuário RADIUS não é removido.)">
      <?= csrf_field() ?><input type="hidden" name="id" value="<?= (int)$c['id'] ?>">
      <input type="hidden" name="action" value="delete">
      <button class="danger">Excluir</button>
    </form>
    <?php endif; ?>
  </td>
</tr>
<?php endforeach; if (!$rows): ?>
<tr><td colspan="5" class="muted">Nenhum cliente encontrado.</td></tr>
<?php endif; ?>
</table></div>
<?php
    pager($total, $page, http_build_query(['tab' => 'list', 'q' => $q, 'arch' => $showArch ? '1' : '0']));
    if ($canWrite): ?>
<h2>Novo cliente</h2>
<div class="card">
<form method="post" class="row">
  <?= csrf_field() ?><input type="hidden" name="action" value="create">
  <label class="wide">Nome *<input name="name" maxlength="120" required></label>
  <label class="wide">E-mail<input name="email" type="email" maxlength="120"></label>
  <label>Telefone<input name="phone" maxlength="30" pattern="[0-9+() \-]*"></label>
  <label>Documento (opcional)<input name="document" maxlength="30"></label>
  <label class="wide">Usuário RADIUS (opcional, deve existir)<input name="username" maxlength="64" pattern="[A-Za-z0-9_.@\-]*"></label>
  <label class="wide">Endereço<input name="address" maxlength="255"></label>
  <label class="wide">Observações<input name="notes" maxlength="1000"></label>
  <button>Cadastrar</button>
</form>
<p class="muted">Dados pessoais: ficam restritos aos operadores e administradores do painel e não vão para o log de auditoria.</p>
</div>
<?php endif;
} elseif ($tab === 'prices') {
    $plans = ru_plans($pdo);
    $prices = cust_prices($pdo);
    ?>
<p class="muted">Preço e periodicidade usados como sugestão ao registrar pagamentos. Só planos existentes aparecem.</p>
<div class="scroll"><table>
<tr><th>Plano</th><th>Preço (R$)</th><th>Período (dias)</th><th></th></tr>
<?php foreach ($plans as $p): $pr = $prices[$p] ?? null; ?>
<tr>
  <td><?= h($p) ?></td>
  <td colspan="3">
    <form method="post" class="row">
      <?= csrf_field() ?><input type="hidden" name="action" value="price_save">
      <input type="hidden" name="plan" value="<?= h($p) ?>">
      <input name="price" size="10" inputmode="decimal" required value="<?= $pr ? h(money_input($pr['cents'])) : '' ?>" aria-label="Preço">
      <input name="period_days" type="number" min="1" max="3660" required value="<?= $pr ? (int)$pr['days'] : 30 ?>" aria-label="Período em dias">
      <button>Salvar</button>
    </form>
    <?php if ($pr): ?>
    <form method="post" class="inline" data-confirm="Remover o preço deste plano?">
      <?= csrf_field() ?><input type="hidden" name="action" value="price_delete">
      <input type="hidden" name="plan" value="<?= h($p) ?>"><button class="danger">Remover</button>
    </form>
    <?php endif; ?>
  </td>
</tr>
<?php endforeach; if (!$plans): ?>
<tr><td colspan="4" class="muted">Nenhum plano cadastrado (crie em Planos).</td></tr>
<?php endif; ?>
</table></div>
<?php
} else {
    // ---------------------------------------------------------------- relatório financeiro
    $months = cust_last_months(12);
    $from = $months[0] . '-01';
    $st = $pdo->prepare(
        "SELECT DATE_FORMAT(paid_at, '%Y-%m') ym, SUM(amount) s, COUNT(*) n FROM panel_payments
         WHERE paid_at >= ? GROUP BY ym"
    );
    $st->execute([$from]);
    $byMonth = [];
    foreach ($st as $r) {
        $byMonth[$r['ym']] = [money_from_db((string)$r['s']), (int)$r['n']];
    }
    $st = $pdo->prepare('SELECT method, SUM(amount) s, COUNT(*) n FROM panel_payments WHERE paid_at >= ? GROUP BY method');
    $st->execute([$from]);
    $byMethod = [];
    foreach ($st as $r) {
        $byMethod[$r['method']] = [money_from_db((string)$r['s']), (int)$r['n']];
    }
    $totalCents = 0;
    $maxMonth = 0;
    foreach ($months as $m) {
        $totalCents += $byMonth[$m][0] ?? 0;
        $maxMonth = max($maxMonth, $byMonth[$m][0] ?? 0);
    }

    $days = max(0, min(3650, (int)($_GET['days'] ?? 0)));
    $prices = cust_prices($pdo);
    $linked = $pdo->query('SELECT id, name, username FROM panel_customers WHERE archived = 0 AND username IS NOT NULL ORDER BY name, id')->fetchAll();
    $exp = cust_expirations($pdo, array_column($linked, 'username'));
    $planOf = [];
    foreach (array_chunk(array_column($linked, 'username'), 400) as $chunk) {
        $in = implode(',', array_fill(0, count($chunk), '?'));
        $st = $pdo->prepare("SELECT username, groupname FROM radusergroup WHERE username IN ($in) ORDER BY priority DESC");
        $st->execute($chunk);
        foreach ($st as $r) {
            $planOf[strtolower($r['username'])] = $r['groupname'];
        }
    }
    $now = time();
    $late = [];
    $owedCents = 0;
    foreach ($linked as $c) {
        $e = $exp[strtolower($c['username'])] ?? [];
        if (empty($e['exists'])) {
            continue;
        }
        $blocked = !empty($e['blocked']);
        $ts = expiration_ts($blocked ? ($e['prev'] ?? null) : ($e['exp'] ?? null));
        if ($ts === null || $now - $ts <= $days * 86400) {
            continue;
        }
        $plan = $planOf[strtolower($c['username'])] ?? '';
        $price = $prices[$plan]['cents'] ?? 0;
        $owedCents += $price;
        $late[] = ['id' => (int)$c['id'], 'name' => $c['name'], 'username' => $c['username'], 'plan' => $plan,
                   'ts' => $ts, 'days' => intdiv($now - $ts, 86400), 'blocked' => $blocked, 'price' => $price];
    }
    usort($late, fn($a, $b) => $b['days'] <=> $a['days']);
    ?>
<h2>Receita por mês (últimos 12)</h2>
<div class="scroll"><table>
<tr><th>Mês</th><th class="money">Receita</th><th>Pagamentos</th><th></th></tr>
<?php foreach (array_reverse($months) as $m):
    $c = $byMonth[$m][0] ?? 0;
    $w = $maxMonth > 0 ? (int)round($c * 10 / $maxMonth) : 0; ?>
<tr><td><?= h(substr($m, 5, 2) . '/' . substr($m, 0, 4)) ?></td><td class="money"><?= h(money_fmt($c)) ?></td>
  <td><?= (int)($byMonth[$m][1] ?? 0) ?></td><td class="barcell"><span class="bar w<?= $w ?>"></span></td></tr>
<?php endforeach; ?>
<tr class="total"><td>Total</td><td class="money"><?= h(money_fmt($totalCents)) ?></td><td></td><td></td></tr>
</table></div>

<h2>Receita por forma de pagamento (mesmo período)</h2>
<div class="scroll"><table>
<tr><th>Forma</th><th class="money">Receita</th><th>Pagamentos</th></tr>
<?php foreach (CUST_METHODS as $k => $label): ?>
<tr><td><?= h($label) ?></td><td class="money"><?= h(money_fmt($byMethod[$k][0] ?? 0)) ?></td><td><?= (int)($byMethod[$k][1] ?? 0) ?></td></tr>
<?php endforeach; ?>
</table></div>

<h2>Inadimplentes</h2>
<form method="get" class="row gap noprint">
  <input type="hidden" name="tab" value="report">
  <label>Validade vencida há mais de (dias)<input name="days" type="number" min="0" max="3650" value="<?= $days ?>"></label>
  <button>Filtrar</button>
</form>
<p class="muted"><?= count($late) ?> cliente(s) vinculado(s) · valor dos planos em atraso: <strong><?= h(money_fmt($owedCents)) ?></strong>
 (estimativa pelo preço do plano; bloqueados contam pela validade anterior ao bloqueio).</p>
<div class="scroll"><table>
<tr><th>Cliente</th><th>Usuário</th><th>Plano</th><th>Venceu em</th><th>Dias</th><th class="money">Valor do plano</th><th>Estado</th></tr>
<?php foreach ($late as $l): ?>
<tr>
  <td><a href="customer.php?id=<?= $l['id'] ?>"><?= h($l['name']) ?></a></td>
  <td><?= h($l['username']) ?></td><td><?= h($l['plan']) ?></td>
  <td class="nowrap"><?= h(date('d/m/Y', $l['ts'])) ?></td><td><?= $l['days'] ?></td>
  <td class="money"><?= $l['price'] > 0 ? h(money_fmt($l['price'])) : '—' ?></td>
  <td><?= $l['blocked'] ? '<span class="tag bad">bloqueado</span>' : '<span class="tag warn">vencido</span>' ?></td>
</tr>
<?php endforeach; if (!$late): ?>
<tr><td colspan="7" class="muted">Nenhum inadimplente neste critério.</td></tr>
<?php endif; ?>
</table></div>
<?php
}
page_footer();
