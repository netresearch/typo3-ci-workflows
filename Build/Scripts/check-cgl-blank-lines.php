<?php

/*
 * Checks that the shared PHP-CS-Fixer rules collapse a run of blank lines
 * inside a method body. @PER-CS3x0 comes after @Symfony in rules.php and sets
 * `no_extra_blank_lines` to the `use` token only, so without the explicit
 * entry in rules.php such runs stay.
 *
 * Usage: php Build/Scripts/check-cgl-blank-lines.php
 */

declare(strict_types=1);

$fixed = (require __DIR__ . '/cgl-probe.php')(<<<'PHP'
    <?php

    declare(strict_types=1);

    namespace Acme\Probe;

    final class Probe
    {
        public function run(): int
        {
            $a = 1;



            return $a;
        }
    }

    PHP);

if (!str_contains($fixed, "\$a = 1;\n\n        return \$a;")) {
    fwrite(STDERR, 'FAIL the run of blank lines was not collapsed:' . PHP_EOL . $fixed);
    exit(1);
}

echo 'php-cs-fixer blank lines: OK' . PHP_EOL;
