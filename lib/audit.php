<?php
declare(strict_types=1);

const AUDIT_SECRET_KEYS = ['password', 'pass', 'secret', 'senha', 'token', 'code', 'codigo', 'voucher_password'];

/** Remove valores sensíveis antes de gravar no log de auditoria. */
function audit_scrub(array $detail): array
{
    foreach ($detail as $k => $v) {
        if (is_array($v)) {
            $detail[$k] = audit_scrub($v);
        } elseif (in_array(strtolower((string)$k), AUDIT_SECRET_KEYS, true)) {
            $detail[$k] = '***';
        }
    }
    return $detail;
}

/**
 * Registra uma ação. Nunca grava senhas/segredos. Falha de auditoria não derruba a ação,
 * mas fica no log do servidor.
 */
function audit(string $action, string $target = '', array $detail = [], ?string $actor = null): void
{
    try {
        $admin = function_exists('current_admin') ? current_admin() : null;
        $json = $detail ? json_encode(audit_scrub($detail), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) : null;
        db()->prepare(
            'INSERT INTO panel_audit (admin_id, admin_name, ip, action, target, detail) VALUES (?, ?, ?, ?, ?, ?)'
        )->execute([
            $admin['id'] ?? null,
            mb_substr($actor ?? ($admin['username'] ?? '-'), 0, 64),
            client_ip(),
            mb_substr($action, 0, 64),
            mb_substr($target, 0, 128),
            $json !== null ? mb_substr($json, 0, 2000) : null,
        ]);
    } catch (Throwable $e) {
        log_exception($e, 'audit');
    }
}
