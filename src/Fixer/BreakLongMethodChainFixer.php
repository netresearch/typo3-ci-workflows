<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Fixer;

use PhpCsFixer\ConfigurationException\InvalidFixerConfigurationException;
use PhpCsFixer\Fixer\ConfigurableFixerInterface;
use PhpCsFixer\Fixer\WhitespacesAwareFixerInterface;
use PhpCsFixer\FixerConfiguration\FixerConfigurationResolver;
use PhpCsFixer\FixerConfiguration\FixerConfigurationResolverInterface;
use PhpCsFixer\FixerConfiguration\FixerOptionBuilder;
use PhpCsFixer\FixerDefinition\CodeSample;
use PhpCsFixer\FixerDefinition\FixerDefinition;
use PhpCsFixer\FixerDefinition\FixerDefinitionInterface;
use PhpCsFixer\Tokenizer\Token;
use PhpCsFixer\Tokenizer\Tokens;
use PhpCsFixer\WhitespacesFixerConfig;
use SplFileInfo;
use Symfony\Component\OptionsResolver\Exception\ExceptionInterface;

/**
 * Puts every call of a long method chain on its own line.
 *
 * This is the one line-breaking decision no shipped fixer makes. None of
 * php-cs-fixer's rules has a line-width concept, and `method_chaining_indentation`
 * only indents a chain somebody already broke by hand — so a chain written on one
 * line stays on one line however long it grows. That matters for generated code:
 * a printer renders from a syntax tree and reproduces whatever the rules say,
 * so a rule nobody wrote is a rule nobody applies, and the chain comes back as
 * one line of arbitrary length.
 *
 * The trigger is the number of calls, not the width, because a fixer works on
 * tokens and has no budget to compare against. Property hops are neither counted
 * nor broken: `$this->connectionPool` stays attached to its subject, and only the
 * calls hanging off it move onto their own lines.
 *
 * @implements ConfigurableFixerInterface<array{minimum_links?: int}, array{minimum_links: int}>
 */
final class BreakLongMethodChainFixer implements ConfigurableFixerInterface, WhitespacesAwareFixerInterface
{
    private int $minimumLinks = 3;

    private WhitespacesFixerConfig $whitespacesConfig;

    public function __construct()
    {
        $this->whitespacesConfig = new WhitespacesFixerConfig();
    }

    public function configure(array $configuration): void
    {
        try {
            /** @var array{minimum_links: int} $resolved */
            $resolved = $this->getConfigurationDefinition()->resolve($configuration);
        } catch (ExceptionInterface $exception) {
            // Shipped fixers reach this through ConfigurableFixerTrait, which is
            // marked internal; the exception type callers see is the same.
            throw new InvalidFixerConfigurationException(
                $this->getName(),
                $exception->getMessage(),
                $exception,
            );
        }

        $this->minimumLinks = $resolved['minimum_links'];
    }

    public function getConfigurationDefinition(): FixerConfigurationResolverInterface
    {
        return new FixerConfigurationResolver([
            (new FixerOptionBuilder(
                'minimum_links',
                'Number of method calls in one chain from which the chain is broken.',
            ))
                ->setAllowedTypes(['int'])
                // A chain of fewer than one call is not a chain: at 0 every
                // property access becomes an empty candidate and the fixer
                // reads a link that is not there.
                ->setAllowedValues([static fn (int $minimum): bool => $minimum >= 1])
                ->setDefault(3)
                ->getOption(),
        ]);
    }

    public function setWhitespacesConfig(WhitespacesFixerConfig $config): void
    {
        $this->whitespacesConfig = $config;
    }

    public function getName(): string
    {
        return 'Netresearch/break_long_method_chain';
    }

    public function getPriority(): int
    {
        // Above `method_chaining_indentation` (0), so that a chain broken here
        // is still seen by the fixer that owns chain indentation.
        return 1;
    }

    public function supports(SplFileInfo $file): bool
    {
        return true;
    }

    public function isRisky(): bool
    {
        return false;
    }

