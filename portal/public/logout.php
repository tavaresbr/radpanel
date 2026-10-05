<?php
declare(strict_types=1);
require __DIR__ . '/../lib/portal.php';
require_post();
cust_destroy();
redirect('login.php');
