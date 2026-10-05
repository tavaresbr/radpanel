<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    if (current_admin()) {
        audit('logout', current_admin()['username']);
    }
    destroy_session();
}
redirect('login.php');
