<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Unit\Changelog;

use FilesystemIterator;
use PHPUnit\Framework\Attributes\CoversNothing;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\Attributes\TestWith;
use PHPUnit\Framework\TestCase;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;
use SplFileInfo;

/**
 * Drives bin/changelog-fragments against throwaway git repositories.
 *
 * Fragments replace direct edits of the shared [Unreleased] section, which made
 * every open PR conflict with every merge. The release commit is the only place
 * that reads them, so the check also refuses fragments when the topmost
 * released section has no tag yet.
 */
#[CoversNothing]
final class ChangelogFragmentsTest extends TestCase
{
    private const CHANGELOG = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- An added line.\n\n### Fixed\n\n- A fixed line.\n\n## [1.2.0] - 2026-01-01\n\n### Fixed\n\n- Released.\n\n[Unreleased]: https://example.org/compare/v1.2.0...HEAD\n";

    private string $repo = '';

    /** @var array<string, string> Added to the environment of the script, not of git. */
    private array $scriptEnvironment = [];

    protected function setUp(): void
    {
        parent::setUp();
        $this->repo = sys_get_temp_dir() . '/typo3-ci-workflows-changelog-fragments-' . bin2hex(random_bytes(6));
        mkdir($this->repo . '/changelog.d', 0o777, true);
        $this->git('init', '--quiet');
        $this->git('config', 'user.email', 'test@example.org');
        $this->git('config', 'user.name', 'Test');
        $this->git('config', 'commit.gpgsign', 'false');
        $this->git('config', 'tag.gpgsign', 'false');
        $this->git('commit', '--quiet', '--allow-empty', '-m', 'release');
        $this->git('tag', 'v1.2.0');
        file_put_contents($this->repo . '/CHANGELOG.md', self::CHANGELOG);
    }

    protected function tearDown(): void
    {
        $this->removeTree($this->repo);
        parent::tearDown();
    }

    #[Test]
    public function collectAppendsUnderTheExistingHeadingAndDeletesTheFragment(): void
    {
        $this->fragment('feat-x.fixed.md', "- A new fix.\n  Wrapped line.\n");

        [$exit] = $this->runScript('collect');

        self::assertSame(0, $exit);
        self::assertSame(
            str_replace("- A fixed line.\n", "- A fixed line.\n\n- A new fix.\n  Wrapped line.\n", self::CHANGELOG),
            $this->changelog(),
        );
        self::assertFileDoesNotExist($this->repo . '/changelog.d/feat-x.fixed.md');
        self::assertSame([], glob($this->repo . '/CHANGELOG.md.collect*'));
    }

    #[Test]
    public function collectKeepsTheModeOfTheChangelog(): void
    {
        chmod($this->repo . '/CHANGELOG.md', 0o640);
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        [$exit] = $this->runScript('collect');

        clearstatcache();
        self::assertSame(0, $exit);
        self::assertSame(0o640, fileperms($this->repo . '/CHANGELOG.md') & 0o777);
    }

    #[Test]
    public function collectDoesNotWriteThroughACheckedInSymlink(): void
    {
        // A pull request could check in CHANGELOG.md.collect as a symlink to
        // any file of the person who later runs collect.
        $victim = $this->repo . '/.git/victim.txt';
        file_put_contents($victim, "untouched\n");
        symlink($victim, $this->repo . '/CHANGELOG.md.collect');
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        [$exit] = $this->runScript('collect');

        self::assertSame(0, $exit);
        self::assertSame("untouched\n", file_get_contents($victim));
        self::assertTrue(is_link($this->repo . '/CHANGELOG.md.collect'));
        self::assertStringContainsString("- A new fix.\n", $this->changelog());
    }

    #[Test]
    public function collectKeepsTheFragmentsWhenTheChangelogCannotBeWritten(): void
    {
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        // In a read-only project directory tempnam() falls back to the system
        // temp directory, which collect must refuse.
        chmod($this->repo, 0o555);
        clearstatcache();

        try {
            if (is_writable($this->repo)) {
                self::markTestSkipped('The test user can write a read-only directory (root).');
            }

            [$exit, , $stderr] = $this->runScript('collect');
        } finally {
            chmod($this->repo, 0o755);
        }

        self::assertSame(2, $exit);
        self::assertStringContainsString('it and the fragments are unchanged', $stderr);
        self::assertSame(self::CHANGELOG, $this->changelog());
        self::assertFileExists($this->repo . '/changelog.d/feat-x.fixed.md');
    }

