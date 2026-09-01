<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Fixer;

use PhpCsFixer\FixerDefinition\CodeSample;
use PhpCsFixer\FixerDefinition\FixerDefinition;
use PhpCsFixer\FixerDefinition\FixerDefinitionInterface;
use PhpCsFixer\Tokenizer\Token;
use PhpCsFixer\Tokenizer\Tokens;
use SplFileInfo;

/**
 * Separates a comment on a line of its own from the code above it.
 *
 * `blank_line_before_statement` can write a blank line in front of a docblock,
 * but not in front of a `//` comment — a comment is not a statement, and no
 * shipped fixer treats it as one. Measured over a 48-class extension plus its
 * tests: a line comment standing on its own line has a blank line above it in
 * 274 of 309 places, 89 %.
 *
 * It matters for the same reason the other two do: a printer renders from a
 * syntax tree and reproduces whatever the rules say. A comment that introduces
 * the next few statements loses the gap that made it an introduction, and ends
 * up glued to the statement above, which it does not describe.
 *
 * Inside brackets the rule is off. A comment between the entries of an array or
 * an argument list explains the entry below it, and a blank line there splits a
 * list that belongs together — that is where every counter-example in the
 * measured code base sits.
 */
final class BlankLineBeforeCommentFixer extends AbstractWhitespaceAwareFixer
{
    public function getName(): string
    {
        return 'Netresearch/blank_line_before_comment';
    }

    public function getPriority(): int
    {
        // With the other two Netresearch fixers, below `no_extra_blank_lines`
        // (-20), so the rule that removes blank lines has had its say first.
        return -21;
    }

    public function isCandidate(Tokens $tokens): bool
    {
        return $tokens->isTokenKindFound(T_COMMENT);
    }

    public function getDefinition(): FixerDefinitionInterface
    {
        return new FixerDefinition(
            'A comment on a line of its own is separated from the code above it by a blank line.',
            [
                new CodeSample(
                    "<?php\n\$a = 1;\n// why the next part exists\n\$b = 2;\n",
                ),
            ],
        );
    }

    public function fix(SplFileInfo $file, Tokens $tokens): void
    {
        $lineEnding = $this->whitespacesConfig->getLineEnding();

        // Back to front: only whitespace is replaced, so indices hold either
        // way, but the direction keeps that true if that ever changes.
        for ($index = count($tokens) - 1; $index > 0; --$index) {
            if (!$tokens[$index]->isGivenKind(T_COMMENT) || !$this->startsItsOwnLine($tokens, $index)) {
                continue;
            }

            if ($this->isInsideBrackets($tokens, $index) || $this->continuesSomething($tokens, $index)) {
                continue;
            }

            $whitespace = $tokens[$index - 1]->getContent();
            $lines      = explode($lineEnding, $whitespace);

            // Already separated, or separated by more than one line — how many
            // is too many belongs to `no_extra_blank_lines`.
            if (count($lines) > 2) {
                continue;
            }

            $tokens[$index - 1] = new Token([T_WHITESPACE, $lineEnding . $lineEnding . end($lines)]);
        }
    }

    private function startsItsOwnLine(Tokens $tokens, int $index): bool
    {
        $before = $tokens[$index - 1];

        return $before->isWhitespace()
            && str_contains($before->getContent(), $this->whitespacesConfig->getLineEnding());
    }

    /**
     * Whether the comment continues something rather than introducing it: the
     * first thing in a block or a file, or one more line of a comment block.
     */
    private function continuesSomething(Tokens $tokens, int $index): bool
    {
        $previous = $tokens->getPrevNonWhitespace($index);

        if ($previous === null) {
            return true;
        }

        return $tokens[$previous]->isComment()
            || $tokens[$previous]->equalsAny(['{', ':'])
            || $tokens[$previous]->isGivenKind([T_OPEN_TAG, T_CURLY_OPEN]);
    }

    /**
     * Whether the comment sits between the entries of an array or an argument
     * list, where it explains the entry below and a blank line would split a
     * list that belongs together.
     */
    private function isInsideBrackets(Tokens $tokens, int $index): bool
    {
        $depth = 0;

        for ($i = $index - 1; $i >= 0; --$i) {
            // Compared by content, not by `equals()`: an array's `[` and a
            // destructuring `[` carry their own token kinds, and a comment
            // between array entries is exactly the case this guards.
            $content = $tokens[$i]->getContent();

            // A closing brace of any kind opens a balanced region going
            // backwards — a closure inside an array entry, for one. Skipping it
            // is what keeps the search from stopping short of the list.
            if ($content === ')' || $content === ']' || $content === '}') {
                ++$depth;

                continue;
            }

            if ($content === '(' || $content === '[') {
                if ($depth === 0) {
                    return true;
                }

                --$depth;

                continue;
            }

            if ($depth > 0) {
                if ($content === '{') {
                    --$depth;
                }

                continue;
            }

            // At depth zero a block edge or a statement end means the comment
            // is not in a list: an opening bracket further up cannot enclose it.
            if ($content === '{' || $content === ';') {
                return false;
            }
        }

        return false;
    }
}
