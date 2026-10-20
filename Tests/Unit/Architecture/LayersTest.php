<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Unit\Architecture;

use InvalidArgumentException;
use Netresearch\Typo3CiWorkflows\Architecture\Layers;
use Netresearch\Typo3CiWorkflows\Tests\Unit\AssertsThrows;
use PHPUnit\Framework\Attributes\CoversClass;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;

#[CoversClass(Layers::class)]
final class LayersTest extends TestCase
{
    use AssertsThrows;

    /**
     * @return iterable<string, array{string, list<string>}>
     */
    public static function conventionalNamespaces(): iterable
    {
        yield 'domain' => [Layers::DOMAIN, ['V\E\Domain']];
        yield 'repository' => [Layers::REPOSITORY, ['V\E\Domain\Repository', 'V\E\Repository']];
        yield 'service' => [Layers::SERVICE, ['V\E\Service']];
        yield 'event' => [Layers::EVENT, ['V\E\Event']];
        yield 'event listener' => [Layers::EVENT_LISTENER, ['V\E\EventListener', 'V\E\Listener']];
        yield 'controller' => [Layers::CONTROLLER, ['V\E\Controller']];
        yield 'command' => [Layers::COMMAND, ['V\E\Command']];
        yield 'middleware' => [Layers::MIDDLEWARE, ['V\E\Middleware']];
        yield 'view helper' => [Layers::VIEW_HELPER, ['V\E\ViewHelpers', 'V\E\ViewHelper']];
        yield 'hook' => [Layers::HOOK, ['V\E\Hook', 'V\E\Hooks']];
        yield 'form' => [Layers::FORM, ['V\E\Form']];
        yield 'utility' => [Layers::UTILITY, ['V\E\Utility', 'V\E\Utils']];
    }

    /**
     * @param list<string> $expected
     */
    #[Test]
    #[DataProvider('conventionalNamespaces')]
    public function aLayerWithoutOverrideHasItsConventionalNamespaces(string $layer, array $expected): void
    {
        self::assertSame($expected, Layers::below('V\E')->of($layer));
    }

    #[Test]
    public function separatorsAroundTheRootAndANameAreDropped(): void
    {
        $layers = Layers::below('\V\E\\', [Layers::SERVICE => '\Application\Service\\']);

        self::assertSame(['V\E\Domain'], $layers->of(Layers::DOMAIN));
        self::assertSame(['V\E\Application\Service'], $layers->of(Layers::SERVICE));
    }

    #[Test]
    public function anOverrideReplacesTheConventionalNamespacesOfItsLayerOnly(): void
    {
        $layers = Layers::below('V\E', [
            Layers::EVENT_LISTENER => ['Backend\EventListener', 'Frontend\EventListener'],
            Layers::CONTROLLER     => 'Http\Controller',
        ]);

        self::assertSame(['V\E\Backend\EventListener', 'V\E\Frontend\EventListener'], $layers->of(Layers::EVENT_LISTENER));
        self::assertSame(['V\E\Http\Controller'], $layers->of(Layers::CONTROLLER));
        self::assertSame(['V\E\Service'], $layers->of(Layers::SERVICE));
    }

    #[Test]
    public function aNamespaceNamedTwiceInOneLayerIsKeptOnce(): void
    {
        self::assertSame(['V\E\Service'], Layers::below('V\E', [Layers::SERVICE => ['Service', '\Service']])->of(Layers::SERVICE));
    }

    /**
     * @return iterable<string, array{string, array<string, string|list<string>>, string}>
     */
    public static function invalidLayers(): iterable
    {
        yield 'empty root' => ['\\', [], 'Layers: the root namespace is empty.'];
        yield 'unknown layer' => ['V\E', ['model' => 'Domain\Model'], 'Layers: unknown layer "model"; known layers are domain, repository, service, event, eventListener, controller, command, middleware, viewHelper, hook, form, utility.'];
        yield 'empty list' => ['V\E', [Layers::FORM => []], 'Layers: layer "form" has no namespace. To drop a rule, hide its method (see LayerRules).'];
        yield 'empty name' => ['V\E', [Layers::FORM => ['Form', '\\']], 'Layers: layer "form" has an empty namespace.'];
        yield 'namespace in two layers' => ['V\E', [Layers::HOOK => 'Service'], 'Layers: namespace "V\E\Service" is in layer "service" and in layer "hook".'];
    }

    /**
     * @param array<string, string|list<string>> $overrides
     */
    #[Test]
    #[DataProvider('invalidLayers')]
    public function anInvalidDefinitionThrows(string $root, array $overrides, string $message): void
    {
        self::assertThrows(
            InvalidArgumentException::class,
            $message,
            fn (): mixed => Layers::below($root, $overrides),
        );
    }

    #[Test]
    public function askingForAnUnknownLayerThrows(): void
    {
        self::assertThrows(
            InvalidArgumentException::class,
            'Layers: unknown layer "model".',
            fn (): mixed => Layers::below('V\E')->of('model'),
        );
    }
}
