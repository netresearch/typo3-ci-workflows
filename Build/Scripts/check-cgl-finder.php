<?php

/*
 * Checks which files the shared PHP-CS-Fixer config factory hands to the
 * fixer, in PHP-CS-Fixer 3's default mode and in future mode. Future mode
 * turns on the defaults planned for PHP-CS-Fixer 4, which stops skipping dot
 * directories, so an exclude that only works because of that default fails
 * here before it fails in a consumer.
 *
 * Usage: php Build/Scripts/check-cgl-finder.php
 */

declare(strict_types=1);

require_once __DIR__ . '/../../vendor/autoload.php';

$factory = require_once __DIR__ . '/../../config/php-cs-fixer/config.php';

$root = sys_get_temp_dir() . '/check-cgl-finder-' . bin2hex(random_bytes(4));

$tree = [
    // Scanned: the extension's own code.
    'Classes/A.php'                 => true,
    'Tests/Unit/ATest.php'          => true,
    'ext_localconf.php'             => true,
    'Resources/Public/Php/Kept.php' => true,
    // Excluded by the shared list.
    '.Build/vendor/acme/B.php' => false,
    '.Build/public/index.php'  => false,
    // Covered by no exclude but .Build itself (vendor and public are
    // excluded by name, so the two cases above would pass without it).
    '.Build/bin/L.php'           => false,
    '.build/vendor/acme/C.php'   => false,
    '.build/bin/D.php'           => false,
    '.ddev/commands/web/E.php'   => false,
    '.pnpm-store/v3/F.php'       => false,
    'config/system/settings.php' => false,
    'node_modules/pkg/G.php'     => false,
    'public/index.php'           => false,
    'var/cache/H.php'            => false,
    'vendor/acme/I.php'          => false,
    'ext_emconf.php'             => false,
    // Excluded only through the fourth argument.
    'packages/site/J.php'            => false,
    'Tests/Fixtures/generated/K.php' => false,
];

foreach (array_keys($tree) as $path) {
    $file = $root . '/' . $path;
    if (!is_dir(dirname($file)) && !mkdir(dirname($file), 0o777, true)) {
        fwrite(STDERR, "Cannot create the directory for {$path}" . PHP_EOL);
        exit(1);
    }
    file_put_contents($file, "<?php\n");
}

$failures = 0;
$checks   = 0;

foreach (['default' => false, 'future' => true] as $mode => $future) {
    putenv('PHP_CS_FIXER_FUTURE_MODE' . ($future ? '=1' : ''));

    $config = $factory('Test header', $root, [], ['packages', 'Tests/Fixtures/generated']);
    $seen   = [];
    foreach ($config->getFinder() as $file) {
        $seen[] = str_replace('\\', '/', substr($file->getPathname(), strlen($root) + 1));
    }

    foreach ($tree as $path => $scanned) {
        ++$checks;
        if (in_array($path, $seen, true) !== $scanned) {
            ++$failures;
            fwrite(STDERR, sprintf('FAIL [%s] %s should %sbe scanned' . PHP_EOL, $mode, $path, $scanned ? '' : 'not '));
        }
    }
}

putenv('PHP_CS_FIXER_FUTURE_MODE');

$files = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
    RecursiveIteratorIterator::CHILD_FIRST,
);
foreach ($files as $file) {
    $file->isDir() ? rmdir($file->getPathname()) : unlink($file->getPathname());
}
rmdir($root);

if ($failures > 0) {
    fwrite(STDERR, "{$failures} of {$checks} checks failed" . PHP_EOL);
    exit(1);
}

echo "php-cs-fixer finder: {$checks} of {$checks} checks pass" . PHP_EOL;
