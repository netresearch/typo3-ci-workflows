<?php

/*
 * Fixture check for the Netresearch/blank_line_before_comment fixer.
 * The frame every case runs in is in fixture-runner.php.
 *
 * Usage: php Build/Scripts/check-blank-line-before-comment.php
 */

declare(strict_types=1);

use Netresearch\Typo3CiWorkflows\Fixer\BlankLineBeforeCommentFixer;
use PhpCsFixer\Tokenizer\Tokens;

require_once __DIR__ . '/../../vendor/autoload.php';
require_once __DIR__ . '/fixture-runner.php';

function applyFixer(string $code): string
{
    $tokens = Tokens::fromCode($code);
    (new BlankLineBeforeCommentFixer())->fix(new SplFileInfo(__FILE__), $tokens);

    return $tokens->generateCode();
}

function inBody(string $body): string
{
    return "<?php\nclass C\n{\n    public function m(): void\n    {\n" . $body . "    }\n}";
}

$cases = [];

$cases['a comment introducing the next statements is separated'] = [
    'in'  => inBody("        \$a = 1;\n        // why the next part exists\n        \$b = 2;\n"),
    'out' => inBody("        \$a = 1;\n\n        // why the next part exists\n        \$b = 2;\n"),
];

$cases['the first thing in a block is not separated'] = [
    // There is nothing above it to separate from, and `no_blank_lines_after_…`
    // rules would take the line straight back out.
    'in'  => inBody("        // what this method does first\n        \$a = 1;\n"),
    'out' => inBody("        // what this method does first\n        \$a = 1;\n"),
];

$cases['a comment block gets one blank line, not one per line'] = [
    'in'  => inBody("        \$a = 1;\n        // first line\n        // second line\n        \$b = 2;\n"),
    'out' => inBody("        \$a = 1;\n\n        // first line\n        // second line\n        \$b = 2;\n"),
];

$cases['a comment between array entries is left alone'] = [
    // It explains the entry below it. A blank line there splits a list that
    // belongs together — and this is where every counter-example in the
    // measured code base sits.
    'in'  => inBody("        \$a = [\n            'a' => 1,\n            // why b\n            'b' => 2,\n        ];\n"),
    'out' => inBody("        \$a = [\n            'a' => 1,\n            // why b\n            'b' => 2,\n        ];\n"),
];

$cases['a comment between arguments is left alone'] = [
    'in'  => inBody("        foo(\n            \$a,\n            // why b\n            \$b,\n        );\n"),
    'out' => inBody("        foo(\n            \$a,\n            // why b\n            \$b,\n        );\n"),
];

$cases['a trailing comment is not on a line of its own'] = [
    'in'  => inBody("        \$a = 1; // in passing\n        \$b = 2;\n"),
    'out' => inBody("        \$a = 1; // in passing\n        \$b = 2;\n"),
];

$cases['a comment after a case label is not separated'] = [
    'in'  => inBody("        switch (\$a) {\n            case 1:\n                // what this branch means\n                break;\n        }\n"),
    'out' => inBody("        switch (\$a) {\n            case 1:\n                // what this branch means\n                break;\n        }\n"),
];

$cases['a docblock belongs to another rule'] = [
    // `blank_line_before_statement` with `phpdoc` owns those, and
    // `class_attributes_separation` owns the ones on class members.
    'in'  => inBody("        \$a = 1;\n        /** @var int \$b */\n        \$b = 2;\n"),
    'out' => inBody("        \$a = 1;\n        /** @var int \$b */\n        \$b = 2;\n"),
];

$cases['a blank line that is already there stays one'] = [
    'in'  => inBody("        \$a = 1;\n\n        // already separated\n        \$b = 2;\n"),
    'out' => inBody("        \$a = 1;\n\n        // already separated\n        \$b = 2;\n"),
];

$cases['two blank lines are left to the rule that owns them'] = [
    'in'  => inBody("        \$a = 1;\n\n\n        // still separated\n        \$b = 2;\n"),
    'out' => inBody("        \$a = 1;\n\n\n        // still separated\n        \$b = 2;\n"),
];

$status = runFixtures($cases, 'applyFixer', 10);

// Tabs must reach the output, otherwise the rule fights the project's own
// indentation on every run.
$tabbed = Tokens::fromCode("<?php\n\$a = 1;\n// why\n\$b = 2;");
$fixer  = new BlankLineBeforeCommentFixer();
$fixer->setWhitespacesConfig(new PhpCsFixer\WhitespacesFixerConfig("\t", "\n"));
$fixer->fix(new SplFileInfo(__FILE__), $tabbed);

$status |= assertFixture(
    $tabbed->generateCode() === "<?php\n\$a = 1;\n\n// why\n\$b = 2;",
    'the configured line ending is used',
    $tabbed->generateCode(),
);

exit($status);
