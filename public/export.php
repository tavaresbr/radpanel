<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/reports_query.php';
require __DIR__ . '/../lib/csv.php';

// Papel primeiro (403), depois método (405) e CSRF (400).
require_role('operator');
require_post();

$report = (string)($_POST['report'] ?? '');
if (!isset(rq_reports()[$report])) {
    http_response_code(400);
    exit('Relatório inválido.');
}
$f = rq_filters($_POST);
$cols = rq_columns($report);

$pdo = db();
try {
    $pdo->setAttribute(PDO::MYSQL_ATTR_USE_BUFFERED_QUERY, false);
    $st = rq_stmt($pdo, $report, $f, RQ_EXPORT_LIMIT);
} catch (Throwable $e) {
    http_response_code(500);
    exit(h(friendly_error($e, 'export')));
}

@set_time_limit(120);
ignore_user_abort(true);
session_write_close();
while (ob_get_level() > 0) {
    ob_end_clean();
}
header('Content-Type: text/csv; charset=utf-8');
header('Content-Disposition: attachment; filename="' . csv_filename($report) . '"');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

$out = fopen('php://output', 'w');
fwrite($out, "\xEF\xBB\xBF");
$head = [];
foreach ($cols as [, $label, $type]) {
    $head[] = $label . ($type === 'bytes' ? ' (bytes)' : ($type === 'secs' ? ' (s)' : ''));
}
csv_write($out, $head);

$n = 0;
while ($n < RQ_EXPORT_LIMIT && ($r = $st->fetch()) !== false) {
    csv_write($out, rq_row($cols, $r));
    if (++$n % 1000 === 0) {
        flush();
    }
}
$st->closeCursor();
fclose($out);

audit('report.export', $report, [
    'linhas'  => $n,
    'periodo' => $report === 'mes' ? rq_month_start($f['to']) . '..' . $f['to'] : $f['from'] . '..' . $f['to'],
    'usuario' => $f['user'],
    'nas'     => $f['nas'],
    'plano'   => $f['plan'],
]);
