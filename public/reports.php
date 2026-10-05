<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/reports_query.php';
require __DIR__ . '/../lib/chart.php';
$admin = require_role('viewer');

$pdo = db();
$reports = rq_reports();
$tab = (string)($_GET['tab'] ?? 'dia');
if (!isset($reports[$tab])) {
    $tab = 'dia';
}
$f = rq_filters($_GET);
$canExport = role_at_least($admin, 'operator');

$fq = http_build_query(['from' => $f['from'], 'to' => $f['to'], 'user' => $f['user'], 'nas' => $f['nas'], 'plan' => $f['plan']]);

$err = null;
$rows = [];
try {
    $rows = rq_rows($pdo, $tab, $f);
    $plans = ru_plans($pdo);
    $nasList = $pdo->query('SELECT nasname, shortname FROM nas ORDER BY nasname LIMIT 500')->fetchAll();
} catch (Throwable $e) {
    $err = friendly_error($e, 'reports');
    $plans = [];
    $nasList = [];
}

page_header('Relatórios', 'reports', ['css' => ['reports.css']]);
if ($err) {
    echo '<div class="flash err">' . h($err) . '</div>';
}
if ($f['swapped']) {
    echo '<div class="flash err">Período invertido: as datas foram trocadas.</div>';
}
if ($f['clamped']) {
    echo '<div class="flash err">Período limitado a ' . RQ_MAX_DAYS . ' dias.</div>';
}

// --- filtros
echo '<form method="get" class="row gap"><input type="hidden" name="tab" value="' . h($tab) . '">'
    . '<label>De<input type="date" name="from" value="' . h($f['from']) . '"></label>'
    . '<label>Até<input type="date" name="to" value="' . h($f['to']) . '"></label>'
    . '<label>Usuário (exato ou prefixo*)<input name="user" maxlength="64" value="' . h($f['user']) . '"></label>'
    . '<label>NAS<select name="nas"><option value="">(todos)</option>';
$seen = false;
foreach ($nasList as $n) {
    $sel = $n['nasname'] === $f['nas'];
    $seen = $seen || $sel;
    echo '<option value="' . h($n['nasname']) . '"' . ($sel ? ' selected' : '') . '>'
        . h($n['nasname'] . ($n['shortname'] ? ' (' . $n['shortname'] . ')' : '')) . '</option>';
}
if ($f['nas'] !== '' && !$seen) {
    echo '<option value="' . h($f['nas']) . '" selected>' . h($f['nas']) . '</option>';
}
echo '</select></label><label>Plano<select name="plan"><option value="">(todos)</option>';
$seen = false;
foreach ($plans as $p) {
    $seen = $seen || $p === $f['plan'];
    echo '<option value="' . h($p) . '"' . ($p === $f['plan'] ? ' selected' : '') . '>' . h($p) . '</option>';
}
if ($f['plan'] !== '' && !$seen) {
    echo '<option value="' . h($f['plan']) . '" selected>' . h($f['plan']) . '</option>';
}
echo '</select></label><button>Filtrar</button></form>';

// --- abas
echo '<nav class="tabs noprint">';
foreach ($reports as $k => $l) {
    echo '<a' . ($k === $tab ? ' class="on"' : '') . ' href="?tab=' . h($k) . '&amp;' . h($fq) . '">' . h($l) . '</a>';
}
echo '</nav>';

$cols = rq_columns($tab);
$fromD = date('d/m/Y', strtotime($f['from']));
$toD = date('d/m/Y', strtotime($f['to']));
if ($tab === 'mes') {
    echo '<p class="muted">Últimos 12 meses até o mês de ' . h(date('m/Y', strtotime($f['to'])))
        . ' (o período De/Até não se aplica).</p>';
} else {
    echo '<p class="muted">Período: ' . h($fromD) . ' a ' . h($toD) . '.'
        . ($tab === 'rejeicoes' ? ' Filtro de NAS não se aplica (radpostauth não guarda o NAS).' : '')
        . ($tab === 'top' ? ' Upload = bytes enviados pelo cliente; Download = bytes recebidos.' : '') . '</p>';
}

