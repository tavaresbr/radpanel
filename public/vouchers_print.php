<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
$admin = require_role('operator');

$batch = (int)($_GET['batch'] ?? 0);
$data = $_SESSION['voucher_print'][$batch] ?? null;
// Exibe uma única vez: apaga da sessão antes de renderizar.
unset($_SESSION['voucher_print'][$batch]);

page_header('Vouchers do lote #' . $batch, 'vouchers', ['bare' => true, 'css' => ['vouchers.css']]);
if (!$data):
?>
<p class="muted">Estes códigos já foram exibidos e não podem ser vistos de novo. Gere um novo lote se precisar.</p>
<p><a href="vouchers.php">Voltar aos vouchers</a></p>
<?php else: ?>
<p class="noprint"><button type="button" data-print>Imprimir</button> <a href="vouchers.php">Voltar</a>
  — esta página só é exibida uma vez; imprima ou salve agora.</p>
<div class="vgrid">
<?php foreach ($data['codes'] as [$u, $p]): ?>
  <div class="vcard">
    <div class="vtitle"><?= h($data['label'] !== '' ? $data['label'] : 'Acesso Wi-Fi') ?></div>
    <div>Usuário: <b class="mono"><?= h($u) ?></b></div>
    <div>Senha: <b class="mono"><?= h($p) ?></b></div>
    <div class="vmeta"><?= h($data['plan']) ?><?= $data['minutes'] ? ' · ' . (int)$data['minutes'] . ' min após o 1º login' : '' ?><?= $data['expires'] ? ' · válido até ' . h(date('d/m/Y', strtotime($data['expires']))) : '' ?></div>
  </div>
<?php endforeach; ?>
</div>
<?php endif;
page_footer(['js' => ['vouchers.js']]);
