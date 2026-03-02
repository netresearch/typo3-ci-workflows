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
 */

declare(strict_types=1);

return static function (string $header, string $projectRoot): PhpCsFixer\Config {
    $rules = require __DIR__ . '/rules.php';

    $finder = PhpCsFixer\Finder::create()
        ->in($projectRoot)
        ->exclude(['.Build', 'config', 'node_modules', 'var'])
        ->notPath('ext_emconf.php');

    $config = new PhpCsFixer\Config();
    $config
        ->setRiskyAllowed(true)
        ->setRules(array_merge($rules, [
            'header_comment' => [
                'header'       => $header,
                'comment_type' => 'comment',
                'location'     => 'after_open',
                'separate'     => 'both',
            ],
        ]))
        ->setFinder($finder);

    if (method_exists($config, 'setUnsupportedPhpVersionAllowed')) {
        $config->setUnsupportedPhpVersionAllowed(true);
    }

    return $config;
};
