<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Architecture;

use PHPat\Selector\Selector;
use PHPat\Selector\SelectorInterface;
use PHPat\Test\Builder\BuildStep;
use PHPat\Test\PHPat;

/**
 * The layer dependency rules that the extensions using this package assert.
 *
 * A PHPat test class uses the trait and names its layers:
 *
 *     final class ArchitectureTest
 *     {
 *         use LayerRules;
 *
 *         private function layers(): Layers
 *         {
 *             return Layers::below('Vendor\MyExtension');
 *         }
 *     }
 *
 * PHPat runs every public method whose name starts with `test`. Each rule here
 * is one such method, so a project drops a rule by hiding it:
 * `use LayerRules { testLayerControllerDoesNotDependOnCommand as private; }`.
 * The methods carry the prefix `testLayer` so that they do not collide with the
 * names of a project's own rules, which a trait method would silently lose to.
 *
 * Each rule only forbids dependencies, and a layer without classes matches
 * nothing, so a rule for a layer the project does not have passes.
 */
trait LayerRules
{
    public function testLayerDomainDoesNotDependOnOuterLayers(): BuildStep
    {
        return $this->layerRule(
            Layers::DOMAIN,
            [
                Layers::SERVICE,
                Layers::CONTROLLER,
                Layers::COMMAND,
                Layers::MIDDLEWARE,
                Layers::EVENT_LISTENER,
                Layers::VIEW_HELPER,
                Layers::HOOK,
                Layers::FORM,
            ],
            'The domain layer is innermost and must not depend on services or on the layers that handle requests, commands and events.',
        );
    }

    public function testLayerServiceDoesNotDependOnPresentation(): BuildStep
    {
        return $this->layerRule(
            Layers::SERVICE,
            [Layers::CONTROLLER, Layers::COMMAND, Layers::MIDDLEWARE, Layers::EVENT_LISTENER, Layers::FORM],
            'Services are called by controllers, commands, middlewares, event listeners and forms, never the other way round.',
        );
    }

    public function testLayerEventDoesNotDependOnServiceOrController(): BuildStep
    {
        return $this->layerRule(
            Layers::EVENT,
            [Layers::SERVICE, Layers::CONTROLLER],
            'Events carry data and must not depend on services or controllers.',
        );
    }

    public function testLayerEventListenerDoesNotDependOnPresentation(): BuildStep
    {
        return $this->layerRule(
            Layers::EVENT_LISTENER,
            [Layers::CONTROLLER, Layers::MIDDLEWARE, Layers::FORM],
            'Event listeners must not depend on controllers, middlewares or forms.',
        );
    }

    public function testLayerControllerDoesNotDependOnCommand(): BuildStep
    {
        return $this->layerRule(
            Layers::CONTROLLER,
            [Layers::COMMAND],
            'Controllers must not invoke console command classes; both call services.',
        );
    }

    public function testLayerCommandDoesNotDependOnController(): BuildStep
    {
        return $this->layerRule(
            Layers::COMMAND,
            [Layers::CONTROLLER],
            'Console commands must not depend on controllers.',
        );
    }

    public function testLayerMiddlewareDoesNotDependOnController(): BuildStep
    {
        return $this->layerRule(
            Layers::MIDDLEWARE,
            [Layers::CONTROLLER],
            'Middlewares must not depend on controllers.',
        );
    }

    public function testLayerViewHelperDoesNotDependOnController(): BuildStep
    {
        return $this->layerRule(
            Layers::VIEW_HELPER,
            [Layers::CONTROLLER],
            'View helpers must not depend on controllers.',
        );
    }

    public function testLayerFormDoesNotDependOnPresentation(): BuildStep
    {
        return $this->layerRule(
            Layers::FORM,
            [Layers::CONTROLLER, Layers::MIDDLEWARE, Layers::EVENT_LISTENER],
            'Form elements render UI and must not depend on controllers, middlewares or event listeners.',
        );
    }

    public function testLayerHookDoesNotDependOnController(): BuildStep
    {
        return $this->layerRule(
            Layers::HOOK,
            [Layers::CONTROLLER],
            'Hooks must not depend on controllers.',
        );
    }

    public function testLayerRepositoryDoesNotDependOnController(): BuildStep
    {
        return $this->layerRule(
            Layers::REPOSITORY,
            [Layers::CONTROLLER],
            'Repositories must not depend on controllers.',
        );
    }

    public function testLayerUtilityDoesNotDependOnController(): BuildStep
    {
        return $this->layerRule(
            Layers::UTILITY,
            [Layers::CONTROLLER],
            'Utilities must not depend on controllers.',
        );
    }

    /**
     * The project's layers. Private, so that PHPat does not take it for a rule.
     */
    abstract private function layers(): Layers;

    /**
     * A rule that the subject layer must not depend on the target layers.
     *
     * A target namespace inside a subject namespace is excluded from the
     * subjects, and a subject namespace inside a target namespace from the
     * targets, so that a class never breaks a rule by depending on its own layer.
     *
     * @param list<string> $targetLayers
     */
    private function layerRule(string $subjectLayer, array $targetLayers, string $because): BuildStep
    {
        $layers   = $this->layers();
        $subjects = $layers->of($subjectLayer);
        $targets  = [];

        foreach ($targetLayers as $targetLayer) {
            array_push($targets, ...$layers->of($targetLayer));
        }

        $subjectExcludes = self::layerNamespacesInside($targets, $subjects);
        $targetExcludes  = self::layerNamespacesInside($subjects, $targets);

        return PHPat::rule()
            ->classes(...self::layerSelectors($subjects))
            ->excluding(...self::layerSelectors($subjectExcludes))
            ->shouldNot()
            ->dependOn()
            ->classes(...self::layerSelectors($targets))
            ->excluding(...self::layerSelectors($targetExcludes))
            ->because($because);
    }

    /**
     * @param list<non-empty-string> $candidates
     * @param list<non-empty-string> $outer
     *
     * @return list<non-empty-string> the candidates that lie inside one of the outer namespaces;
     *                                Layers never puts one namespace into two layers, so a candidate
     *                                is never equal to an outer namespace
     */
    private static function layerNamespacesInside(array $candidates, array $outer): array
    {
        $inside = [];

        foreach ($candidates as $candidate) {
            foreach ($outer as $namespace) {
                if (str_starts_with($candidate . '\\', $namespace . '\\')) {
                    $inside[] = $candidate;

                    break;
                }
            }
        }

        return $inside;
    }

    /**
     * @param list<non-empty-string> $namespaces
     *
     * @return list<SelectorInterface>
     */
    private static function layerSelectors(array $namespaces): array
    {
        return array_map(static fn (string $namespace): SelectorInterface => Selector::inNamespace($namespace), $namespaces);
    }
}
