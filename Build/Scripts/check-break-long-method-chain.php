<?php

/*
 * Fixture check for the Netresearch/break_long_method_chain fixer.
 *
 * Every case states the input and the exact expected output, and every case is
 * run twice: a formatting rule that does not reach a fixed point rewrites the
 * code base on each run, so idempotence is checked here rather than noticed in
 * a pull request.
 *
 * Usage: php Build/Scripts/check-break-long-method-chain.php
 */

declare(strict_types=1);

use Netresearch\Typo3CiWorkflows\Fixer\BreakLongMethodChainFixer;
use PhpCsFixer\Tokenizer\Tokens;

require_once __DIR__ . '/../../vendor/autoload.php';

/**
 * @param array{minimum_links?: int} $configuration
 */
function applyFixer(string $code, array $configuration = []): string
{
    $fixer = new BreakLongMethodChainFixer();
    $fixer->configure($configuration);

    $tokens = Tokens::fromCode($code);
    $fixer->fix(new SplFileInfo(__FILE__), $tokens);

    return $tokens->generateCode();
}

$cases = [];

$cases['three calls are broken'] = [
    'in' => <<<'PHP'
        <?php
        $q->select('uid')->from('pages')->executeQuery();
        PHP,
    'out' => <<<'PHP'
        <?php
        $q
            ->select('uid')
            ->from('pages')
            ->executeQuery();
        PHP,
];

$cases['two calls stay on one line'] = [
    'in'  => "<?php\n\$q->from('pages')->executeQuery();",
    'out' => "<?php\n\$q->from('pages')->executeQuery();",
];

$cases['property hops keep their subject'] = [
    'in' => <<<'PHP'
        <?php
        $this->pool->getQueryBuilderForTable('pages')->select('uid')->executeQuery();
        PHP,
    'out' => <<<'PHP'
        <?php
        $this->pool
            ->getQueryBuilderForTable('pages')
            ->select('uid')
            ->executeQuery();
        PHP,
];

$cases['a property-only chain is not a chain'] = [
    'in'  => "<?php\n\$a->b->c->d->e;",
    'out' => "<?php\n\$a->b->c->d->e;",
];

$cases['separate calls in one expression are separate chains'] = [
    'in'  => "<?php\nif (\$a->b() && \$c->d() && \$e->f()) {\n}",
    'out' => "<?php\nif (\$a->b() && \$c->d() && \$e->f()) {\n}",
];

$cases['a chain inside a string is left alone'] = [
    'in'  => "<?php\n\$s = \"x{\$a->b()->c()->d()}y\";",
    'out' => "<?php\n\$s = \"x{\$a->b()->c()->d()}y\";",
];

$cases['a chain inside a heredoc is left alone'] = [
    // The guard against writing a line break into a string's value is a flag
    // carried along the scan, so it is checked in both places a `{$...}` can
    // appear, not only in a double-quoted string.
    'in' => <<<'PHP'
        <?php
        $sql = <<<SQL
            SELECT {$a->b()->c()->d()} FROM t
            SQL;
        PHP,
    'out' => <<<'PHP'
        <?php
        $sql = <<<SQL
            SELECT {$a->b()->c()->d()} FROM t
            SQL;
        PHP,
];

$cases['a chain that only looks like one inside a nowdoc is left alone'] = [
    'in' => <<<'PHP'
        <?php
        $text = <<<'SQL'
            literal $a->b()->c()->d()
            SQL;
        PHP,
    'out' => <<<'PHP'
        <?php
        $text = <<<'SQL'
            literal $a->b()->c()->d()
            SQL;
        PHP,
];

$cases['a dynamic call aborts the chain'] = [
    'in'  => "<?php\n\$a->b()->{\$c}()->d()->e();",
    'out' => "<?php\n\$a->b()->{\$c}()->d()->e();",
];

$cases['indentation follows the statement, not the chain'] = [
    'in' => <<<'PHP'
        <?php
        class C
        {
            public function m(): void
            {
                $this->q->select('uid')->from('pages')->executeQuery();
            }
        }
        PHP,
    'out' => <<<'PHP'
        <?php
        class C
        {
            public function m(): void
            {
                $this->q
                    ->select('uid')
                    ->from('pages')
                    ->executeQuery();
            }
        }
        PHP,
];

$cases['a chain in an argument is indented against that argument'] = [
    'in' => <<<'PHP'
        <?php
        $q->where(
            $q->expr()->in('uid', $x)->and($y)->or($z)
        );
        PHP,
    'out' => <<<'PHP'
        <?php
        $q->where(
            $q
                ->expr()
                ->in('uid', $x)
                ->and($y)
                ->or($z)
        );
        PHP,
];

$cases['a chain nested in another chain is broken against the outer one'] = [
    // Regression guard: the inner chain sits at higher token indices than the
    // outer chain's last links, so breaking both from one collected set applies
    // the outer breaks at indices the inner insertions have already moved. That
    // produced code such as `->eq('x'\n, 0)` and `)->orderBy\n('a', 'b')`.
    'in' => <<<'PHP'
        <?php
        $row = $q->select(1)->from(2)->where($q->expr()->eq(3)->and(4))->executeQuery();
        PHP,
    'out' => <<<'PHP'
        <?php
        $row = $q
            ->select(1)
            ->from(2)
            ->where($q
                ->expr()
                ->eq(3)
                ->and(4))
            ->executeQuery();
        PHP,
];

