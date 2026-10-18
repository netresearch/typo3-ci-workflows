<?php

/*
 * Shared Rector base configuration for Netresearch TYPO3 extensions.
 *
 * This config provides common code-quality sets, rule skips, and optional
 * standard TYPO3 extension paths/skips via the $projectRoot parameter.
 *
 * Merge behavior:
 *   - sets() and skip() are ADDITIVE — extensions can safely call them again
 *   - paths() REPLACES — the last call wins (extension overrides shared paths)
 *   - phpVersion() REPLACES — extension can override if needed
 *
 * Usage in your extension's Build/rector.php:
 *
 *   declare(strict_types=1);
 *
 *   use Rector\Config\RectorConfig;
 *   use Ssch\TYPO3Rector\Set\Typo3LevelSetList;
 *
 *   $configure = require __DIR__ . '/../.Build/vendor/netresearch/typo3-ci-workflows/config/rector/rector.php';
 *
 *   return static function (RectorConfig $rectorConfig) use ($configure): void {
 *       // Apply shared base config with standard TYPO3 extension paths
 *       $configure($rectorConfig, __DIR__ . '/..');
 *
 *       // Extension-specific TYPO3 sets
 *       $rectorConfig->sets([
 *           Typo3LevelSetList::UP_TO_TYPO3_13,
 *       ]);
 *   };
 *
 * The $projectRoot parameter (v1.1+) auto-configures:
 *   - paths: Classes/, Configuration/, Resources/ (if exists), ext_*.php (via glob)
 *   - skip: ext_emconf.php
 *   - phpstanConfig: config/phpstan/phpstan-rector.neon of this package
 *   - phpVersion: 80200
 *
 * Pass '' or omit $projectRoot for v1.0 backward-compatible behavior
 * (extension must set paths/skip/phpstanConfig/phpVersion manually).
 * Note: sets and skips (code-quality rules) always apply regardless of $projectRoot.
 *
 * A third argument sets options; each one requires $projectRoot. An unknown
 * option or value throws, so a typo cannot pass as the default:
 *
 *   $configure($rectorConfig, __DIR__ . '/..', [
 *       'tests' => true,   // add Tests/ to the paths
 *       'php'   => '8.3',  // the lowest PHP version the extension supports
 *       'typo3' => 13,     // the lowest TYPO3 major version it supports
 *   ]);
 *
 *   - tests: Tests/ joins the paths when the directory exists.
 *   - php:   8.2 to 8.5. Sets phpVersion() and adds the matching
 *            LevelSetList::UP_TO_PHP_* set. Without it: 8.2.
 *   - typo3: 12, 13 or 14. Adds Typo3LevelSetList::UP_TO_TYPO3_<n>. With 14,
 *            MigratePluginContentElementAndPluginSubtypesRector is skipped.
 *            TYPO3 14 registers every plugin as a content element, and the
 *            rule's edits no longer fit its API: in configurePlugin() it adds
 *            an argument that TYPO3 14 only accepts as "CType", and in an
 *            addPlugin() call without a second argument (now $flexForm) it
 *            writes "CType" as the FlexForm. It also writes an upgrade wizard with an
 *            empty list_type mapping into Classes/Updates/; a normal run
 *            writes that file, a --dry-run does not show it. Records with a
 *            list_type from an earlier TYPO3 version still need a migration
 *            with a real mapping.
 */

declare(strict_types=1);

use Rector\CodingStyle\Rector\Catch_\CatchExceptionNameMatchingTypeRector;
use Rector\Config\RectorConfig;
use Rector\DeadCode\Rector\ClassMethod\RemoveUnusedPrivateMethodParameterRector;
use Rector\DeadCode\Rector\ClassMethod\RemoveUselessParamTagRector;
use Rector\DeadCode\Rector\ClassMethod\RemoveUselessReturnTagRector;
use Rector\DeadCode\Rector\Property\RemoveUselessVarTagRector;
use Rector\Php80\Rector\Class_\ClassPropertyAssignToConstructorPromotionRector;
use Rector\Set\ValueObject\LevelSetList;
use Rector\Set\ValueObject\SetList;
use Rector\TypeDeclaration\Rector\Class_\TypedPropertyFromCreateMockAssignRector;
use Ssch\TYPO3Rector\Set\Typo3LevelSetList;
use Ssch\TYPO3Rector\TYPO313\v4\MigratePluginContentElementAndPluginSubtypesRector;

/**
 * @param array{tests?: bool, php?: string, typo3?: int} $options
 */