// --- gráfico
$byKey = [];
foreach ($rows as $r) {
    $byKey[$r[$cols[0][0]]] = $r;
}
$chart = null;
if ($tab === 'dia' || $tab === 'mes') {
    $labels = [];
    $up = [];
    $down = [];
    if ($tab === 'dia') {
        $t = strtotime($f['from']);
        $end = strtotime($f['to']);
        for ($i = 0; $t <= $end && $i < RQ_MAX_DAYS + 1; $i++, $t = strtotime('+1 day', $t)) {
            $k = date('Y-m-d', $t);
            $labels[] = date('d/m', $t);
            $up[] = $byKey[$k]['up'] ?? 0;
            $down[] = $byKey[$k]['down'] ?? 0;
        }
    } else {
        $t = strtotime(rq_month_start($f['to']));
        for ($i = 0; $i < 12; $i++, $t = strtotime('+1 month', $t)) {
            $k = date('Y-m', $t);
            $labels[] = date('m/Y', $t);
            $up[] = $byKey[$k]['up'] ?? 0;
            $down[] = $byKey[$k]['down'] ?? 0;
        }
    }
    $chart = chart_bars(
        [['name' => 'Upload', 'class' => 'bar-up', 'values' => $up], ['name' => 'Download', 'class' => 'bar-down', 'values' => $down]],
        $labels,
        ['title' => $reports[$tab] . ': upload e download', 'fmt' => fn(float $n): string => fmt_bytes((int)$n)]
    );
} elseif ($tab === 'hora') {
    $labels = [];
    $vals = [];
    for ($i = 0; $i < 24; $i++) {
        $k = sprintf('%02d', $i);
        $labels[] = $k . 'h';
        $vals[] = $byKey[$k]['sessoes'] ?? 0;
    }
    $chart = chart_bars([['name' => 'Sessões', 'class' => 'bar-up', 'values' => $vals]], $labels,
        ['title' => 'Sessões iniciadas por hora do dia']);
}
if ($chart !== null) {
    echo '<div class="card">' . $chart . '</div>';
}

// --- tabela
$totals = [];
foreach ($cols as [$k, , $type]) {
    $totals[$k] = 0;
}
echo '<div class="scroll"><table><thead><tr>';
foreach ($cols as [, $label, $type]) {
    echo '<th' . ($type === 'text' ? '' : ' class="num"') . '>' . h($label) . '</th>';
}
echo '</tr></thead><tbody>';
foreach ($rows as $r) {
    echo '<tr>';
    foreach ($cols as [$k, , $type]) {
        $v = $r[$k];
        if ($type === 'int' || $type === 'bytes' || $type === 'secs') {
            $totals[$k] += $v;
        }
        $txt = match ($type) {
            'bytes' => fmt_bytes($v),
            'secs'  => fmt_secs($v),
            'int', 'cnt' => number_format($v, 0, ',', '.'),
            default => $k === 'dia' ? date('d/m/Y', strtotime($v)) : (string)$v,
        };
        echo '<td' . ($type === 'text' ? '' : ' class="num"') . '>' . h($txt) . '</td>';
    }
    echo '</tr>';
}
if (!$rows) {
    echo '<tr><td colspan="' . count($cols) . '" class="muted">Sem dados para o período e filtros escolhidos.</td></tr>';
}
echo '</tbody>';
if ($rows) {
    echo '<tfoot><tr>';
    foreach ($cols as $i => [$k, , $type]) {
        if ($i === 0) {
            echo '<td>Total</td>';
        } elseif ($type === 'int') {
            echo '<td class="num">' . h(number_format($totals[$k], 0, ',', '.')) . '</td>';
        } elseif ($type === 'bytes') {
            echo '<td class="num">' . h(fmt_bytes($totals[$k])) . '</td>';
        } elseif ($type === 'secs') {
            echo '<td class="num">' . h(fmt_secs($totals[$k])) . '</td>';
        } else {
            echo '<td></td>';
        }
    }
    echo '</tr></tfoot>';
}
echo '</table></div>';
if (count($rows) >= RQ_VIEW_LIMIT) {
    echo '<p class="muted">Exibindo as primeiras ' . RQ_VIEW_LIMIT . ' linhas. A exportação traz até '
        . number_format(RQ_EXPORT_LIMIT, 0, ',', '.') . '.</p>';
}

// --- exportação (operador ou superior; POST + CSRF)
if ($canExport) {
    echo '<form method="post" action="export.php" class="export noprint">' . csrf_field()
        . '<input type="hidden" name="report" value="' . h($tab) . '">'
        . '<input type="hidden" name="from" value="' . h($f['from']) . '">'
        . '<input type="hidden" name="to" value="' . h($f['to']) . '">'
        . '<input type="hidden" name="user" value="' . h($f['user']) . '">'
        . '<input type="hidden" name="nas" value="' . h($f['nas']) . '">'
        . '<input type="hidden" name="plan" value="' . h($f['plan']) . '">'
        . '<button>Exportar CSV</button></form>';
}
page_footer();