$cases['two chains in one argument list land on the same level'] = [
    // Regression guard: with a comma taken as a statement boundary, the second
    // chain derives its indentation from the first one *after* that has been
    // broken, and the two come out a level apart for no reason.
    'in' => <<<'PHP'
        <?php
        foo($a->b()->c()->d(), $e->f()->g()->h());
        PHP,
    'out' => <<<'PHP'
        <?php
        foo($a
            ->b()
            ->c()
            ->d(), $e
            ->f()
            ->g()
            ->h());
        PHP,
];

$cases['an array access between links does not end the chain'] = [
    'in'  => "<?php\n\$a->b()[0]->c()->d();",
    'out' => "<?php\n\$a\n    ->b()[0]\n    ->c()\n    ->d();",
];

$cases['a nullsafe operator counts as a link'] = [
    'in'  => "<?php\n\$a?->b()?->c()?->d();",
    'out' => "<?php\n\$a\n    ?->b()\n    ?->c()\n    ?->d();",
];

$status = 0;

// A case whose fixture silently loses its body — an unescaped `$a` in a
// double-quoted string, say — still passes, so the count is asserted too.
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

// The threshold is what the rule is configured on, so it is checked directly.
$twoLinks = applyFixer("<?php\n\$q->from('pages')->executeQuery();", ['minimum_links' => 2]);

if ($twoLinks !== "<?php\n\$q\n    ->from('pages')\n    ->executeQuery();") {
    echo "FAIL: minimum_links is not honoured\n--- actual ---\n{$twoLinks}\n";
    $status = 1;
} else {
    echo "ok: minimum_links is honoured\n";
}

// Tabs must reach the output, otherwise the rule fights the project's own
// indentation on every run.
$fixer = new BreakLongMethodChainFixer();
$fixer->configure([]);
$fixer->setWhitespacesConfig(new PhpCsFixer\WhitespacesFixerConfig("\t", "\n"));
$tokens = Tokens::fromCode("<?php\n\$q->a()->b()->c();");
$fixer->fix(new SplFileInfo(__FILE__), $tokens);

if ($tokens->generateCode() !== "<?php\n\$q\n\t->a()\n\t->b()\n\t->c();") {
    echo "FAIL: the configured indent is ignored\n--- actual ---\n" . $tokens->generateCode() . "\n";
    $status = 1;
} else {
    echo "ok: the configured indent is used\n";
}

// A threshold below one is not a smaller threshold, it is a different fixer:
// every property access becomes an empty candidate chain and the first link is
// read out of an empty list.
foreach ([0, -1] as $invalid) {
    try {
        applyFixer("<?php\n\$a->b->c;", ['minimum_links' => $invalid]);
        echo "FAIL: minimum_links = {$invalid} was accepted\n";
        $status = 1;
    } catch (PhpCsFixer\ConfigurationException\InvalidFixerConfigurationException) {
        echo "ok: minimum_links = {$invalid} is rejected\n";
    }
}

// The bug that made the nested case necessary showed itself on a whole file
// rather than on one statement: applying the outer chain's breaks at indices the
// inner insertions had already moved pushed a `(` or a `,` onto the front of a
// line — `->orderBy\n('created_at',` and `->eq('revoked_at'\n, 0)`. The output
// still parsed, so nothing downstream complained until `statement_indentation`
// died on the result and PHP-CS-Fixer reported the file as "not fixed". Chains
// nested three deep across several statements are what it takes to see it, so
// the check is a structural one over such a sample.
$manyChains = <<<'PHP'
    <?php
    class C
    {
        public function m(): void
        {
            $row = $q->select('*')->from(self::TABLE)->where(
                $q->expr()->eq('credential_id', $q->createNamedParameter($id, ParameterType::BINARY)),
                $q->expr()->eq('deleted', 0)
            )->executeQuery()->fetchAssociative();
            $rows = $q->select('*')->from(self::TABLE)->where(
                $q->expr()->eq('be_user', $q->createNamedParameter($uid, ParameterType::INTEGER)),
                $q->expr()->eq('deleted', 0),
                $q->expr()->eq('revoked_at', 0)
            )->orderBy('created_at', 'DESC')->executeQuery()->fetchAllAssociative();
        }
    }
    PHP;

$fixed = applyFixer($manyChains, ['minimum_links' => 2]);
$stray = [];

foreach (explode("\n", $fixed) as $number => $line) {
    if (preg_match('/^\s*[(,]/', $line) === 1) {
        $stray[] = ($number + 1) . ': ' . trim($line);
    }
}

if ($stray !== []) {
    echo "FAIL: a break landed in front of an argument separator\n  " . implode("\n  ", $stray) . "\n";
    $status = 1;
} else {
    echo "ok: no break lands in front of a separator\n";
}

exit($status);