return static function (RectorConfig $rectorConfig, string $projectRoot = '', array $options = []): void {
    $phpLevels = [
        '8.2' => [80200, LevelSetList::UP_TO_PHP_82],
        '8.3' => [80300, LevelSetList::UP_TO_PHP_83],
        '8.4' => [80400, LevelSetList::UP_TO_PHP_84],
        '8.5' => [80500, LevelSetList::UP_TO_PHP_85],
    ];
    $typo3Levels = [
        12 => Typo3LevelSetList::UP_TO_TYPO3_12,
        13 => Typo3LevelSetList::UP_TO_TYPO3_13,
        14 => Typo3LevelSetList::UP_TO_TYPO3_14,
    ];

    $unknown = array_diff(array_keys($options), ['tests', 'php', 'typo3']);
    if ($unknown !== []) {
        throw new InvalidArgumentException('Unknown Rector option(s): ' . implode(', ', $unknown) . '. Known: tests, php, typo3.');
    }
    if ($options !== [] && $projectRoot === '') {
        throw new InvalidArgumentException('Rector options require $projectRoot.');
    }
    if (isset($options['tests']) && !is_bool($options['tests'])) {
        throw new InvalidArgumentException('Rector option "tests" must be a bool.');
    }
    $php = $options['php'] ?? '8.2';
    if (!is_string($php) || !isset($phpLevels[$php])) {
        throw new InvalidArgumentException('Rector option "php" must be one of ' . implode(', ', array_keys($phpLevels)) . ', got ' . var_export($php, true) . '.');
    }
    $typo3 = $options['typo3'] ?? null;
    if ($typo3 !== null && (!is_int($typo3) || !isset($typo3Levels[$typo3]))) {
        throw new InvalidArgumentException('Rector option "typo3" must be one of ' . implode(', ', array_keys($typo3Levels)) . ', got ' . var_export($typo3, true) . '.');
    }

    $rectorConfig->importNames();
    $rectorConfig->removeUnusedImports();

    if ($projectRoot !== '') {
        // Standard TYPO3 extension paths
        $paths = [$projectRoot . '/Classes', $projectRoot . '/Configuration'];
        if (is_dir($projectRoot . '/Resources')) {
            $paths[] = $projectRoot . '/Resources';
        }
        if (($options['tests'] ?? false) && is_dir($projectRoot . '/Tests')) {
            $paths[] = $projectRoot . '/Tests';
        }
        $paths = array_merge($paths, glob($projectRoot . '/ext_*.php') ?: []);
        $rectorConfig->paths($paths);

        $rectorConfig->skip([$projectRoot . '/ext_emconf.php']);

        // Point Rector at the dedicated phpstan-rector.neon shipped in
        // this package — NOT the project's Build/phpstan.neon. Rector
        // loads its phpstan config through its bundled phpstan.phar,
        // which does not have ergebnis/phpstan-rules registered, so the
        // `parameters: ergebnis: { ... }` block in the regular shared
        // neon trips Nette\Schema\ValidationException
        // ("Unexpected item 'parameters › ergebnis'"). The Rector-only
        // neon has the same level/exclude bits Rector needs but skips
        // the ergebnis schema entirely.
        $rectorConfig->phpstanConfig(
            __DIR__ . '/../phpstan/phpstan-rector.neon',
        );

        [$phpVersion, $phpLevelSet] = $phpLevels[$php];
        $rectorConfig->phpVersion($phpVersion);
        $rectorConfig->sets([$phpLevelSet]);

        if ($typo3 !== null) {
            $rectorConfig->sets([$typo3Levels[$typo3]]);
        }
        if ($typo3 === 14) {
            $rectorConfig->skip([MigratePluginContentElementAndPluginSubtypesRector::class]);
        }
    }

    // Common code-quality rule sets.
    //
    // SetList::STRICT_BOOLEANS is deliberately absent: Rector 2.6.0 removed the
    // constant, and every consumer's Rector job died with "Undefined constant
    // Rector\Set\ValueObject\SetList::STRICT_BOOLEANS" the moment CI resolved
    // that release. Rector's own deprecation says the set was "mostly risky and
    // not practical" and points at codeQuality and codingStyle instead, both of
    // which are already listed below — so nothing is lost by dropping it.
    //
    // SetList::EARLY_RETURN and SetList::INSTANCEOF are absent for the same
    // reason before it bites: Rector deprecates both, and from Rector 2.6.5
    // (the floor in composer.json) their set files register no rules. Of
    // their 15 rules, 11 moved into the code quality, type declaration and
    // dead code sets listed below; Rector deprecated the other 4.
    $rectorConfig->sets([
        SetList::CODE_QUALITY,
        SetList::CODING_STYLE,
        SetList::DEAD_CODE,
        SetList::PRIVATIZATION,
        SetList::TYPE_DECLARATION,
        LevelSetList::UP_TO_PHP_82,
    ]);

    // Common skips — rules that cause issues across TYPO3 extensions
    $rectorConfig->skip([
        // Rename catch variables to match exception type — too noisy
        CatchExceptionNameMatchingTypeRector::class,

        // Constructor promotion conflicts with TYPO3 DI patterns
        ClassPropertyAssignToConstructorPromotionRector::class,

        // Keep explicit PHPDoc tags for documentation clarity
        RemoveUselessParamTagRector::class,
        RemoveUselessReturnTagRector::class,
        RemoveUselessVarTagRector::class,

        // Removing private method params can break internal API contracts
        RemoveUnusedPrivateMethodParameterRector::class,

        // In a TestCase, replaces the type of a property that is assigned
        // createMock() with plain MockObject, also when the property already
        // has a class type: `private Foo $foo` becomes `private MockObject
        // $foo`, and passing it where a Foo is expected no longer type-checks.
        // Only an intersection type (Foo&MockObject) is left alone.
        TypedPropertyFromCreateMockAssignRector::class,
    ]);
};
