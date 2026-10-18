<?php

/*
 * Checks the options of the shared Rector config factory: what each option
 * adds to the paths, sets, skips and PHP version, and that an unknown option
 * or value throws. Rector keeps its configuration in static parameters, so
 * every case runs in a process of its own.
 *
 * Usage: php Build/Scripts/check-rector-options.php
 */

declare(strict_types=1);

use Rector\Config\RectorConfig;
use Rector\Configuration\Option;
use Rector\Configuration\Parameter\SimpleParameterProvider;
use Rector\Set\ValueObject\LevelSetList;
use Rector\TypeDeclaration\Rector\Class_\TypedPropertyFromCreateMockAssignRector;
use Ssch\TYPO3Rector\Set\Typo3LevelSetList;
use Ssch\TYPO3Rector\TYPO313\v4\MigratePluginContentElementAndPluginSubtypesRector;

require_once __DIR__ . '/../../vendor/autoload.php';

if (($argv[1] ?? '') === '--case') {
    // Child: apply the factory with the given options and print what it set.
    $root      = $argv[2];
    $options   = json_decode($argv[3], true, flags: JSON_THROW_ON_ERROR);
    $configure = require_once __DIR__ . '/../../config/rector/rector.php';

    try {
        $configure(new RectorConfig(), $root, $options);
    } catch (InvalidArgumentException $e) {
        echo json_encode(['error' => $e->getMessage()], JSON_THROW_ON_ERROR);

        exit(0);
    }

    echo json_encode([
        'paths' => array_map(static fn (string $p): string => substr($p, strlen($root) + 1), SimpleParameterProvider::provideArrayParameter(Option::PATHS)),
        'sets'  => SimpleParameterProvider::provideArrayParameter(Option::REGISTERED_RECTOR_SETS),
        'skip'  => SimpleParameterProvider::provideArrayParameter(Option::SKIP),
        'php'   => SimpleParameterProvider::provideIntParameter(Option::PHP_VERSION_FEATURES),
    ], JSON_THROW_ON_ERROR);

    exit(0);
}

$root = sys_get_temp_dir() . '/check-rector-options-' . bin2hex(random_bytes(4));
foreach (['Classes', 'Configuration', 'Tests/Unit'] as $dir) {
    mkdir($root . '/' . $dir, 0o777, true);
}
file_put_contents($root . '/ext_localconf.php', "<?php\n");
file_put_contents($root . '/ext_emconf.php', "<?php\n");

$run = static function (array $options) use ($root): array {
    $cmd     = [PHP_BINARY, __FILE__, '--case', $root, json_encode($options, JSON_THROW_ON_ERROR | JSON_FORCE_OBJECT)];
    $process = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    $out     = stream_get_contents($pipes[1]);
    $err     = stream_get_contents($pipes[2]);
    $status  = proc_close($process);
    if ($status !== 0) {
        return ['crash' => trim($err . $out)];
    }

    return json_decode($out, true, flags: JSON_THROW_ON_ERROR);
};

