<?php

/*
 * The frame both fixer fixture checks run in.
 *
 * Each case states an input and the exact expected output, and each is run
 * twice: a formatting rule that does not reach a fixed point rewrites the code
 * base on every run, so idempotence is checked here rather than noticed in a
 * pull request. The case count is asserted too — a fixture whose body is lost,
 * to an unescaped `$a` in a double-quoted string say, passes green in that
 * state and only the count makes it visible.
 */

declare(strict_types=1);

/**
 * @param array<string, array{in: string, out: string}> $cases
 * @param callable(string): string                      $apply
 *
 * @return int an exit status: 0 when every case holds
 */
function runFixtures(array $cases, callable $apply, int $expectedCount): int
{
    $status = 0;

    if (count($cases) !== $expectedCount) {
        echo 'FAIL: expected ' . $expectedCount . ' cases, found ' . count($cases) . "\n";
        $status = 1;
    }

    foreach ($cases as $name => $case) {
        $first  = $apply($case['in']);
        $second = $apply($first);

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

    return $status;
}

/**
 * Reports one assertion that is not a fixture pair.
 */
function assertFixture(bool $holds, string $name, string $actual): int
{
    if ($holds) {
        echo "ok: {$name}\n";

        return 0;
    }

    echo "FAIL: {$name}\n--- actual ---\n{$actual}\n";

    return 1;
}
