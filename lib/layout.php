<?php
declare(strict_types=1);

/** Páginas do menu: arquivo => [rótulo, papel mínimo]. Só aparecem se o arquivo existir. */
const NAV_ITEMS = [
    'setup'     => ['Ativar equipamento', 'admin'],
    'dashboard' => ['Início', 'viewer'],
    'users'     => ['Usuários', 'viewer'],
    'vouchers'  => ['Vouchers', 'operator'],
    'plans'     => ['Planos', 'viewer'],
    'sessions'  => ['Sessões', 'viewer'],
    'reports'   => ['Relatórios', 'viewer'],
    'customers' => ['Clientes', 'operator'],
    'nas'       => ['Equipamentos', 'admin'],
    'wireguard' => ['VPN WireGuard', 'admin'],
    'tools'     => ['Ferramentas', 'admin'],
    'admins'    => ['Administradores', 'admin'],
    'audit'     => ['Auditoria', 'admin'],
];

/**
 * $opts: 'css' => ['arquivo.css', ...] (arquivos em public/), 'js' => ['arquivo.js', ...], 'bare' => true (sem menu).
 */
function page_header(string $title, string $active = '', array $opts = []): void
{
    $admin = current_admin();
    echo '<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">';
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">';
    echo '<title>' . h($title) . ' · RadPanel</title><link rel="stylesheet" href="style.css">';
    foreach ((array)($opts['css'] ?? []) as $css) {
        echo '<link rel="stylesheet" href="' . h($css) . '">';
    }
    echo '</head><body>';
    if (empty($opts['bare']) && $admin) {
        echo '<header class="noprint"><strong>RadPanel</strong><nav>';
        foreach (NAV_ITEMS as $k => [$label, $min]) {
            if (!role_at_least($admin, $min) || !is_file(__DIR__ . '/../public/' . $k . '.php')) {
                continue;
            }
            echo '<a' . ($k === $active ? ' class="on"' : '') . ' href="' . $k . '.php">' . h($label) . '</a>';
        }
        echo '</nav><form method="post" action="logout.php">' . csrf_field()
            . '<button class="link">Sair (' . h($admin['username']) . ' · ' . h(role_label($admin['role'])) . ')</button></form></header>';
    }
    echo '<main>';
    if (!empty($_SESSION['flash'])) {
        [$type, $msg] = $_SESSION['flash'];
        unset($_SESSION['flash']);
        echo '<div class="flash ' . h($type) . '">' . h($msg) . '</div>';
    }
    echo '<h1>' . h($title) . '</h1>';
}

function page_footer(array $opts = []): void
{
    echo '</main><script src="app.js"></script>';
    foreach ((array)($opts['js'] ?? []) as $js) {
        echo '<script src="' . h($js) . '"></script>';
    }
    echo '</body></html>';
}

function flash_redirect(string $msg, string $type, string $to): never
{
    flash($msg, $type);
    redirect($to);
}

/** Paginação com janela (não gera uma ligação por página). */
function pager(int $total, int $page, string $baseQuery): void
{
    $pages = max(1, (int)ceil($total / PER_PAGE));
    if ($pages <= 1) {
        return;
    }
    $show = array_unique(array_filter(
        array_merge([1, $pages], range(max(1, $page - 2), min($pages, $page + 2))),
        fn($p) => $p >= 1 && $p <= $pages
    ));
    sort($show);
    echo '<p class="pager">';
    $prev = 0;
    foreach ($show as $i) {
        if ($prev && $i > $prev + 1) {
            echo '… ';
        }
        echo '<a' . ($i === $page ? ' class="on"' : '') . ' href="?' . h($baseQuery) . '&amp;page=' . $i . '">' . $i . '</a> ';
        $prev = $i;
    }
    echo '</p>';
}

function page_offset(int $page): int
{
    return (max(1, min($page, 1000000)) - 1) * PER_PAGE;
}

function plan_select(array $plans, string $sel = '', string $name = 'plan'): string
{
    $o = '<option value="">(sem plano)</option>';
    foreach ($plans as $p) {
        $o .= '<option value="' . h($p) . '"' . ($p === $sel ? ' selected' : '') . '>' . h($p) . '</option>';
    }
    return '<select name="' . h($name) . '">' . $o . '</select>';
}
