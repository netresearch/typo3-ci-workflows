<?php

/*
 * Shared PHP-CS-Fixer config factory for Netresearch TYPO3 extensions.
 *
 * Encapsulates the standard Finder setup, rules, and config boilerplate.
 * Extensions only need to provide a copyright header and project root.
 *
 * Usage in your extension's Build/.php-cs-fixer.dist.php:
 *
 *   $createConfig = require __DIR__ . '/../.Build/vendor/netresearch/typo3-ci-workflows/config/php-cs-fixer/config.php';
 *
 *   return $createConfig(<<<'EOF'
 *       Copyright (c) 2025-2026 Netresearch DTT GmbH
 *       SPDX-License-Identifier: AGPL-3.0-or-later
 *       EOF, __DIR__ . '/..');
 *
 * A third argument adds project rules on top of the shared set:
 *
 *   return $createConfig($header, __DIR__ . '/..', [
 *       'Netresearch/break_long_method_chain' => ['minimum_links' => 3],
 *   ]);
 *
 * A fourth argument excludes more directories, with the semantics of
 * Symfony Finder's exclude(): a plain name matches a directory of that name
 * at any depth, a name with a slash is a path below the project root:
 *
 *   return $createConfig($header, __DIR__ . '/..', [], ['packages', 'Tests/Fixtures/generated']);
 */

declare(strict_types=1);

use Netresearch\Typo3CiWorkflows\Fixer\BlankLineAfterControlStructureFixer;
use Netresearch\Typo3CiWorkflows\Fixer\BlankLineBeforeCommentFixer;
use Netresearch\Typo3CiWorkflows\Fixer\BreakLongMethodChainFixer;

/**
 * @param array<string, mixed> $extraRules    rules to add on top of the shared set,
 *                                            e.g. ['Netresearch/break_long_method_chain' => true]
 * @param list<string>         $extraExcludes directories to exclude on top of the shared list
 */
return static function (
    string $header,
    string $projectRoot,
    array $extraRules = [],
    array $extraExcludes = [],
): PhpCsFixer\Config {
    $rules = require __DIR__ . '/rules.php';

    // The dot directories are named although PHP-CS-Fixer 3 skips dot
    // directories by default: PHP-CS-Fixer 4 reverses that default
    // (Future::getV4OrV3(false, true) in its Finder), and so does
    // PHP_CS_FIXER_FUTURE_MODE=1 today. `public` is TYPO3's web directory
    // when composer.json sets no extra.typo3/cms.web-dir. `vendor` is
    // excluded at any depth by PHP-CS-Fixer's own Finder.
    $finder = PhpCsFixer\Finder::create()
        ->in($projectRoot)
        ->exclude([
            '.Build',
            '.build',
            '.ddev',
            '.pnpm-store',
            'config',
            'node_modules',
            'public',
            'var',
            ...$extraExcludes,
        ])
        ->notPath('ext_emconf.php');

    $config = new PhpCsFixer\Config();
    $config
        ->setRiskyAllowed(true)
        // Registered, not enabled — all of them. A rule that reflows a code
        // base has to be adopted in a commit of its own, per project, not
        // arrive with a dependency update. The README's Code Style section documents
        // each of them and shows how a project switches one on.
        ->registerCustomFixers([
            new BlankLineAfterControlStructureFixer(),
            new BlankLineBeforeCommentFixer(),
            new BreakLongMethodChainFixer(),
        ])
        ->setRules(array_merge($rules, [
            'header_comment' => [
                'header'       => $header,
                'comment_type' => 'comment',
                'location'     => 'after_open',
                'separate'     => 'both',
            ],
        ], $extraRules))
        ->setFinder($finder);

    if (method_exists($config, 'setUnsupportedPhpVersionAllowed')) {
        $config->setUnsupportedPhpVersionAllowed(true);
    }

    return $config;
};
