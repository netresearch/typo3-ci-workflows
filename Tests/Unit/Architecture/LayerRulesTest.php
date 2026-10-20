<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Unit\Architecture;

use FilesystemIterator;
use JsonException;
use PHPUnit\Framework\Attributes\CoversNothing;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;
use RuntimeException;
use SplFileInfo;

/**
 * Runs PHPStan with PHPat over the fixture extensions in Tests/Fixtures/Architecture
 * and checks what the LayerRules trait reports for each of them.
 *
 * One PHPStan run serves every test: the fixtures sit in separate namespaces,
 * and each fixture's ArchitectureTest names its own root.
 *
 * CoversNothing, because the trait runs inside the PHPStan process.
 */
#[CoversNothing]
final class LayerRulesTest extends TestCase
{
    private const FIXTURES = 'Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\\';

    /** @var list<array{rule: string, subject: string, target: string}>|null */
    private static ?array $findings = null;

    /** The directory of the PHPStan run, removed after the class. */
    private static ?string $tmp = null;

    public static function tearDownAfterClass(): void
    {
        if (self::$tmp !== null && is_dir(self::$tmp)) {
            $entries = new RecursiveIteratorIterator(
                new RecursiveDirectoryIterator(self::$tmp, FilesystemIterator::SKIP_DOTS),
                RecursiveIteratorIterator::CHILD_FIRST,
            );

            foreach ($entries as $entry) {
                if (!$entry instanceof SplFileInfo) {
                    continue;
                }

                if ($entry->isDir() && !$entry->isLink()) {
                    rmdir($entry->getPathname());
                } else {
                    unlink($entry->getPathname());
                }
            }

            rmdir(self::$tmp);
        }

        self::$tmp = null;
        parent::tearDownAfterClass();
    }

    #[Test]
    public function everyRuleReportsEachLayerItForbids(): void
    {
        $expected = [];

        foreach (self::forbidden() as $rule => [$subject, $targets]) {
            foreach ($targets as $target) {
                $expected[] = [
                    'rule'    => $rule,
                    'subject' => 'Violations\\' . $subject . '\To' . self::className($target),
                    'target'  => 'Violations\\' . $target . '\Target',
                ];
            }
        }

        self::assertEqualsCanonicalizing($expected, self::findingsIn('Violations'));
    }

    #[Test]
    public function allowedDependenciesBetweenAllLayersPass(): void
    {
        self::assertSame([], self::findingsIn('Complete'));
    }

    #[Test]
    public function rulesForLayersWithoutClassesPass(): void
    {
        self::assertSame([], self::findingsIn('Partial'));
    }

    #[Test]
    public function aLayerInsideAnotherIsNotReportedForDependingOnItself(): void
    {
        self::assertSame(
            [[
                'rule'    => 'testLayerServiceDoesNotDependOnPresentation',
                'subject' => 'Nested\Service\Mailer',
                'target'  => 'Nested\Service\Listener\Helper',
            ]],
            self::findingsIn('Nested'),
        );
    }

    #[Test]
    public function aRuleHiddenAsPrivateDoesNotRun(): void
    {
        self::assertSame([], self::findingsIn('OptOut'));
    }

    /**
     * The rules this package ships: method => [subject namespace, forbidden
     * target namespaces], as the fixtures in Violations/ spell them.
     *
     * @return array<string, array{string, list<string>}>
     */
    private static function forbidden(): array
    {
        return [
            'testLayerDomainDoesNotDependOnOuterLayers'         => ['Domain', ['Service', 'Controller', 'Command', 'Middleware', 'EventListener', 'ViewHelpers', 'Hook', 'Form']],
            'testLayerServiceDoesNotDependOnPresentation'       => ['Service', ['Controller', 'Command', 'Middleware', 'EventListener', 'Form']],
            'testLayerEventDoesNotDependOnServiceOrController'  => ['Event', ['Service', 'Controller']],
            'testLayerEventListenerDoesNotDependOnPresentation' => ['EventListener', ['Controller', 'Middleware', 'Form']],
            'testLayerControllerDoesNotDependOnCommand'         => ['Controller', ['Command']],
            'testLayerCommandDoesNotDependOnController'         => ['Command', ['Controller']],
            'testLayerMiddlewareDoesNotDependOnController'      => ['Middleware', ['Controller']],
            'testLayerViewHelperDoesNotDependOnController'      => ['ViewHelpers', ['Controller']],
            'testLayerFormDoesNotDependOnPresentation'          => ['Form', ['Controller', 'Middleware', 'EventListener']],
            'testLayerHookDoesNotDependOnController'            => ['Hook', ['Controller']],
            'testLayerRepositoryDoesNotDependOnController'      => ['Repository', ['Controller']],
            'testLayerUtilityDoesNotDependOnController'         => ['Utility', ['Controller']],
        ];
    }

