<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Fixer;

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
        /** @var array{minimum_links: int} $resolved */
        $resolved = $this->getConfigurationDefinition()->resolve($configuration);

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
        // One chain per pass, and the chains are collected again after every
        // one of them. A chain nested in another chain's argument list sits at
        // higher token indices than the outer chain's later links, so breaking
        // both from one collected set would apply the outer breaks at indices
        // the inner insertions have already moved — and it also lets the inner
        // chain take its indentation from where the outer chain has put it.
        $remaining = count($this->collectChains($tokens)) + 1;

        while ($remaining-- > 0 && $this->breakFirstUnbrokenChain($tokens)) {
            // Each pass leaves one more chain broken, and a broken chain is
            // recognised as such, so this terminates.
        }
    }

    private function breakFirstUnbrokenChain(Tokens $tokens): bool
    {
        foreach ($this->collectChains($tokens) as $chain) {
            $break = $this->whitespacesConfig->getLineEnding()
                . $this->statementIndent($tokens, $chain[0])
                . $this->whitespacesConfig->getIndent();

            if ($this->isAlreadyBroken($tokens, $chain, $break)) {
                continue;
            }

            foreach (array_reverse($chain) as $operator) {
                if ($tokens[$operator - 1]->isWhitespace()) {
                    $tokens[$operator - 1] = new Token([T_WHITESPACE, $break]);

                    continue;
                }

                $tokens->insertAt($operator, new Token([T_WHITESPACE, $break]));
            }

            return true;
        }

        return false;
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

            if ($token->equalsAny([';', ',']) || $token->isGivenKind([T_OPEN_TAG, T_DOUBLE_ARROW])) {
                return $this->indentOf($tokens, $tokens->getNextMeaningfulToken($i) ?? $index);
            }
        }

        return $this->indentOf($tokens, $index);
    }

    /**
     * @return list<non-empty-list<int>> the call operators of every chain long enough to break
     */
    private function collectChains(Tokens $tokens): array
    {
        $unsafe   = $this->interpolatedRanges($tokens);
        $chains   = [];
        $consumed = [];

        foreach ($tokens as $index => $token) {
            if (!$this->isObjectOperator($token)) {
                continue;
            }

            if (isset($consumed[$index]) || $this->isInside($unsafe, $index)) {
                continue;
            }

            $calls = [];
            $links = [];
            $cursor = $index;

            while (true) {
                $links[] = $cursor;

                $name = $tokens->getNextMeaningfulToken($cursor);

                if ($name === null) {
                    break;
                }

                // `$foo->{$bar}()`, `$foo->$bar()` and anything else dynamic is
                // left alone rather than guessed at.
                if (!$tokens[$name]->isGivenKind(T_STRING)) {
                    $calls = [];

                    break;
                }

                $end  = $name;
                $next = $tokens->getNextMeaningfulToken($name);

                if ($next !== null && $tokens[$next]->equals('(')) {
                    $calls[] = $cursor;
                    $end     = $tokens->findBlockEnd(Tokens::BLOCK_TYPE_PARENTHESIS_BRACE, $next);
                    $next    = $tokens->getNextMeaningfulToken($end);
                }

                while ($next !== null && $tokens[$next]->equals('[')) {
                    $end  = $tokens->findBlockEnd(Tokens::BLOCK_TYPE_INDEX_SQUARE_BRACE, $next);
                    $next = $tokens->getNextMeaningfulToken($end);
                }

                if ($next === null || !$this->isObjectOperator($tokens[$next])) {
                    break;
                }

                $cursor = $next;
            }

            foreach ($links as $link) {
                $consumed[$link] = true;
            }

            if (count($calls) >= $this->minimumLinks) {
                $chains[] = $calls;
            }
        }

        return $chains;
    }

    /**
     * Ranges of `{$...}` inside a string or heredoc.
     *
     * A line break inserted there would land in the string's value, so those
     * chains are skipped. The brace-less form (`"$a->b"`) cannot hold a call and
     * therefore never reaches the threshold.
     *
     * @return list<array{int, int}>
     */
    private function interpolatedRanges(Tokens $tokens): array
    {
        $ranges = [];

        foreach ($tokens as $index => $token) {
            if (!$token->isGivenKind([T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES])) {
                continue;
            }

            $ranges[] = [$index, $this->closingBrace($tokens, $index)];
        }

        return $ranges;
    }

    /**
     * `T_CURLY_OPEN` is not registered as the start of any block type, so the
     * matching brace is counted rather than looked up.
     */
    private function closingBrace(Tokens $tokens, int $index): int
    {
        $depth = 0;

        for ($i = $index, $last = count($tokens); $i < $last; ++$i) {
            $content = $tokens[$i]->getContent();

            if ($content === '{' || $content === '${') {
                ++$depth;

                continue;
            }

            if ($content !== '}') {
                continue;
            }

            if (--$depth === 0) {
                return $i;
            }
        }

        return $last - 1;
    }

    /**
     * @param list<array{int, int}> $ranges
     */
    private function isInside(array $ranges, int $index): bool
    {
        foreach ($ranges as [$start, $end]) {
            if ($index > $start && $index < $end) {
                return true;
            }
        }

        return false;
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
