<?php

/*
 * Runs the shared PHP-CS-Fixer config factory on one probe file and returns
 * the fixed source. Used by the check-cgl-*.php scripts that pin what the
 * shared rules do to a piece of code.
 *
 * Usage: $fixed = (require __DIR__ . '/cgl-probe.php')($source);
 * Exits with 1 when php-cs-fixer fails.
 */

declare(strict_types=1);

return static function (string $source): string {
    $package = dirname(__DIR__, 2);
    $root    = sys_get_temp_dir() . '/check-cgl-probe-' . bin2hex(random_bytes(4));

    if (!mkdir($root . '/Classes', 0o777, true)) {
        fwrite(STDERR, "Cannot create {$root}" . PHP_EOL);
        exit(1);
    }

    file_put_contents($root . '/Classes/Probe.php', $source);
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

    return $fixed;
};