    #[Test]
    public function collectFailsWhenAFragmentCannotBeDeleted(): void
    {
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        // A read-only directory refuses the deletion of the file inside it.
        chmod($this->repo . '/changelog.d', 0o555);
        clearstatcache();

        try {
            if (is_writable($this->repo . '/changelog.d')) {
                self::markTestSkipped('The test user can write a read-only directory (root).');
            }

            [$exit, , $stderr] = $this->runScript('collect');
        } finally {
            chmod($this->repo . '/changelog.d', 0o755);
        }

        self::assertSame(2, $exit);
        self::assertStringContainsString('1 could not be deleted', $stderr);
        self::assertStringContainsString('feat-x.fixed.md', $stderr);
        self::assertStringContainsString("- A fixed line.\n\n- A new fix.\n", $this->changelog());
    }

    #[Test]
    public function collectInsertsAMissingHeadingInKeepAChangelogOrder(): void
    {
        $this->fragment('a.removed.md', "- A removal.\n");
        $this->fragment('b.security.md', "- A security fix.\n");

        [$exit] = $this->runScript('collect');

        self::assertSame(0, $exit);
        self::assertSame(
            "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- An added line.\n\n### Removed\n\n- A removal.\n\n### Fixed\n\n- A fixed line.\n\n### Security\n\n- A security fix.\n\n## [1.2.0] - 2026-01-01\n\n### Fixed\n\n- Released.\n\n[Unreleased]: https://example.org/compare/v1.2.0...HEAD\n",
            $this->changelog(),
        );
    }

    #[Test]
    public function collectKeepsFragmentsOfOneHeadingInFileNameOrder(): void
    {
        $this->fragment('z-last.added.md', "- Second.\n");
        $this->fragment('a-first.added.md', "- First.\n");

        [$exit, , $stderr] = $this->runScript('collect');

        self::assertSame(0, $exit, $stderr);
        self::assertStringContainsString("- An added line.\n\n- First.\n\n- Second.\n\n### Fixed", $this->changelog());
    }

    #[Test]
    public function anUpgradingFragmentGetsAHeadingNamedAfterTheLastRelease(): void
    {
        $this->fragment('a.upgrading.md', "- Run the wizard.\n");

        [$exit, , $stderr] = $this->runScript('collect');

        self::assertSame(0, $exit, $stderr);
        self::assertStringContainsString(
            "## [Unreleased]\n\n### Upgrading from 1.2\n\n- Run the wizard.\n\n### Added",
            $this->changelog(),
        );
    }

    #[Test]
    #[TestWith(['### Upgrading from 1.1'])]
    #[TestWith(['### Upgrading'])]
    public function anUpgradingFragmentJoinsAnExistingUpgradingHeading(string $heading): void
    {
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            str_replace("### Added\n", $heading . "\n\n- Old note.\n\n### Added\n", self::CHANGELOG),
        );
        $this->fragment('a.upgrading.md', "- New note.\n");

        [$exit, , $stderr] = $this->runScript('collect');

