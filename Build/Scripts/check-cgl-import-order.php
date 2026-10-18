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

require_once __DIR__ . '/cgl-probe.php';

$fixed = cglProbe(<<<'PHP'
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

$uses = preg_grep('/^use /', explode("\n", $fixed));

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
