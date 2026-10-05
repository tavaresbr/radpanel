<?php
declare(strict_types=1);
require __DIR__ . '/../lib/portal.php';
redirect(current_customer() ? 'dashboard.php' : 'login.php');
