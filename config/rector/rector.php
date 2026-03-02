<?php

/*
 * Shared Rector base configuration for Netresearch TYPO3 extensions.
 *
 * This config provides common code-quality sets and rule skips.
 * Rector's sets() and skip() are additive — extensions can safely call them
 * again to add PHP-level, TYPO3-level, and extension-specific entries.
 *
 * Usage in your extension's Build/rector.php:
 *
 *   declare(strict_types=1);
 *
 *   use Rector\Config\RectorConfig;
 *   use Rector\Set\ValueObject\LevelSetList;
 *   use Ssch\TYPO3Rector\Set\Typo3LevelSetList;
 *
 *   $configure = require __DIR__ . '/../.Build/vendor/netresearch/typo3-ci-workflows/config/rector/rector.php';
 *
 *   return static function (RectorConfig $rectorConfig) use ($configure): void {
 *       // Apply shared base config (sets + skips are additive)
 *       $configure($rectorConfig);
 *
 *       // Extension-specific paths
 *       $rectorConfig->paths([
 *           __DIR__ . '/../Classes',
 *           __DIR__ . '/../Configuration',
 *           __DIR__ . '/../Tests',
 *       ]);
 *
 *       // Extension-specific skips (merged with shared skips)
 *       $rectorConfig->skip([
 *           __DIR__ . '/../.Build',
 *           __DIR__ . '/../ext_emconf.php',
 *       ]);
 *
 *       $rectorConfig->phpstanConfig(__DIR__ . '/phpstan.neon');
 *       $rectorConfig->phpVersion(80200);
 *
 *       // PHP and TYPO3 level sets — adjust to your extension's requirements
 *       $rectorConfig->sets([
 *           LevelSetList::UP_TO_PHP_82,          // Match your composer.json php constraint
 *           Typo3LevelSetList::UP_TO_TYPO3_13,   // Use lowest supported TYPO3 major
 *       ]);
 *   };
 */

declare(strict_types=1);

use Rector\CodingStyle\Rector\Catch_\CatchExceptionNameMatchingTypeRector;
use Rector\Config\RectorConfig;
use Rector\DeadCode\Rector\ClassMethod\RemoveUnusedPrivateMethodParameterRector;
use Rector\DeadCode\Rector\ClassMethod\RemoveUselessParamTagRector;
use Rector\DeadCode\Rector\ClassMethod\RemoveUselessReturnTagRector;
use Rector\DeadCode\Rector\Property\RemoveUselessVarTagRector;
use Rector\Php80\Rector\Class_\ClassPropertyAssignToConstructorPromotionRector;
use Rector\Set\ValueObject\SetList;

return static function (RectorConfig $rectorConfig): void {
    $rectorConfig->importNames();
    $rectorConfig->removeUnusedImports();

    // Common code-quality rule sets
    $rectorConfig->sets([
        SetList::CODE_QUALITY,
        SetList::CODING_STYLE,
        SetList::DEAD_CODE,
        SetList::EARLY_RETURN,
        SetList::INSTANCEOF,
        SetList::PRIVATIZATION,
        SetList::TYPE_DECLARATION,
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
