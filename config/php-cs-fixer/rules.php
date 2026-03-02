<?php

/*
 * Shared PHP-CS-Fixer rules for Netresearch TYPO3 extensions.
 *
 * Usage in your extension's Build/.php-cs-fixer.dist.php:
 *
 *   $sharedRules = require __DIR__ . '/../.Build/vendor/netresearch/typo3-ci-workflows/config/php-cs-fixer/rules.php';
 *
 *   $header = <<<EOF
 *   Copyright (c) 2025-2026 Netresearch DTT GmbH
 *   SPDX-License-Identifier: AGPL-3.0-or-later
 *   EOF;
 *
 *   $finder = PhpCsFixer\Finder::create()
 *       ->in(__DIR__ . '/..')
 *       ->exclude(['.Build', 'config', 'node_modules', 'var'])
 *       ->notPath('ext_emconf.php');
 *
 *   $config = (new PhpCsFixer\Config())
 *       ->setRiskyAllowed(true)
 *       ->setRules(array_merge($sharedRules, [
 *           'header_comment' => [
 *               'header'       => $header,
 *               'comment_type' => 'comment',
 *               'location'     => 'after_open',
 *               'separate'     => 'both',
 *           ],
 *       ]))
 *       ->setFinder($finder);
 *
 *   // Allow running on newer PHP than composer.json minimum
 *   if (method_exists($config, 'setUnsupportedPhpVersionAllowed')) {
 *       $config->setUnsupportedPhpVersionAllowed(true);
 *   }
 *
 *   return $config;
 *
 * Note: Extensions must add 'captainhook/hook-installer', 'phpstan/extension-installer',
 * and 'a9f/fractor-extension-installer' to their allow-plugins in composer.json.
 */

return [
    // Base rulesets — PER-CS 2.0 + Symfony as foundation
    '@Symfony'         => true,
    '@PER-CS2x0'       => true,
    '@PHP8x2Migration' => true,

    // Strict typing
    'declare_strict_types' => true,

    // Spacing
    'concat_space' => ['spacing' => 'one'],

    // Docblocks — keep stable behavior
    'phpdoc_to_comment'          => false,
    'no_superfluous_phpdoc_tags' => false,
    'phpdoc_separation'          => [
        'groups' => [['author', 'license', 'link']],
    ],

    // Aliases
    'no_alias_functions' => true,

    // Alignment
    'binary_operator_spaces' => [
        'operators' => [
            '='  => 'align_single_space_minimal',
            '=>' => 'align_single_space_minimal',
        ],
    ],

    // No Yoda
    'yoda_style' => [
        'equal'                => false,
        'identical'            => false,
        'less_and_greater'     => false,
        'always_move_variable' => false,
    ],

    // Imports
    'global_namespace_import' => [
        'import_classes'   => true,
        'import_constants' => true,
        'import_functions' => true,
    ],
    'no_unused_imports' => true,
    'ordered_imports'   => ['sort_algorithm' => 'alpha'],

    // Function declarations
    'function_declaration' => [
        'closure_function_spacing' => 'one',
        'closure_fn_spacing'       => 'one',
    ],

    // Modern syntax
    'trailing_comma_in_multiline' => [
        'elements' => ['arrays', 'arguments', 'parameters'],
    ],

    // Whitespace
    'whitespace_after_comma_in_array' => ['ensure_single_space' => true],

    // Style preferences
    'single_line_throw' => false,
    'self_accessor'     => false,
];
