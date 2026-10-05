<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require_role('admin');

$pdo = db();

/** Valor para LIKE '%x%' com escape de \ % _ */
function like_contains(string $s): string
{
    return '%' . str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], $s) . '%';
}

$f = [
    'action' => mb_substr(trim((string)($_GET['action'] ?? '')), 0, 64),
    'target' => mb_substr(trim((string)($_GET['target'] ?? '')), 0, 128),
    'admin'  => mb_substr(trim((string)($_GET['admin'] ?? '')), 0, 64),
    'from'   => trim((string)($_GET['from'] ?? '')),
    'to'     => trim((string)($_GET['to'] ?? '')),
];
$err = '';
foreach (['from', 'to'] as $k) {
    if ($f[$k] !== '' && !valid_date($f[$k])) {
        $err = 'Data inválida (use AAAA-MM-DD).';
        $f[$k] = '';
    }
}

$where = [];
$args = [];
if ($f['action'] !== '') {
    $where[] = 'action = ?';
    $args[] = $f['action'];
}
if ($f['target'] !== '') {
    $where[] = 'target LIKE ?';
    $args[] = like_contains($f['target']);
}
if ($f['admin'] !== '') {
    $where[] = 'admin_name LIKE ?';
    $args[] = like_contains($f['admin']);
}
if ($f['from'] !== '') {
    $where[] = 'ts >= ?';
    $args[] = $f['from'] . ' 00:00:00';
}
if ($f['to'] !== '') {
    $where[] = 'ts < DATE_ADD(?, INTERVAL 1 DAY)';
    $args[] = $f['to'] . ' 00:00:00';
}
$w = $where ? ' WHERE ' . implode(' AND ', $where) : '';

$st = $pdo->prepare('SELECT COUNT(*) FROM panel_audit' . $w);
$st->execute($args);
$total = (int)$st->fetchColumn();

$page = max(1, min(1000000, (int)($_GET['page'] ?? 1)));
$st = $pdo->prepare('SELECT id, ts, admin_name, ip, action, target, detail FROM panel_audit' . $w
    . ' ORDER BY id DESC LIMIT ' . PER_PAGE . ' OFFSET ' . page_offset($page));
$st->execute($args);
$rows = $st->fetchAll();

$actions = $pdo->query('SELECT DISTINCT action FROM panel_audit ORDER BY action')->fetchAll(PDO::FETCH_COLUMN);

page_header('Auditoria', 'audit', ['css' => ['admin.css']]);
if ($err) {
    echo '<div class="flash err">' . h($err) . '</div>';
}
?>
<div class="card">
<form method="get" class="row">
  <label>Ação<select name="action"><option value="">(todas)</option>
    <?php foreach ($actions as $a): ?><option value="<?= h($a) ?>"<?= $a === $f['action'] ? ' selected' : '' ?>><?= h($a) ?></option><?php endforeach; ?>
  </select></label>
  <label>Alvo contém<input name="target" maxlength="128" value="<?= h($f['target']) ?>"></label>
  <label>Administrador<input name="admin" maxlength="64" value="<?= h($f['admin']) ?>"></label>
  <label>De<input type="date" name="from" value="<?= h($f['from']) ?>"></label>
  <label>Até<input type="date" name="to" value="<?= h($f['to']) ?>"></label>
  <button>Filtrar</button> <a href="audit.php">Limpar</a>
</form>
</div>
<p class="muted"><?= $total ?> registro(s). Somente leitura.</p>
<div class="scroll"><table>
<tr><th>Data</th><th>Administrador</th><th>IP</th><th>Ação</th><th>Alvo</th><th>Detalhe</th></tr>
<?php foreach ($rows as $r): ?>
<tr>
  <td class="nowrap"><?= h($r['ts']) ?></td><td><?= h($r['admin_name']) ?></td><td class="nowrap"><?= h($r['ip']) ?></td>
  <td><?= h($r['action']) ?></td><td><?= h($r['target']) ?></td><td class="detail"><?= h($r['detail']) ?></td>
</tr>
<?php endforeach; if (!$rows): ?>
<tr><td colspan="6" class="muted">Nenhum registro.</td></tr>
<?php endif; ?>
</table></div>
<?php
$q = http_build_query(array_filter($f, fn($v) => $v !== ''));
pager($total, $page, $q === '' ? 'p=1' : $q);
page_footer();