$plugin = MigratePluginContentElementAndPluginSubtypesRector::class;
$cases  = [
    'no options: the defaults of v1.12' => [
        [],
        static fn (array $r): bool => $r['paths'] === ['Classes', 'Configuration', 'ext_emconf.php', 'ext_localconf.php']
            && $r['php'] === 80200
            && in_array(LevelSetList::UP_TO_PHP_82, $r['sets'], true)
            && !in_array($plugin, $r['skip'], true),
    ],
    'tests adds Tests/' => [
        ['tests' => true],
        static fn (array $r): bool => $r['paths'] === ['Classes', 'Configuration', 'Tests', 'ext_emconf.php', 'ext_localconf.php'],
    ],
    // The rule replaces `private Foo $foo` with `private MockObject $foo` when
    // the property is assigned createMock(). Skipped whatever the options,
    // because an extension can add Tests/ to the paths itself.
    'the mock property rule is skipped' => [
        [],
        static fn (array $r): bool => in_array(TypedPropertyFromCreateMockAssignRector::class, $r['skip'], true),
    ],
    'tests false keeps Tests/ out' => [
        ['tests' => false],
        static fn (array $r): bool => !in_array('Tests', $r['paths'], true),
    ],
    'php 8.2 sets the version and the level set' => [
        ['php' => '8.2'],
        static fn (array $r): bool => $r['php'] === 80200 && in_array(LevelSetList::UP_TO_PHP_82, $r['sets'], true)
            && !in_array(LevelSetList::UP_TO_PHP_83, $r['sets'], true),
    ],
    'php 8.3 sets the version and the level set' => [
        ['php' => '8.3'],
        static fn (array $r): bool => $r['php'] === 80300 && in_array(LevelSetList::UP_TO_PHP_83, $r['sets'], true)
            && !in_array(LevelSetList::UP_TO_PHP_84, $r['sets'], true),
    ],
    'php 8.4 sets the version and the level set' => [
        ['php' => '8.4'],
        static fn (array $r): bool => $r['php'] === 80400 && in_array(LevelSetList::UP_TO_PHP_84, $r['sets'], true)
            && !in_array(LevelSetList::UP_TO_PHP_85, $r['sets'], true),
    ],
    'php 8.5 sets the version and the level set' => [
        ['php' => '8.5'],
        static fn (array $r): bool => $r['php'] === 80500 && in_array(LevelSetList::UP_TO_PHP_85, $r['sets'], true),
    ],
    'typo3 12 adds its level set and keeps the plugin rule' => [
        ['typo3' => 12],
        static fn (array $r): bool => in_array(Typo3LevelSetList::UP_TO_TYPO3_12, $r['sets'], true)
            && !in_array(Typo3LevelSetList::UP_TO_TYPO3_13, $r['sets'], true)
            && !in_array($plugin, $r['skip'], true),
    ],
    'typo3 13 adds its level set and keeps the plugin rule' => [
        ['typo3' => 13],
        static fn (array $r): bool => in_array(Typo3LevelSetList::UP_TO_TYPO3_13, $r['sets'], true)
            && !in_array(Typo3LevelSetList::UP_TO_TYPO3_14, $r['sets'], true)
            && !in_array($plugin, $r['skip'], true),
    ],
    'typo3 14 adds its level set and skips the plugin rule' => [
        ['typo3' => 14],
        static fn (array $r): bool => in_array(Typo3LevelSetList::UP_TO_TYPO3_14, $r['sets'], true)
            && in_array($plugin, $r['skip'], true),
    ],
    'an unknown option throws' => [
        ['test' => true],
        static fn (array $r): bool => str_contains($r['error'] ?? '', 'Unknown Rector option(s): test'),
    ],
    'an unknown PHP version throws' => [
        ['php' => '8.1'],
        static fn (array $r): bool => str_contains($r['error'] ?? '', '"php" must be one of'),
    ],
    'a PHP version as float throws' => [
        ['php' => 8.3],
        static fn (array $r): bool => str_contains($r['error'] ?? '', '"php" must be one of'),
    ],
    'an unknown TYPO3 version throws' => [
        ['typo3' => 15],
        static fn (array $r): bool => str_contains($r['error'] ?? '', '"typo3" must be one of'),
    ],
    'a TYPO3 version as string throws' => [
        ['typo3' => '14'],
        static fn (array $r): bool => str_contains($r['error'] ?? '', '"typo3" must be one of'),
    ],
    'tests as string throws' => [
        ['tests' => 'yes'],
        static fn (array $r): bool => str_contains($r['error'] ?? '', '"tests" must be a bool'),
    ],
];

$failures = 0;
foreach ($cases as $name => [$options, $assert]) {
    $result = $run($options);
    if (isset($result['crash']) || !$assert($result)) {
        ++$failures;
        fwrite(STDERR, "FAIL {$name}: " . json_encode(['paths' => $result['paths'] ?? null, 'php' => $result['php'] ?? null, 'sets' => array_map('basename', $result['sets'] ?? []), 'skip' => $result['skip'] ?? null, 'error' => $result['error'] ?? $result['crash'] ?? null], JSON_UNESCAPED_SLASHES) . PHP_EOL);
    }
}

// Options without a project root are an error: they would be ignored.
$configure = require_once __DIR__ . '/../../config/rector/rector.php';
try {
    $configure(new RectorConfig(), '', ['tests' => true]);
    ++$failures;
    fwrite(STDERR, 'FAIL options without $projectRoot did not throw' . PHP_EOL);
} catch (InvalidArgumentException) {
}
$total = count($cases) + 1;

$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
foreach ($files as $file) {
    $file->isDir() ? rmdir($file->getPathname()) : unlink($file->getPathname());
}
rmdir($root);

if ($failures > 0) {
    fwrite(STDERR, "{$failures} of {$total} cases failed" . PHP_EOL);
    exit(1);
}

echo "rector options: {$total} of {$total} cases pass" . PHP_EOL;
