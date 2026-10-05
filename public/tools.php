<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/mikrotik.php';
require_role('admin');

/** Último backup: ['file' => nome, 'ts' => int, 'size' => int] | null; ['error' => texto] se ilegível. */
function backup_status(string $dir): array
{
    if (!is_dir($dir) || !is_readable($dir)) {
        return ['error' => 'Diretório de backup inexistente ou sem permissão de leitura (' . $dir . ').'];
    }
    $latest = null;
    foreach (glob(rtrim($dir, '/') . '/radius-*.sql.gz') ?: [] as $f) {
        $m = @filemtime($f);
        if ($m !== false && ($latest === null || $m > $latest['ts'])) {
            $latest = ['file' => basename($f), 'ts' => $m, 'size' => (int)@filesize($f)];
        }
    }
    return $latest ?? ['error' => 'Nenhum backup encontrado em ' . $dir . '.'];
}

$script = null;
$err = '';
$in = [
    'server_ip' => (string)cfg('server_ip', ''), 'secret' => '', 'name' => '', 'services' => ['hotspot', 'ppp'],
    'auth_port' => '1812', 'acct_port' => '1813', 'accounting' => true, 'interim' => '5',
    'incoming' => true, 'coa_port' => '3799', 'hotspot_profile' => '',
];

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    if (post('action') === 'mikrotik') {
        $in = [
            'server_ip' => (string)($_POST['server_ip'] ?? ''), 'secret' => (string)($_POST['secret'] ?? ''),
            'name' => (string)($_POST['name'] ?? ''), 'services' => $_POST['services'] ?? [],
            'auth_port' => (string)($_POST['auth_port'] ?? ''), 'acct_port' => (string)($_POST['acct_port'] ?? ''),
            'accounting' => !empty($_POST['accounting']), 'interim' => (string)($_POST['interim'] ?? ''),
            'incoming' => !empty($_POST['incoming']), 'coa_port' => (string)($_POST['coa_port'] ?? ''),
            'hotspot_profile' => (string)($_POST['hotspot_profile'] ?? ''),
        ];
        try {
            $script = mikrotik_script($in);
            $v = mikrotik_validate($in);
            // Nunca registra o segredo nem o script.
            audit('tools.mikrotik', $v['name'], ['server' => $v['server_ip'], 'services' => implode(',', $v['services'])]);
        } catch (Throwable $e) {
            $err = friendly_error($e, 'tools');
        }
    } else {
        http_response_code(400);
        exit('Ação desconhecida.');
    }
}
$in['secret'] = '';   // o segredo nunca volta ao formulário
$services = is_array($in['services']) ? $in['services'] : [];

$bk = backup_status((string)cfg('backup_dir', '/var/backups/radpanel'));

page_header('Ferramentas', 'tools', ['css' => ['admin.css']]);
if ($err) {
    echo '<div class="flash err">' . h($err) . '</div>';
}
?>
<h2>Gerador de script MikroTik (RouterOS v7)</h2>
<div class="card">
<p class="muted">Gera os comandos para o MikroTik usar este servidor RADIUS. O segredo digitado só aparece no
texto gerado nesta resposta: não é gravado no banco, no log nem na auditoria. Use o mesmo segredo cadastrado
em Equipamentos. Sintaxe RouterOS 7.x; revise antes de aplicar.</p>
<form method="post" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="mikrotik">
  <div class="row gap">
    <label>IP/host do servidor RADIUS<input name="server_ip" required maxlength="253" value="<?= h((string)$in['server_ip']) ?>"></label>
    <label>Segredo<input name="secret" required minlength="8" maxlength="64" autocomplete="new-password"></label>
    <label>Nome do equipamento<input name="name" maxlength="32" placeholder="loja-centro" value="<?= h((string)$in['name']) ?>"></label>
    <label>Perfil de hotspot (vazio = padrão)<input name="hotspot_profile" maxlength="32" value="<?= h((string)$in['hotspot_profile']) ?>"></label>
  </div>
  <div class="row gap">
    <label>Porta de autenticação<input name="auth_port" class="narrow" value="<?= h((string)$in['auth_port']) ?>"></label>
    <label>Porta de contabilidade<input name="acct_port" class="narrow" value="<?= h((string)$in['acct_port']) ?>"></label>
    <label>Interim-update (min)<input name="interim" class="narrow" value="<?= h((string)$in['interim']) ?>"></label>
    <label>Porta CoA<input name="coa_port" class="narrow" value="<?= h((string)$in['coa_port']) ?>"></label>
  </div>
  <div class="checks gap">
    <label><input type="checkbox" name="services[]" value="hotspot"<?= in_array('hotspot', $services, true) ? ' checked' : '' ?>> Hotspot</label>
    <label><input type="checkbox" name="services[]" value="ppp"<?= in_array('ppp', $services, true) ? ' checked' : '' ?>> PPP</label>
    <label><input type="checkbox" name="accounting" value="1"<?= $in['accounting'] ? ' checked' : '' ?>> Contabilidade (accounting)</label>
    <label><input type="checkbox" name="incoming" value="1"<?= $in['incoming'] ? ' checked' : '' ?>> Aceitar CoA/desconexão (/radius incoming)</label>
  </div>
  <button>Gerar script</button>
</form>
</div>
<?php if ($script !== null): ?>
<h2>Script gerado</h2>
<pre><?= h($script) ?></pre>
<?php endif; ?>

<h2>Backup</h2>
<div class="card">
<?php if (isset($bk['error'])): ?>
  <p><span class="tag bad">sem backup</span> <?= h($bk['error']) ?></p>
<?php else:
    $age = time() - $bk['ts']; ?>
  <p><span class="tag <?= $age > 36 * 3600 ? 'bad' : 'good' ?>"><?= $age > 36 * 3600 ? 'desatualizado' : 'em dia' ?></span>
  Último: <span class="mono"><?= h($bk['file']) ?></span> · <?= h(date('d/m/Y H:i', $bk['ts'])) ?> · <?= h(fmt_bytes($bk['size'])) ?></p>
<?php endif; ?>
<p class="muted">Somente leitura. O backup diário roda pelo cron (<code>bin/install-backup.sh</code>).</p>
</div>
<?php page_footer();
