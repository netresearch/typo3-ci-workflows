<?php

/*
 * Runs the shared PHP-CS-Fixer config factory on one probe file and returns
 * the fixed source. Used by the check-cgl-*.php scripts that pin what the
 * shared rules do to a piece of code.
 *
 * Usage: require_once __DIR__ . '/cgl-probe.php'; $fixed = cglProbe($source);
 * Exits with 1 when php-cs-fixer fails.
 */

declare(strict_types=1);

function cglProbe(string $source): string
{
    $package = dirname(__DIR__, 2);
    $root    = sys_get_temp_dir() . '/check-cgl-probe-' . bin2hex(random_bytes(4));

    if (!mkdir($root . '/Classes', 0o777, true)) {
        fwrite(STDERR, "Cannot create {$root}" . PHP_EOL);
        exit(1);
    }

    $probe  = $root . '/Classes/Probe.php';
    $config = $root . '/.php-cs-fixer.php';

    $cleanUp = static function () use ($root, $probe, $config): void {
        unlink($probe);
        unlink($config);
        rmdir($root . '/Classes');
        rmdir($root);
    };

    file_put_contents($probe, $source);
    file_put_contents($config, sprintf(
        "<?php\n\$factory = require %s;\n\nreturn \$factory('Test header', %s);\n",
        var_export($package . '/config/php-cs-fixer/config.php', true),
        var_export($root, true),
    ));

    $process = proc_open(
        [PHP_BINARY, $package . '/vendor/bin/php-cs-fixer', 'fix', '--config=' . $config, '--allow-risky=yes', '--using-cache=no', '--quiet'],
        [1 => ['pipe', 'w'], 2 => ['redirect', 1]],
        $pipes,
    );

    if ($process === false) {
        $cleanUp();
        fwrite(STDERR, 'Cannot start php-cs-fixer' . PHP_EOL);
        exit(1);
    }

    $output = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $exitCode = proc_close($process);

    $fixed = (string) file_get_contents($probe);

    $cleanUp();

    if ($exitCode !== 0) {
        fwrite(STDERR, "php-cs-fixer exited with {$exitCode}:" . PHP_EOL . $output . PHP_EOL);
        exit(1);
    }

    return $fixed;
}
