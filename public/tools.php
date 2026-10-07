<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/mikrotik.php';
require_role('admin');

/**
 * Confere o que o painel já sabe deste equipamento (cadastro em `nas` pelo nome curto) sem expor o segredo:
 * ['found' => bool, 'secret_ok' => bool, 'ip' => string, 'last' => ?string (último accounting)].
 */
function nas_check(PDO $pdo, string $name, string $secret): array
{
    $q = $pdo->prepare('SELECT nasname, secret FROM nas WHERE shortname = ?');
    $q->execute([$name]);
    $row = $q->fetch();
    if (!$row) {
        return ['found' => false, 'secret_ok' => false, 'ip' => '', 'last' => null];
    }
    $ip = (string)$row['nasname'];
    $last = null;
    if (filter_var($ip, FILTER_VALIDATE_IP) !== false) {
        $a = $pdo->prepare('SELECT MAX(COALESCE(acctupdatetime, acctstarttime)) FROM radacct WHERE nasipaddress = ?');
        $a->execute([$ip]);
        $v = $a->fetchColumn();
        $last = ($v === false || $v === null) ? null : (string)$v;
    }
    return ['found' => true, 'secret_ok' => hash_equals((string)$row['secret'], $secret), 'ip' => $ip, 'last' => $last];
}

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
    'incoming' => true, 'coa_port' => '3799', 'hotspot_profile' => '', 'src_address' => '', 'firewall' => true,
];
$check = null;   // verificação do cadastro do equipamento (só depois de gerar)

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
            'src_address' => (string)($_POST['src_address'] ?? ''),
            'firewall' => !empty($_POST['firewall']),
        ];
        try {
            $script = mikrotik_script($in);
            $v = mikrotik_validate($in);
            // Nunca registra o segredo nem o script.
            audit('tools.mikrotik', $v['name'], ['server' => $v['server_ip'], 'services' => implode(',', $v['services'])]);
            $check = nas_check(db(), $v['name'], $v['secret']);
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

page_header('Ferramentas', 'tools', ['css' => ['admin.css', 'tools.css']]);
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
    <label>Segredo<input name="secret" id="mt-secret" required minlength="8" maxlength="64" autocomplete="new-password"></label>
    <label>&nbsp;<button type="button" class="secondary" data-gensecret="mt-secret">Gerar segredo forte</button></label>
    <label>Nome do equipamento<input name="name" maxlength="32" placeholder="loja-centro" value="<?= h((string)$in['name']) ?>"></label>
    <label>Perfil de hotspot (vazio = todos os perfis)<input name="hotspot_profile" maxlength="32" value="<?= h((string)$in['hotspot_profile']) ?>"></label>
    <label>IP do túnel WireGuard deste roteador (vazio = sem túnel)<input name="src_address" maxlength="15" placeholder="10.99.0.2" value="<?= h((string)$in['src_address']) ?>"></label>
  </div>
  <p class="muted">Use um segredo diferente em cada equipamento; ele precisa ser o mesmo cadastrado em Equipamentos.
  O botão gera o segredo no seu navegador, sem enviá-lo ao servidor.</p>
  <div class="checks gap">
    <label><input type="checkbox" name="services[]" value="hotspot"<?= in_array('hotspot', $services, true) ? ' checked' : '' ?>> Hotspot</label>
    <label><input type="checkbox" name="services[]" value="ppp"<?= in_array('ppp', $services, true) ? ' checked' : '' ?>> PPP</label>
    <label><input type="checkbox" name="accounting" value="1"<?= $in['accounting'] ? ' checked' : '' ?>> Contabilidade (accounting)</label>
    <label><input type="checkbox" name="incoming" value="1"<?= $in['incoming'] ? ' checked' : '' ?>> Aceitar CoA/desconexão (/radius incoming)</label>
    <label><input type="checkbox" name="firewall" value="1"<?= $in['firewall'] ? ' checked' : '' ?>> Gerar regra de firewall do CoA (só do servidor)</label>
  </div>
  <details class="gap">
    <summary>Avançado (portas e interim-update)</summary>
    <div class="row gap">
      <label>Porta de autenticação<input name="auth_port" class="narrow" value="<?= h((string)$in['auth_port']) ?>"></label>
      <label>Porta de contabilidade<input name="acct_port" class="narrow" value="<?= h((string)$in['acct_port']) ?>"></label>
      <label>Interim-update (min)<input name="interim" class="narrow" value="<?= h((string)$in['interim']) ?>"></label>
      <label>Porta CoA<input name="coa_port" class="narrow" value="<?= h((string)$in['coa_port']) ?>"></label>
    </div>
    <p class="muted">Interim-update menor atualiza o consumo mais rápido, mas gera mais gravações no banco;
    5, 10 ou 15 minutos atendem a maioria dos casos.</p>
  </details>
  <button>Gerar script</button>
</form>
</div>
<?php if ($script !== null): ?>
<h2>Script gerado</h2>
<pre data-copy><?= h($script) ?></pre>
<p><button type="button" class="secondary" data-download="pre[data-copy]" data-filename="radpanel-<?= h((string)$in['name'] !== '' ? (string)$in['name'] : 'radpanel') ?>.rsc">Baixar .rsc</button></p>
<?php if ($check !== null): ?>
<h2>Conferência no painel</h2>
<div class="card">
<ul class="checklist">
<?php if (!$check['found']): ?>
  <li><span class="tag bad">falta</span> Nenhum equipamento cadastrado com o nome curto "<?= h((string)$in['name'] !== '' ? (string)$in['name'] : 'radpanel') ?>". Cadastre em <a href="nas.php">Equipamentos</a> antes de aplicar o script.</li>
<?php else: ?>
  <li><span class="tag good">ok</span> Equipamento cadastrado (IP <span class="mono"><?= h($check['ip']) ?></span>).</li>
  <li><?= $check['secret_ok'] ? '<span class="tag good">ok</span> O segredo informado é o mesmo do cadastro.' : '<span class="tag bad">diferente</span> O segredo informado NÃO é o do cadastro: o RADIUS vai recusar este roteador.' ?></li>
  <li><?php if ($check['last'] === null): ?><span class="tag bad">sem sinal</span> Nenhum accounting recebido deste equipamento ainda.
    <?php else: $ago = max(0, time() - (int)strtotime($check['last'])); ?><span class="tag <?= $ago > 3600 ? 'bad' : 'good' ?>"><?= $ago > 3600 ? 'antigo' : 'ok' ?></span> Último accounting há <?= h(fmt_age($ago)) ?>.<?php endif; ?></li>
<?php endif; ?>
</ul>
</div>
<?php endif; ?>
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
<?php page_footer(['js' => ['tools.js']]);
