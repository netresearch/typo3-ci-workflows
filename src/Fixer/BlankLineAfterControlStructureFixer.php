<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Fixer;

use PhpCsFixer\Fixer\FixerInterface;
use PhpCsFixer\Fixer\WhitespacesAwareFixerInterface;
use PhpCsFixer\FixerDefinition\CodeSample;
use PhpCsFixer\FixerDefinition\FixerDefinition;
use PhpCsFixer\FixerDefinition\FixerDefinitionInterface;
use PhpCsFixer\Tokenizer\Token;
use PhpCsFixer\Tokenizer\Tokens;
use PhpCsFixer\WhitespacesFixerConfig;
use SplFileInfo;

/**
 * Separates a control structure from whatever follows it with a blank line.
 *
 * `blank_line_before_statement` writes a blank line in front of a statement;
 * nothing writes one after a block. That gap is not a matter of taste: measured
 * over a 48-class extension, a closing brace inside a method body is followed by
 * a blank line in 232 of 247 places — 93 %, against 37 % for the blank line
 * before an `if` that the shipped rule does enforce. The one rule the code
 * actually keeps is the one no fixer knows.
 *
 * It matters for the same reason the chain rule does: a printer renders from a
 * syntax tree and reproduces whatever the rules say. Every blank line a rule
 * does not describe is gone the first time a file is written back.
 *
 * The alternative syntax (`if (…): … endif;`) has no brace and is not covered.
 * A syntax tree never prints it, which is the case this rule exists for.
 */
final class BlankLineAfterControlStructureFixer implements FixerInterface, WhitespacesAwareFixerInterface
{
    /**
     * The keywords whose block this rule applies to. `else`, `elseif`, `catch`
     * and `finally` are in here as block heads; they are excluded separately as
     * *followers*, where a blank line would tear one structure apart.
     */
    private const HEADS = [
        T_IF,
        T_ELSE,
        T_ELSEIF,
        T_FOR,
        T_FOREACH,
        T_WHILE,
        T_DO,
        T_SWITCH,
        T_TRY,
        T_CATCH,
        T_FINALLY,
    ];

    /**
     * A blank line in front of any of these would separate a structure from its
     * own continuation. `while` is here for `do { … } while (…);`.
     */
    private const CONTINUATIONS = [
        T_ELSE,
        T_ELSEIF,
        T_CATCH,
        T_FINALLY,
        T_WHILE,
    ];

    private WhitespacesFixerConfig $whitespacesConfig;

    public function __construct()
    {
        $this->whitespacesConfig = new WhitespacesFixerConfig();
    }

    public function setWhitespacesConfig(WhitespacesFixerConfig $config): void
    {
        $this->whitespacesConfig = $config;
    }

    public function getName(): string
    {
        return 'Netresearch/blank_line_after_control_structure';
    }

    public function getPriority(): int
    {
        // Below `no_extra_blank_lines` (-20 in the shipped set is lower still),
        // so that whatever removes blank lines has had its say first and this
        // rule is not undone right after it ran.
        return -21;
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
        return $tokens->isAnyTokenKindsFound(self::HEADS);
    }

    public function getDefinition(): FixerDefinitionInterface
    {
        return new FixerDefinition(
            'A control structure is separated from the statement after it by a blank line.',
            [
                new CodeSample(
                    "<?php\nif (\$a) {\n    b();\n}\nc();\n",
                ),
            ],
        );
    }

    public function fix(SplFileInfo $file, Tokens $tokens): void
    {
        // Back to front, so that a brace still to be looked at keeps its index.
        // Only whitespace is replaced, never inserted, so the indices hold
        // anyway — the direction is what keeps that true if that ever changes.
        for ($index = count($tokens) - 1; $index > 0; --$index) {
            if (!$tokens[$index]->equals('}') || !$this->closesControlStructure($tokens, $index)) {
                continue;
            }

            $anchor = $this->separationPoint($tokens, $index);

            if ($anchor !== null) {
                $this->separate($tokens, $anchor);
            }
        }
    }

    /**
     * The token the structure ends at, or null when nothing is to be separated.
     *
     * That is the brace itself, except for `do { … } while (…);`, which ends at
     * the semicolon.
     */
    private function separationPoint(Tokens $tokens, int $brace): ?int
    {
        $next = $tokens->getNextMeaningfulToken($brace);

        if ($next === null) {
            return null;
        }

        $anchor = $brace;

        if ($tokens[$next]->isGivenKind(T_WHILE)) {
            $anchor = $this->endOfDoWhile($tokens, $next) ?? $anchor;
            $next   = $tokens->getNextMeaningfulToken($anchor);

            if ($next === null) {
                return null;
            }
        }

        return $this->isContinuation($tokens, $next) ? null : $anchor;
    }

    private function separate(Tokens $tokens, int $anchor): void
    {
        $lineEnding = $this->whitespacesConfig->getLineEnding();
        $whitespace = $tokens[$anchor + 1];

        // Nothing to separate when the next statement continues on the same
        // line: this rule writes a blank line, it does not break one. How
        // compactly the body itself is written does not matter.
        if (!$whitespace->isWhitespace() || !str_contains($whitespace->getContent(), $lineEnding)) {
            return;
        }

        $lines = explode($lineEnding, $whitespace->getContent());

        // More than one blank line already: how many is too many belongs to
        // `no_extra_blank_lines`, and fighting it would cost the fixed point.
        if (count($lines) > 2) {
            return;
        }

        $tokens[$anchor + 1] = new Token([
            T_WHITESPACE,
            $lineEnding . $lineEnding . end($lines),
        ]);
    }

    /**
     * Whether the brace at `$index` closes the block of a control structure —
     * as opposed to a function body, a class body, a closure or a match arm.
     */
    private function closesControlStructure(Tokens $tokens, int $index): bool
    {
        $open = $tokens->findBlockStart(Tokens::BLOCK_TYPE_CURLY_BRACE, $index);
        $head = $tokens->getPrevMeaningfulToken($open);

        if ($head === null) {
            return false;
        }

        // `if (…) {`, `foreach (…) {`, `catch (…) {` — step over the condition.
        if ($tokens[$head]->equals(')')) {
            $head = $tokens->getPrevMeaningfulToken(
                $tokens->findBlockStart(Tokens::BLOCK_TYPE_PARENTHESIS_BRACE, $head),
            );

            if ($head === null) {
                return false;
            }
        }

        return $tokens[$head]->isGivenKind(self::HEADS);
    }

    /**
     * The semicolon that ends a `do { … } while (…);`, or null when the `while`
     * at `$index` opens a loop of its own.
     */
    private function endOfDoWhile(Tokens $tokens, int $index): ?int
    {
        $condition = $tokens->getNextMeaningfulToken($index);

        if ($condition === null || !$tokens[$condition]->equals('(')) {
            return null;
        }

        $semicolon = $tokens->getNextMeaningfulToken(
            $tokens->findBlockEnd(Tokens::BLOCK_TYPE_PARENTHESIS_BRACE, $condition),
        );

        return $semicolon !== null && $tokens[$semicolon]->equals(';') ? $semicolon : null;
    }

    private function isContinuation(Tokens $tokens, int $index): bool
    {
        // `}` closing the parent, and `};` / `},` / `})` — a brace that is part
        // of an expression rather than the end of a statement.
        if ($tokens[$index]->equalsAny(['}', ';', ',', ')', ']'])) {
            return true;
        }

        return $tokens[$index]->isGivenKind(self::CONTINUATIONS);
    }
}
