<?php

/*
 * Fixture check for the Netresearch/blank_line_after_control_structure fixer.
 *
 * Every case states the input and the exact expected output, and every case is
 * run twice: a formatting rule that does not reach a fixed point rewrites the
 * code base on each run, so idempotence is checked here rather than noticed in
 * a pull request.
 *
 * Usage: php Build/Scripts/check-blank-line-after-control-structure.php
 */

declare(strict_types=1);

use Netresearch\Typo3CiWorkflows\Fixer\BlankLineAfterControlStructureFixer;
use PhpCsFixer\Tokenizer\Tokens;

require_once __DIR__ . '/../../vendor/autoload.php';

function applyFixer(string $code): string
{
    $tokens = Tokens::fromCode($code);
    (new BlankLineAfterControlStructureFixer())->fix(new SplFileInfo(__FILE__), $tokens);

    return $tokens->generateCode();
}

/**
 * Wraps a method body, because that is the only place the rule applies and the
 * indentation of the surrounding scope is part of what it writes.
 */
function inBody(string $body): string
{
    return "<?php\nclass C\n{\n    public function m(): void\n    {\n" . $body . "    }\n}";
}

// The if/c() pair is the rule's basic shape and stands in three cases: what it
// writes, and what it leaves alone once it is there.
const IF_JOINED    = "        if (\$a) {\n            b();\n        }\n        c();\n";
const IF_SEPARATED = "        if (\$a) {\n            b();\n        }\n\n        c();\n";

$cases = [];

$cases['an if is separated from what follows'] = [
    'in'  => inBody(IF_JOINED),
    'out' => inBody(IF_SEPARATED),
];

$cases['else is not torn off its if'] = [
    'in'  => inBody("        if (\$a) {\n            b();\n        } else {\n            d();\n        }\n"),
    'out' => inBody("        if (\$a) {\n            b();\n        } else {\n            d();\n        }\n"),
];

$cases['a continuation on its own line is not torn off either'] = [
    // `} else {` needs no guard — the continuation is on the same line and the
    // rule only ever writes where a line break already is. On input that has
    // not been through `braces_position` yet, it does need one.
    'in'  => inBody("        if (\$a) {\n            b();\n        }\n        else {\n            d();\n        }\n"),
    'out' => inBody("        if (\$a) {\n            b();\n        }\n        else {\n            d();\n        }\n"),
];

$cases['a do-while whose while is on its own line stays whole'] = [
    'in'  => inBody("        do {\n            j();\n        }\n        while (\$a);\n"),
    'out' => inBody("        do {\n            j();\n        }\n        while (\$a);\n"),
];

$cases['catch and finally stay attached'] = [
    'in'  => inBody("        try {\n            f();\n        } catch (Throwable \$t) {\n            g();\n        } finally {\n            h();\n        }\n"),
    'out' => inBody("        try {\n            f();\n        } catch (Throwable \$t) {\n            g();\n        } finally {\n            h();\n        }\n"),
];

$cases['a do-while is separated after its semicolon, not its brace'] = [
    'in'  => inBody("        do {\n            j();\n        } while (\$a);\n        k();\n"),
    'out' => inBody("        do {\n            j();\n        } while (\$a);\n\n        k();\n"),
];

$cases['a block that ends its parent gets nothing'] = [
    'in'  => inBody("        foreach (\$x as \$v) {\n            if (\$v) {\n                l();\n            }\n        }\n"),
    'out' => inBody("        foreach (\$x as \$v) {\n            if (\$v) {\n                l();\n            }\n        }\n"),
];

$cases['a closure is not a control structure'] = [
    'in'  => inBody("        \$fn = function () {\n            return 1;\n        };\n        n();\n"),
    'out' => inBody("        \$fn = function () {\n            return 1;\n        };\n        n();\n"),
];

$cases['a match arm list is not a control structure'] = [
    'in'  => inBody("        \$y = match (\$a) {\n            default => 3,\n        };\n        n();\n"),
    'out' => inBody("        \$y = match (\$a) {\n            default => 3,\n        };\n        n();\n"),
];