    public function isCandidate(Tokens $tokens): bool
    {
        return $tokens->isAnyTokenKindsFound([T_OBJECT_OPERATOR, T_NULLSAFE_OBJECT_OPERATOR]);
    }

    public function getDefinition(): FixerDefinitionInterface
    {
        return new FixerDefinition(
            'Every call of a method chain of at least `minimum_links` calls is put on its own line.',
            [
                new CodeSample(
                    "<?php\n\$queryBuilder->select('uid')->from('pages')->executeQuery();\n",
                ),
                new CodeSample(
                    "<?php\n\$queryBuilder->select('uid')->from('pages')->executeQuery();\n",
                    ['minimum_links' => 2],
                ),
            ],
        );
    }

    public function fix(SplFileInfo $file, Tokens $tokens): void
    {
        // One chain per pass. A chain nested in another chain's argument list
        // sits at higher token indices than the outer chain's later links, so
        // breaking both from one collected set would apply the outer breaks at
        // indices the inner insertions have already moved — and it also lets the
        // inner chain take its indentation from where the outer chain has put it,
        // which is what keeps the result idempotent.
        //
        // Three things made that quadratic, and 400 chains in one file took 22
        // seconds: scanning to the end of the file on every pass, re-scanning
        // from the front, and one insertAt per break, each copying the whole
        // collection. So the scan stops at the first chain it has to break, it
        // resumes where the last one started — every chain in front of that is
        // settled — and a chain's breaks go in as one slice. Same file: 0.69 s.
        $from = 0;

        while (true) {
            $chain = $this->firstUnbrokenChain($tokens, $from);

            if ($chain === null) {
                return;
            }

            [$calls, $break] = $chain;
            $insertions = [];

            foreach ($calls as $operator) {
                // Replacing is index-stable and can happen right away; the
                // insertions go in together, because each one on its own copies
                // the whole collection.
                if ($tokens[$operator - 1]->isWhitespace()) {
                    $tokens[$operator - 1] = new Token([T_WHITESPACE, $break]);

                    continue;
                }

                $insertions[$operator] = new Token([T_WHITESPACE, $break]);
            }

            if ($insertions !== []) {
                $tokens->insertSlices($insertions);
            }

            $from = $calls[0];
        }
    }

    /**
     * The first chain from `$from` that is not broken yet.
     *
     * Stops at that chain rather than collecting them all: `fix()` calls this
     * once per chain, so scanning to the end of the file every time is what made
     * the whole run quadratic.
     *
     * @return null|array{non-empty-list<int>, string} the chain's call operators and the whitespace to put in front of each
     */
    private function firstUnbrokenChain(Tokens $tokens, int $from): ?array
    {
        $consumed = [];

        // A line break written inside `{$...}` would land in the string's value.
        // `$from` is either the start of the file or the start of a chain, so it
        // is never itself inside one, and interpolation does not nest — a flag is
        // enough. The brace-less form (`"$a->b"`) cannot hold a call and so never
        // reaches the threshold.
        $interpolating = false;

        for ($index = $from, $last = count($tokens); $index < $last; ++$index) {
            $token = $tokens[$index];

            if ($interpolating) {
                $interpolating = $token->getContent() !== '}';

                continue;
            }

            if ($token->isGivenKind([T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES])) {
                $interpolating = true;

                continue;
            }

            if (!$this->isObjectOperator($token) || isset($consumed[$index])) {
                continue;
            }

            [$links, $calls] = $this->parseChain($tokens, $index);

            foreach ($links as $link) {
                $consumed[$link] = true;
            }

            if (count($calls) < $this->minimumLinks) {
                continue;
            }

            $break = $this->whitespacesConfig->getLineEnding()
                . $this->statementIndent($tokens, $calls[0])
                . $this->whitespacesConfig->getIndent();

            if (!$this->isAlreadyBroken($tokens, $calls, $break)) {
                return [$calls, $break];
            }
        }

        return null;
    }