        self::assertSame(0, $exit, $stderr);
        self::assertStringContainsString($heading . "\n\n- Old note.\n\n- New note.\n\n### Added", $this->changelog());
        self::assertSame(1, substr_count($this->changelog(), '### Upgrading'));
    }

    #[Test]
    public function collectFindsAHeadingInACrlfChangelog(): void
    {
        // A Windows checkout with core.autocrlf: the heading line ends in "\r".
        file_put_contents($this->repo . '/CHANGELOG.md', str_replace("\n", "\r\n", self::CHANGELOG));
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        [$exit] = $this->runScript('collect');

        $changelog = $this->changelog();
        self::assertSame(0, $exit);
        self::assertSame(2, substr_count($changelog, '### Fixed'), 'one in [Unreleased], one in [1.2.0]');
        self::assertMatchesRegularExpression('/- A fixed line\.\r?\n\r?\n- A new fix\.\n/', $changelog);
    }

    #[Test]
    public function collectWithoutFragmentsChangesNothing(): void
    {
        file_put_contents($this->repo . '/changelog.d/README.md', "# Fragments\n");

        [$exit, $stdout] = $this->runScript('collect');

        self::assertSame(0, $exit);
        self::assertStringContainsString('nothing to collect', $stdout);
        self::assertSame(self::CHANGELOG, $this->changelog());
        self::assertFileExists($this->repo . '/changelog.d/README.md');
    }

    #[Test]
    public function checkAcceptsWellFormedFragmentsBesideTheReadme(): void
    {
        file_put_contents($this->repo . '/changelog.d/README.md', "# Fragments\n");
        $this->fragment('fix-thing.fixed.md', "- A fix.\n");

        [$exit, $stdout] = $this->runScript('check');

        self::assertSame(0, $exit);
        self::assertStringContainsString('1 fragment(s) ok', $stdout);
    }

    #[Test]
    public function checkRefusesAFragmentWithAnUnknownSection(): void
    {
        $this->fragment('fix-thing.bugfix.md', "- A fix.\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('fix-thing.bugfix.md  is not named', $stderr);
    }

    #[Test]
    public function checkRefusesAFragmentThatIsNoBullet(): void
    {
        $this->fragment('fix-thing.fixed.md', "A fix.\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('must start with a top-level bullet', $stderr);
    }

    #[Test]
    public function checkRefusesAFragmentWithAHeading(): void
    {
        $this->fragment('fix-thing.fixed.md', "- A fix.\n\n### Fixed\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('must not contain a heading', $stderr);
    }

    #[Test]
    public function checkRefusesAFragmentWithALinkDefinition(): void
    {
        // collect() takes a line like this for the end of [Unreleased].
        $this->fragment('a.fixed.md', "- See [guide].\n\n[guide]: https://example.org\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('must not contain a link definition', $stderr);
    }

    #[Test]
    public function collectWritesNothingWhenAFragmentIsMalformed(): void
    {
        $this->fragment('good.fixed.md', "- A fix.\n");
        $this->fragment('bad.fixed.md', "No bullet.\n");

        [$exit] = $this->runScript('collect');

        self::assertSame(1, $exit);
        self::assertSame(self::CHANGELOG, $this->changelog());
        self::assertFileExists($this->repo . '/changelog.d/good.fixed.md');
    }

    #[Test]
    public function checkRefusesFragmentsInAReleaseCommit(): void
    {
        // The release commit renamed [Unreleased] to [1.3.0], which has no tag
        // yet, and did not collect the fragment: 1.3.0 would ship without it.
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            str_replace('## [Unreleased]', "## [Unreleased]\n\n## [1.3.0] - 2026-02-01", self::CHANGELOG),
        );
        $this->fragment('fix-thing.fixed.md', "- A fix.\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('[1.3.0] has no tag v1.3.0 yet, and 1 fragment(s) are left', $stderr);
        self::assertStringContainsString('composer changelog:collect', $stderr);
        self::assertStringContainsString('push tag v1.3.0', $stderr);
    }

    #[Test]
    public function checkAcceptsFragmentsWhenTheReleaseTagExistsOnlyOnOrigin(): void
    {
        // A CI checkout has no tags. The tag is looked up on origin without
        // being fetched, so a full clone does not turn shallow.
        $origin = $this->repo . '/.git/test-origin.git';
        $this->git('init', '--quiet', '--bare', $origin);
        $this->git('remote', 'add', 'origin', $origin);
        $this->git('tag', 'v1.3.0');
        $this->git('push', '--quiet', 'origin', 'refs/tags/v1.3.0');
        $this->git('tag', '-d', 'v1.3.0');
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            str_replace('## [Unreleased]', "## [Unreleased]\n\n## [1.3.0] - 2026-02-01", self::CHANGELOG),
        );
        $this->fragment('fix-thing.fixed.md', "- A fix.\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(0, $exit, $stderr);
        self::assertSame('', $this->git('tag', '--list', 'v1.3.0'));
    }

    #[Test]
    public function checkStopsWhenOriginCannotBeAsked(): void
    {
        $this->git('remote', 'add', 'origin', $this->repo . '/.git/missing.git');
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            str_replace('## [Unreleased]', "## [Unreleased]\n\n## [1.3.0] - 2026-02-01", self::CHANGELOG),
        );
        $this->fragment('fix-thing.fixed.md', "- A fix.\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(2, $exit);
        self::assertStringContainsString('cannot ask origin whether tag v1.3.0 exists', $stderr);
        self::assertStringNotContainsString('has no tag', $stderr);
    }

    #[Test]
    public function aReleaseCommitWithoutFragmentsPasses(): void
    {
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            str_replace('## [Unreleased]', "## [Unreleased]\n\n## [1.3.0] - 2026-02-01", self::CHANGELOG),
        );

        [$exit] = $this->runScript('check');

        self::assertSame(0, $exit);
    }

    #[Test]
    public function theGitEnvironmentOfAHookIsNotUsed(): void
    {
        $outer = getenv('GIT_DIR');
        putenv('GIT_DIR=' . $this->repo . '/.git/outer');

        try {
            $this->git('tag', 'v1.3.0');
            file_put_contents(
                $this->repo . '/CHANGELOG.md',
                str_replace('## [Unreleased]', "## [Unreleased]\n\n## [1.3.0] - 2026-02-01", self::CHANGELOG),
            );
            $this->fragment('fix-thing.fixed.md', "- A fix.\n");

            [$exit, , $stderr] = $this->runScript('check');
        } finally {
            putenv($outer === false ? 'GIT_DIR' : 'GIT_DIR=' . $outer);
        }

        self::assertSame(0, $exit, $stderr);
    }

    #[Test]
    public function theRepositoryRootDefaultsToTheWorkingDirectory(): void
    {
        // Composer runs a script from the project root, and a Composer bin
        // lives in vendor/bin, so the bin's own location says nothing.
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        [$exit, , $stderr] = $this->runIn($this->repo, 'collect');

        self::assertSame(0, $exit, $stderr);
        self::assertStringContainsString("- A fixed line.\n\n- A new fix.\n", $this->changelog());
    }

    /**
     * @param list<string> $args
     */
    #[Test]
    #[TestWith([['--dry-run']])]
    #[TestWith([['check', '--dry-run']])]
    #[TestWith([['check', 'a', 'b']])]
    #[TestWith([['fix']])]
    #[TestWith([[]])]
    public function aUsageErrorChangesNothing(array $args): void
    {
        $this->fragment('feat-x.fixed.md', "- A new fix.\n");

        [$exit, , $stderr] = $this->runIn($this->repo, ...$args);

        self::assertSame(2, $exit);
        self::assertNotSame('', $stderr);
        self::assertSame(self::CHANGELOG, $this->changelog());
        self::assertFileExists($this->repo . '/changelog.d/feat-x.fixed.md');
    }

    #[Test]
    public function anOptionIsRefusedByName(): void
    {
        // The CGL job runs "composer ci:cgl -- --dry-run" in a repository
        // without ci:test:php:cgl, and Composer appends that option to every
        // script in the chain.
        [$exit, , $stderr] = $this->runIn($this->repo, 'check', '--dry-run');

        self::assertSame(2, $exit);
        self::assertStringContainsString('unknown option --dry-run', $stderr);
    }

    #[Test]
    public function aSymlinkedFragmentDirectoryIsRefusedAndNothingOutsideIsDeleted(): void
    {
        $outside = $this->repo . '/.git/outside';
        mkdir($outside);
        file_put_contents($outside . '/keep.fixed.md', "- Not a fragment of this repository.\n");
        rmdir($this->repo . '/changelog.d');
        symlink($outside, $this->repo . '/changelog.d');

        [$exit, , $stderr] = $this->runScript('collect');

        self::assertSame(1, $exit);
        self::assertStringContainsString('changelog.d  is a symbolic link', $stderr);
        self::assertFileExists($outside . '/keep.fixed.md');
        self::assertSame(self::CHANGELOG, $this->changelog());
    }

    #[Test]
    public function aSymlinkedFragmentIsRefused(): void
    {
        file_put_contents($this->repo . '/.git/target.md', "- Read through the link.\n");
        symlink($this->repo . '/.git/target.md', $this->repo . '/changelog.d/a.fixed.md');

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('a.fixed.md  is a symbolic link', $stderr);
    }

    #[Test]
    #[TestWith(["- A fix.\n\nNotes\n=====\n"])]
    #[TestWith(["- A fix.\n\nNotes\n-----\n"])]
    #[TestWith(["- A fix.\n\n---\n\n- Another.\n"])]
    public function checkRefusesAHeadingUnderlineOrARule(string $text): void
    {
        $this->fragment('a.fixed.md', $text);

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('must not contain a heading underline or a horizontal rule', $stderr);
    }

    #[Test]
    public function checkRefusesALinkDefinitionWithItsDestinationOnTheNextLine(): void
    {
        $this->fragment('a.fixed.md', "- See [guide].\n\n[guide]:\n  https://example.org\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit);
        self::assertStringContainsString('must not contain a link definition', $stderr);
    }

    #[Test]
    public function checkDoesNotUseTheRepositoryOfAHooksGitDir(): void
    {
        // A hook of another repository exports GIT_DIR. That repository has
        // the tag; the checked one does not, so the check must refuse.
        $other = $this->repo . '/.git/other';
        mkdir($other);
        $this->git('init', '--quiet', $other);
        $this->git('-C', $other, '-c', 'user.name=Test', '-c', 'user.email=test@example.org', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '-m', 'other');
        $this->git('-C', $other, 'tag', 'v1.3.0');
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            str_replace('## [Unreleased]', "## [Unreleased]\n\n## [1.3.0] - 2026-02-01", self::CHANGELOG),
        );
        $this->fragment('fix-thing.fixed.md', "- A fix.\n");
        $this->scriptEnvironment = ['GIT_DIR' => $other . '/.git'];

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(1, $exit, $stderr);
        self::assertStringContainsString('[1.3.0] has no tag v1.3.0 yet', $stderr);
    }

    #[Test]
    public function anUnreadableFragmentIsAnInputOutputError(): void
    {
        $this->fragment('a.fixed.md', "- A fix.\n");
        chmod($this->repo . '/changelog.d/a.fixed.md', 0o000);
        clearstatcache();

        try {
            if (is_readable($this->repo . '/changelog.d/a.fixed.md')) {
                self::markTestSkipped('The test user can read an unreadable file (root).');
            }

            [$exit, , $stderr] = $this->runScript('check');
        } finally {
            chmod($this->repo . '/changelog.d/a.fixed.md', 0o644);
        }

        self::assertSame(2, $exit);
        self::assertStringContainsString('cannot read', $stderr);
    }

    #[Test]
    public function anUnlistableFragmentDirectoryIsAnInputOutputError(): void
    {
        $this->fragment('a.fixed.md', "- A fix.\n");
        chmod($this->repo . '/changelog.d', 0o300);
        clearstatcache();

        try {
            if (is_readable($this->repo . '/changelog.d')) {
                self::markTestSkipped('The test user can list an unreadable directory (root).');
            }

            [$exit, , $stderr] = $this->runScript('collect');
        } finally {
            chmod($this->repo . '/changelog.d', 0o755);
        }

        self::assertSame(2, $exit);
        self::assertStringContainsString('cannot list', $stderr);
        self::assertSame(self::CHANGELOG, $this->changelog());
    }

    /**
     * The release histories of t3x-contexts ("# 5.1.1", "## Bug Fixes") and
     * t3x-cowriter ("## 3.28.11 (2026-11-25)", "### BUGFIX") below a new
     * [Unreleased] section.
     */
    #[Test]
    #[TestWith(["# 5.1.1\n\n## Bug Fixes\n\n- Old fix.\n\n### Fixed\n\n- Older.\n"])]
    #[TestWith(["## 3.28.11 (2026-11-25)\n\n### BUGFIX\n\n- Old fix.\n\n### Fixed\n\n- Older.\n"])]
    public function collectStopsAtAReleaseHeadingOfAnotherFormat(string $history): void
    {
        $head = "# Changelog\n\nThe format is based on Keep a Changelog.\n\n## [Unreleased]\n\n";
        file_put_contents($this->repo . '/CHANGELOG.md', $head . $history);
        $this->fragment('a.fixed.md', "- A new fix.\n");

        [$exit, , $stderr] = $this->runScript('collect');

        self::assertSame(0, $exit, $stderr);
        self::assertSame($head . "### Fixed\n\n- A new fix.\n\n" . $history, $this->changelog());
    }

    #[Test]
    public function aCommentInAFencedExampleDoesNotEndTheSection(): void
    {
        $fence = str_repeat('`', 3);
        $changelog = "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Run the migration:\n\n{$fence}bash\n# Run the migration\n./migrate\n{$fence}\n\n## [1.2.0] - 2026-01-01\n\n### Fixed\n\n- Released.\n";
        file_put_contents($this->repo . '/CHANGELOG.md', $changelog);
        $this->fragment('a.fixed.md', "- A new fix.\n");

        [$exit, , $stderr] = $this->runScript('collect');

        self::assertSame(0, $exit, $stderr);
        self::assertSame(
            str_replace("{$fence}\n\n## [1.2.0]", "{$fence}\n\n- A new fix.\n\n## [1.2.0]", $changelog),
            $this->changelog(),
        );
    }

    #[Test]
    public function aHeadingWithoutAVersionNumberIsNoRelease(): void
    {
        // t3x-contexts_wurfl keeps its legacy line as "## [0.x] - Legacy".
        file_put_contents(
            $this->repo . '/CHANGELOG.md',
            "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- New.\n\n## [0.x] - Legacy (WURFL)\n\n- Old.\n",
        );
        $this->fragment('a.fixed.md', "- A new fix.\n");

        [$exit, , $stderr] = $this->runScript('check');

        self::assertSame(0, $exit, $stderr);
    }

    private function fragment(string $name, string $text): void
    {
        file_put_contents($this->repo . '/changelog.d/' . $name, $text);
    }

    private function changelog(): string
    {
        return (string) file_get_contents($this->repo . '/CHANGELOG.md');
    }

    /**
     * Run the script in $mode against the throwaway repository.
     *
     * @return array{int, string, string}
     */
    private function runScript(string $mode): array
    {
        return $this->runIn(null, $mode, $this->repo);
    }

    /**
     * Run the script with $args, from $cwd (null: the test's own directory).
     *
     * @return array{int, string, string}
     */
    private function runIn(?string $cwd, string ...$args): array
    {
        $script = dirname(__DIR__, 3) . '/bin/changelog-fragments';

        // nosemgrep: netresearch.php.lang.security.exec-use.exec-use - argv array, no shell; runs PHP or git on a throwaway test repository
        $proc = proc_open(
            [PHP_BINARY, $script, ...$args],
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes,
            $cwd,
            array_replace($this->environment(), $this->scriptEnvironment),
        );

        self::assertIsResource($proc, 'cannot start the script');

        $stdout = (string) stream_get_contents($pipes[1]);
        $stderr = (string) stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);

        return [proc_close($proc), $stdout, $stderr];
    }

    private function git(string ...$args): string
    {
        $command = array_values(['git', '-C', $this->repo, ...$args]);

        // nosemgrep: netresearch.php.lang.security.exec-use.exec-use - argv array, no shell; runs PHP or git on a throwaway test repository
        $proc = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $this->environment());

        self::assertIsResource($proc, 'cannot start git');

        $stdout = (string) stream_get_contents($pipes[1]);
        $stderr = (string) stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);

        self::assertSame(0, proc_close($proc), implode(' ', $command) . ' failed: ' . $stderr);

        return $stdout;
    }

    /**
     * The environment without git's own variables and without the git
     * configuration of the machine.
     *
     * A hook of a linked worktree runs with GIT_DIR and GIT_INDEX_FILE set, and
     * both override `git -C`: the test would then write into that repository. A
     * hook from the global configuration would run in the throwaway repository.
     *
     * @return array<string, string>
     */
    private function environment(): array
    {
        $environment = array_filter(getenv(), static fn (string $name): bool => !str_starts_with($name, 'GIT_'), ARRAY_FILTER_USE_KEY);

        return $environment + ['GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_NOSYSTEM' => '1'];
    }

    private function removeTree(string $dir): void
    {
        if ($dir === '' || !is_dir($dir)) {
            return;
        }

        $items = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST,
        );

        foreach ($items as $item) {
            /** @var SplFileInfo $item */
            // nosemgrep: php.lang.security.unlink-use.unlink-use - removes the test's own temporary directory
            $item->isDir() && !$item->isLink() ? rmdir($item->getPathname()) : unlink($item->getPathname());
        }

        rmdir($dir);
    }
}
