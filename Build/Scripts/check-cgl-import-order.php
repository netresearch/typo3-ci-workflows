<?php

/*
 * Checks the import order that the shared PHP-CS-Fixer rules produce: class
 * imports first, then `use function`, then `use const`, each group sorted
 * alphabetically. A rule entry in rules.php replaces the whole configuration
 * the base sets give that rule, so an `ordered_imports` entry without
 * `imports_order` sorts function imports in between the class imports.
 *
 * Usage: php Build/Scripts/check-cgl-import-order.php
 */

declare(strict_types=1);

$package = dirname(__DIR__, 2);
$root    = sys_get_temp_dir() . '/check-cgl-import-order-' . bin2hex(random_bytes(4));

if (!mkdir($root . '/Classes', 0o777, true)) {
    fwrite(STDERR, "Cannot create {$root}" . PHP_EOL);
    exit(1);
}

file_put_contents($root . '/Classes/Probe.php', <<<'PHP'
    <?php

    declare(strict_types=1);

    namespace Acme\Probe;

    use Zeta\Thing;
    use Alpha\Other;

    final class Probe
    {
        public function run(): int
        {
            return \count([new Thing(), new Other()]) + \strlen('x') + \PHP_INT_SIZE;
        }
    }

    PHP);

file_put_contents($root . '/.php-cs-fixer.php', sprintf(
    "<?php\n\$factory = require %s;\n\nreturn \$factory('Test header', %s);\n",
    var_export($package . '/config/php-cs-fixer/config.php', true),
    var_export($root, true),
));

$process = proc_open(
    [PHP_BINARY, $package . '/vendor/bin/php-cs-fixer', 'fix', '--config=' . $root . '/.php-cs-fixer.php', '--allow-risky=yes', '--using-cache=no', '--quiet'],
    [1 => ['pipe', 'w'], 2 => ['redirect', 1]],
    $pipes,
);
$output = stream_get_contents($pipes[1]);
fclose($pipes[1]);
$exitCode = proc_close($process);

$uses = preg_grep('/^use /', explode("\n", (string) file_get_contents($root . '/Classes/Probe.php')));

unlink($root . '/Classes/Probe.php');
unlink($root . '/.php-cs-fixer.php');
rmdir($root . '/Classes');
rmdir($root);

if ($exitCode !== 0) {
    fwrite(STDERR, "php-cs-fixer exited with {$exitCode}:" . PHP_EOL . $output . PHP_EOL);
    exit(1);
}

$expected = [
    'use Alpha\Other;',
    'use Zeta\Thing;',
    'use function count;',
    'use function strlen;',
    'use const PHP_INT_SIZE;',
];

if (array_values($uses) !== $expected) {
    fwrite(STDERR, 'FAIL import order is' . PHP_EOL . '  ' . implode(PHP_EOL . '  ', $uses) . PHP_EOL);
    fwrite(STDERR, 'expected' . PHP_EOL . '  ' . implode(PHP_EOL . '  ', $expected) . PHP_EOL);
    exit(1);
}

echo 'php-cs-fixer import order: OK' . PHP_EOL;