$cases['a switch is separated'] = [
    'in'  => inBody("        switch (\$a) {\n            case 1:\n                break;\n        }\n        o();\n"),
    'out' => inBody("        switch (\$a) {\n            case 1:\n                break;\n        }\n\n        o();\n"),
];

$cases['a compact block is still a control structure'] = [
    // The rule separates a structure from the statement after it; how compactly
    // the body is written does not change that. @PER-CS3.0 does not produce
    // one-line bodies in the first place.
    'in'  => inBody("        if (\$a) { b(); }\n        c();\n"),
    'out' => inBody("        if (\$a) { b(); }\n\n        c();\n"),
];

$cases['what continues on the same line is left alone'] = [
    // Nothing to separate: the rule writes a blank line, it does not break one.
    'in'  => inBody("        if (\$a) { b(); } c();\n"),
    'out' => inBody("        if (\$a) { b(); } c();\n"),
];

$cases['a blank line that is already there stays one'] = [
    'in'  => inBody(IF_SEPARATED),
    'out' => inBody(IF_SEPARATED),
];

$cases['two blank lines are left to the rule that owns them'] = [
    // `no_extra_blank_lines` decides how many blank lines are too many. Writing
    // exactly one here would fight it on every run.
    'in'  => inBody("        if (\$a) {\n            b();\n        }\n\n\n        c();\n"),
    'out' => inBody("        if (\$a) {\n            b();\n        }\n\n\n        c();\n"),
];

$cases['a method body end belongs to another rule'] = [
    'in'  => "<?php\nclass C\n{\n    public function m(): void\n    {\n        a();\n    }\n    public function n(): void\n    {\n        b();\n    }\n}",
    'out' => "<?php\nclass C\n{\n    public function m(): void\n    {\n        a();\n    }\n    public function n(): void\n    {\n        b();\n    }\n}",
];

$status = 0;

// A case whose fixture silently loses its body still passes, so the count is
// asserted too.
if (count($cases) !== 15) {
    echo 'FAIL: expected 15 cases, found ' . count($cases) . "\n";
    $status = 1;
}

foreach ($cases as $name => $case) {
    $first  = applyFixer($case['in']);
    $second = applyFixer($first);

    if ($first !== $case['out']) {
        echo "FAIL: {$name}\n--- expected ---\n{$case['out']}\n--- actual ---\n{$first}\n\n";
        $status = 1;

        continue;
    }

    if ($second !== $first) {
        echo "FAIL: {$name} — not idempotent\n--- run 2 ---\n{$second}\n\n";
        $status = 1;

        continue;
    }

    echo "ok: {$name}\n";
}

// `blank_line_before_statement` wants to write at the same place — after a
// closing brace, in front of a `return`. Both together must settle on exactly
// one blank line, in either order.
$both = Tokens::fromCode(inBody("        if (\$a) {\n            b();\n        }\n        return 1;\n"));
(new BlankLineAfterControlStructureFixer())->fix(new SplFileInfo(__FILE__), $both);
$statements = new PhpCsFixer\Fixer\Whitespace\BlankLineBeforeStatementFixer();
$statements->configure(['statements' => ['return']]);
$statements->fix(new SplFileInfo(__FILE__), $both);

if ($both->generateCode() !== inBody("        if (\$a) {\n            b();\n        }\n\n        return 1;\n")) {
    echo "FAIL: together with blank_line_before_statement\n--- actual ---\n" . $both->generateCode() . "\n";
    $status = 1;
} else {
    echo "ok: settles on one blank line with blank_line_before_statement\n";
}

// Tabs must reach the output, otherwise the rule fights the project's own
// indentation on every run.
$tabbed = Tokens::fromCode("<?php\nif (\$a) {\n\tb();\n}\nc();");
$fixer  = new BlankLineAfterControlStructureFixer();
$fixer->setWhitespacesConfig(new PhpCsFixer\WhitespacesFixerConfig("\t", "\n"));
$fixer->fix(new SplFileInfo(__FILE__), $tabbed);

if ($tabbed->generateCode() !== "<?php\nif (\$a) {\n\tb();\n}\n\nc();") {
    echo "FAIL: the configured line ending is ignored\n--- actual ---\n" . $tabbed->generateCode() . "\n";
    $status = 1;
} else {
    echo "ok: the configured whitespace is used\n";
}

exit($status);
