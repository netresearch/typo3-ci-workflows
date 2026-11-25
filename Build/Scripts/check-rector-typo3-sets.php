<?php

/*
 * Runs Rector with the shared config and each Typo3LevelSetList, and checks
 * that the rules using the classes of config/rector/removed-classes.php
 * change code.
 *
 * Usage: php Build/Scripts/check-rector-typo3-sets.php
 */

declare(strict_types=1);

$base = dirname(__DIR__, 2);
$root = sys_get_temp_dir() . '/check-rector-typo3-sets-' . bin2hex(random_bytes(4));
mkdir($root . '/Classes', 0o777, true);
mkdir($root . '/Configuration', 0o777, true);
file_put_contents($root . '/ext_emconf.php', "<?php\n");

file_put_contents($root . '/Classes/Subject.php', <<<'PHP'
    <?php

    declare(strict_types=1);

    namespace Vendor\Subject;

    final class Subject
    {
        public function run(\Vendor\Old\MethodOwner $owner): void
        {
            $owner->oldMethod();
            \Vendor\Old\StaticOwner::oldStatic();
        }
    }
    PHP);

$failed = false;
$rector = static function (string $body, string $label) use ($base, $root, &$failed): string {
    file_put_contents($root . '/rector.php', "<?php\n\ndeclare(strict_types=1);\n\n" . $body);
    $process = proc_open(
        [PHP_BINARY, '-d', 'memory_limit=2G', $base . '/vendor/bin/rector', 'process', '--config', $root . '/rector.php', '--dry-run', '--no-progress-bar', '--clear-cache', '--debug'],
        [1 => ['pipe', 'w'], 2 => ['redirect', 1]],
        $pipes,
        $root,
    );
    $out    = (string) stream_get_contents($pipes[1]);
    $status = proc_close($process);
    // 0: nothing to change, 2: changes found. Everything else is a failure.
    if (!in_array($status, [0, 2], true)) {
        $failed = true;
        fwrite(STDERR, "{$label}: Rector exited with {$status}" . PHP_EOL . $out . PHP_EOL);
    }

    return $out;
};

$load = "\$configure = require '{$base}/config/rector/rector.php';\n";
foreach ([12, 13, 14] as $typo3) {
    $rector(
        $load . "return static function (\\Rector\\Config\\RectorConfig \$c) use (\$configure): void { \$configure(\$c, __DIR__, ['typo3' => {$typo3}]); };\n",
        "TYPO3 {$typo3}",
    );
}

// The rules themselves, configured with the classes under test.
$out = $rector($load . <<<'PHP'
    return static function (\Rector\Config\RectorConfig $c) use ($configure): void {
        $configure($c, __DIR__);
        $c->ruleWithConfiguration(\Ssch\TYPO3Rector\General\Transform\MethodCallToStaticCallRector::class, [
            new \Rector\Transform\ValueObject\MethodCallToStaticCall('Vendor\Old\MethodOwner', 'oldMethod', 'Vendor\New\MethodOwner', 'newMethod'),
        ]);
        $c->ruleWithConfiguration(\Ssch\TYPO3Rector\General\Renaming\RenameStaticMethodRector::class, [
            new \Rector\Renaming\ValueObject\RenameStaticMethod('Vendor\Old\StaticOwner', 'oldStatic', 'Vendor\New\StaticOwner', 'newStatic'),
        ]);
    };
    PHP, 'rules');
foreach (['newMethod()', 'newStatic()'] as $expected) {
    if (!str_contains($out, $expected)) {
        $failed = true;
        fwrite(STDERR, "rules: {$expected} is missing from the diff" . PHP_EOL . $out . PHP_EOL);
    }
}

if ($failed) {
    exit(1);
}

echo 'rector TYPO3 sets: 12, 13 and 14 load, 2 rules change code' . PHP_EOL;