    /**
     * The fixture class name for a target namespace: `ViewHelpers` -> `ViewHelper`.
     */
    private static function className(string $targetNamespace): string
    {
        return $targetNamespace === 'ViewHelpers' ? 'ViewHelper' : $targetNamespace;
    }

    /**
     * @return list<array{rule: string, subject: string, target: string}>
     */
    private static function findingsIn(string $fixture): array
    {
        return array_values(array_filter(
            self::findings(),
            static fn (array $finding): bool => str_starts_with($finding['subject'], $fixture . '\\'),
        ));
    }

    /**
     * @return list<array{rule: string, subject: string, target: string}>
     */
    private static function findings(): array
    {
        return self::$findings ??= self::analyse();
    }

    /**
     * @return list<array{rule: string, subject: string, target: string}>
     *
     * @throws RuntimeException when PHPStan fails or reports anything but a PHPat finding
     * @throws JsonException
     */
    private static function analyse(): array
    {
        $root = dirname(__DIR__, 3);
        $tmp  = self::$tmp = sys_get_temp_dir() . '/layer-rules-' . bin2hex(random_bytes(6));

        if (!mkdir($tmp) && !is_dir($tmp)) {
            throw new RuntimeException('Cannot create ' . $tmp);
        }

        $command = [
            PHP_BINARY,
            $root . '/vendor/bin/phpstan',
            'analyse',
            '--configuration=' . $root . '/Tests/Fixtures/Architecture/phpstan.neon',
            '--error-format=json',
            '--no-progress',
            '--memory-limit=1G',
        ];
        $env                    = getenv();
        $env['LAYER_RULES_TMP'] = $tmp;
        // stderr goes to a file: two pipes read one after the other can deadlock.
        $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['file', $tmp . '/stderr', 'w']], $pipes, $root, $env);

        if ($process === false) {
            throw new RuntimeException('Cannot start PHPStan.');
        }

        $stdout = (string) stream_get_contents($pipes[1]);
        fclose($pipes[1]);
        $exit   = proc_close($process);
        $stderr = (string) file_get_contents($tmp . '/stderr');

        // 0: no findings, 1: findings. Anything else is PHPStan failing.
        if ($exit !== 0 && $exit !== 1) {
            throw new RuntimeException(sprintf("PHPStan exited with %d:\n%s\n%s", $exit, $stdout, $stderr));
        }

        $report = json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);

        if (!is_array($report) || !is_array($report['files'] ?? null) || ($report['errors'] ?? null) !== []) {
            throw new RuntimeException("PHPStan reported general errors or no file list:\n" . $stdout . $stderr);
        }

        $findings = [];

        foreach ($report['files'] as $file) {
            foreach (is_array($file) && is_array($file['messages'] ?? null) ? $file['messages'] : [] as $message) {
                $findings[] = self::finding($message);
            }
        }

        return $findings;
    }

    /**
     * @return array{rule: string, subject: string, target: string}
     *
     * @throws RuntimeException for a message that is not a PHPat dependency finding on a fixture
     */
    private static function finding(mixed $message): array
    {
        $identifier = is_array($message) && is_string($message['identifier'] ?? null) ? $message['identifier'] : '';
        $text       = is_array($message) && is_string($message['message'] ?? null) ? $message['message'] : '';
        $pattern    = '/^' . preg_quote(self::FIXTURES, '/') . '(\S+) should not depend on ' . preg_quote(self::FIXTURES, '/') . '(\S+)$/';

        if (!str_starts_with($identifier, 'phpat.') || preg_match($pattern, $text, $match) !== 1) {
            throw new RuntimeException(sprintf('Unexpected PHPStan message [%s]: %s', $identifier, $text));
        }

        return ['rule' => substr($identifier, strlen('phpat.')), 'subject' => $match[1], 'target' => $match[2]];
    }
}
