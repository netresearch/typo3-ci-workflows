<?php

/*
 * Shared Rector base configuration for Netresearch TYPO3 extensions.
 *
 * This config provides common code-quality sets, rule skips, and optional
 * standard TYPO3 extension paths/skips via the $projectRoot parameter.
 * Rector's sets() and skip() are additive — extensions can safely call them
 * again to add TYPO3-level and extension-specific entries.
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
 *   - phpstanConfig: Build/phpstan.neon
 *   - phpVersion: 80200
 *
 * Pass '' or omit $projectRoot for v1.0 backward-compatible behavior
 * (extension must set paths/skip/phpVersion manually).
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

return static function (RectorConfig $rectorConfig, string $projectRoot = ''): void {
    $rectorConfig->importNames();
    $rectorConfig->removeUnusedImports();

    if ($projectRoot !== '') {
        // Standard TYPO3 extension paths
        $paths = [$projectRoot . '/Classes', $projectRoot . '/Configuration'];
        if (is_dir($projectRoot . '/Resources')) {
            $paths[] = $projectRoot . '/Resources';
        }
        $paths = array_merge($paths, glob($projectRoot . '/ext_*.php') ?: []);
        $rectorConfig->paths($paths);

        $rectorConfig->skip([$projectRoot . '/ext_emconf.php']);
        $rectorConfig->phpstanConfig($projectRoot . '/Build/phpstan.neon');
    }

    $rectorConfig->phpVersion(80200);

    // Common code-quality rule sets
    $rectorConfig->sets([
        SetList::CODE_QUALITY,
        SetList::CODING_STYLE,
        SetList::DEAD_CODE,
        SetList::EARLY_RETURN,
        SetList::INSTANCEOF,
        SetList::PRIVATIZATION,
        SetList::STRICT_BOOLEANS,
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
    ]);
};
