<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/customers.php';
require_role('operator');
require_post();
header('Content-Type: application/json; charset=utf-8');

// Limite simples por sessão: 15 consultas por minuto (a BrasilAPI é pública e compartilhada).
$now = time();
$hits = array_values(array_filter((array)($_SESSION['cnpj_hits'] ?? []), fn($t) => $now - (int)$t < 60));
if (count($hits) >= 15) {
    http_response_code(429);
    echo json_encode(['ok' => false, 'error' => 'Muitas consultas. Aguarde um minuto.']);
    exit;
}
$hits[] = $now;
$_SESSION['cnpj_hits'] = $hits;

try {
    $data = cust_cnpj_lookup(cust_doc_digits(post('cnpj')));
    echo json_encode(['ok' => true, 'data' => $data], JSON_UNESCAPED_UNICODE);
} catch (Throwable $e) {
    http_response_code($e instanceof RuntimeException ? 422 : 500);
    echo json_encode(['ok' => false, 'error' => friendly_error($e, 'cnpj_lookup')], JSON_UNESCAPED_UNICODE);
}
