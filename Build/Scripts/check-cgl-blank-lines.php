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

$package = dirname(__DIR__, 2);
$root    = sys_get_temp_dir() . '/check-cgl-blank-lines-' . bin2hex(random_bytes(4));

if (!mkdir($root . '/Classes', 0o777, true)) {
    fwrite(STDERR, "Cannot create {$root}" . PHP_EOL);
    exit(1);
}

file_put_contents($root . '/Classes/Probe.php', <<<'PHP'
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

$fixed = (string) file_get_contents($root . '/Classes/Probe.php');

unlink($root . '/Classes/Probe.php');
unlink($root . '/.php-cs-fixer.php');
rmdir($root . '/Classes');
rmdir($root);

if ($exitCode !== 0) {
    fwrite(STDERR, "php-cs-fixer exited with {$exitCode}:" . PHP_EOL . $output . PHP_EOL);
    exit(1);
}

if (!str_contains($fixed, "\$a = 1;\n\n        return \$a;")) {
    fwrite(STDERR, 'FAIL the run of blank lines was not collapsed:' . PHP_EOL . $fixed);
    exit(1);
}

echo 'php-cs-fixer blank lines: OK' . PHP_EOL;
