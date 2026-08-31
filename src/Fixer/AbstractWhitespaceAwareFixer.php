<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Fixer;

use PhpCsFixer\Fixer\FixerInterface;
use PhpCsFixer\Fixer\WhitespacesAwareFixerInterface;
use PhpCsFixer\WhitespacesFixerConfig;
use SplFileInfo;

/**
 * What every fixer in this package has in common.
 *
 * All of them write whitespace, so all of them need the project's indent and
 * line ending, and none of them changes what the code does. Kept in one place
 * rather than repeated per fixer — a private copy in each file is the same
 * duplication with a longer name.
 */
abstract class AbstractWhitespaceAwareFixer implements FixerInterface, WhitespacesAwareFixerInterface
{
    protected WhitespacesFixerConfig $whitespacesConfig;

    public function __construct()
    {
        // php-cs-fixer sets the real one before it runs a fixer; a fixer used
        // directly, as the fixture checks do, gets the default.
        $this->whitespacesConfig = new WhitespacesFixerConfig();
    }

    public function setWhitespacesConfig(WhitespacesFixerConfig $config): void
    {
        $this->whitespacesConfig = $config;
    }

    public function supports(SplFileInfo $file): bool
    {
        return true;
    }

    public function isRisky(): bool
    {
        return false;
    }
}