    /**
     * @param non-empty-list<int> $chain
     */
    private function isAlreadyBroken(Tokens $tokens, array $chain, string $break): bool
    {
        foreach ($chain as $operator) {
            if (!$tokens[$operator - 1]->isWhitespace()) {
                return false;
            }

            if ($tokens[$operator - 1]->getContent() !== $break) {
                return false;
            }
        }

        return true;
    }

    /**
     * Indentation of the line the surrounding statement — or the surrounding
     * argument — starts on.
     *
     * Deriving it from the chain itself would grow by one level per run as soon
     * as the first call already sits on its own line, so the walk goes back over
     * balanced brackets to the point where the expression begins.
     */
    private function statementIndent(Tokens $tokens, int $index): string
    {
        $depth = 0;

        for ($i = $index - 1; $i >= 0; --$i) {
            $token = $tokens[$i];

            if ($token->equalsAny([')', ']', '}'])) {
                ++$depth;

                continue;
            }

            if ($token->equalsAny(['(', '[', '{'])) {
                if ($depth === 0) {
                    return $this->indentOf($tokens, $tokens->getNextMeaningfulToken($i) ?? $index);
                }

                --$depth;

                continue;
            }

            if ($depth !== 0) {
                continue;
            }

            // A comma is deliberately not a boundary. Taking it as one lets the
            // second of two chains in one argument list derive its indentation
            // from the first one after that has already been broken, so the two
            // come out a level apart for no reason. The enclosing bracket is the
            // same for both.
            if ($token->equals(';') || $token->isGivenKind([T_OPEN_TAG, T_DOUBLE_ARROW])) {
                return $this->indentOf($tokens, $tokens->getNextMeaningfulToken($i) ?? $index);
            }
        }

        return $this->indentOf($tokens, $index);
    }

    /**
     * Walks one chain from its first operator.
     *
     * @return array{non-empty-list<int>, list<int>} every operator of the chain, and those that are a call
     */
    private function parseChain(Tokens $tokens, int $start): array
    {
        $links  = [];
        $calls  = [];
        $cursor = $start;

        while (true) {
            $links[] = $cursor;

            $name = $tokens->getNextMeaningfulToken($cursor);

            if ($name === null) {
                break;
            }

            // `$foo->{$bar}()`, `$foo->$bar()` and anything else dynamic is left
            // alone rather than guessed at.
            if (!$tokens[$name]->isGivenKind(T_STRING)) {
                return [$links, []];
            }

            $next = $tokens->getNextMeaningfulToken($name);

            if ($next !== null && $tokens[$next]->equals('(')) {
                $calls[] = $cursor;
                $next    = $tokens->getNextMeaningfulToken(
                    $tokens->findBlockEnd(Tokens::BLOCK_TYPE_PARENTHESIS_BRACE, $next),
                );
            }

            $next = $this->skipArrayAccess($tokens, $next);

            if ($next === null || !$this->isObjectOperator($tokens[$next])) {
                break;
            }

            $cursor = $next;
        }

        return [$links, $calls];
    }

    private function skipArrayAccess(Tokens $tokens, ?int $index): ?int
    {
        while ($index !== null && $tokens[$index]->equals('[')) {
            $index = $tokens->getNextMeaningfulToken(
                $tokens->findBlockEnd(Tokens::BLOCK_TYPE_INDEX_SQUARE_BRACE, $index),
            );
        }

        return $index;
    }

    private function isObjectOperator(Token $token): bool
    {
        return $token->isGivenKind([T_OBJECT_OPERATOR, T_NULLSAFE_OBJECT_OPERATOR]);
    }

    private function indentOf(Tokens $tokens, int $index): string
    {
        for ($i = $index; $i >= 0; --$i) {
            if (!$tokens[$i]->isWhitespace() || !str_contains($tokens[$i]->getContent(), "\n")) {
                continue;
            }

            $lines = explode("\n", $tokens[$i]->getContent());

            return end($lines);
        }

        return '';
    }
}
