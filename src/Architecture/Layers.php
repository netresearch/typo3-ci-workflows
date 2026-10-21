<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Architecture;

use InvalidArgumentException;

/**
 * The namespaces of an extension's layers, for the rules in LayerRules.
 *
 * Every layer has a conventional namespace below the extension's root. A layer
 * the extension does not have keeps that namespace: no class matches it, so its
 * rules pass, and they start to apply when a class of that layer is added.
 */
final class Layers
{
    public const DOMAIN = 'domain';

    public const REPOSITORY = 'repository';

    public const SERVICE = 'service';

    public const EVENT = 'event';

    public const EVENT_LISTENER = 'eventListener';

    public const CONTROLLER = 'controller';

    public const COMMAND = 'command';

    public const MIDDLEWARE = 'middleware';

    public const VIEW_HELPER = 'viewHelper';

    public const HOOK = 'hook';

    public const FORM = 'form';

    public const UTILITY = 'utility';

    /**
     * The namespaces below the root that a layer has when the extension does
     * not name its own. Each spelling in a list was found in at least one
     * extension that uses this package.
     */
    private const CONVENTIONAL = [
        self::DOMAIN         => ['Domain'],
        self::REPOSITORY     => ['Domain\Repository', 'Repository'],
        self::SERVICE        => ['Service'],
        self::EVENT          => ['Event'],
        self::EVENT_LISTENER => ['EventListener', 'Listener'],
        self::CONTROLLER     => ['Controller'],
        self::COMMAND        => ['Command'],
        self::MIDDLEWARE     => ['Middleware'],
        self::VIEW_HELPER    => ['ViewHelpers', 'ViewHelper'],
        self::HOOK           => ['Hook', 'Hooks'],
        self::FORM           => ['Form'],
        self::UTILITY        => ['Utility', 'Utils'],
    ];

    /**
     * @param array<string, non-empty-list<non-empty-string>> $namespaces absolute namespaces per layer
     */
    private function __construct(
        private readonly array $namespaces,
    ) {}

    /**
     * @param string                             $root      the extension's root namespace, e.g. `Vendor\MyExtension`
     * @param array<string, string|list<string>> $overrides namespaces below the root, per layer, replacing the conventional ones
     *
     * @throws InvalidArgumentException for an empty root, an unknown layer, an empty
     *                                  namespace list, or a namespace in two layers
     */
    public static function below(string $root, array $overrides = []): self
    {
        $root = trim($root, '\\');

        if ($root === '') {
            throw new InvalidArgumentException('Layers: the root namespace is empty.');
        }

        $relative = self::CONVENTIONAL;

        foreach ($overrides as $layer => $names) {
            if (!array_key_exists($layer, self::CONVENTIONAL)) {
                throw new InvalidArgumentException(sprintf(
                    'Layers: unknown layer "%s"; known layers are %s.',
                    $layer,
                    implode(', ', array_keys(self::CONVENTIONAL)),
                ));
            }

            $names = is_string($names) ? [$names] : $names;

            if ($names === []) {
                throw new InvalidArgumentException(sprintf(
                    'Layers: layer "%s" has no namespace. To drop a rule, hide its method (see LayerRules).',
                    $layer,
                ));
            }

            $relative[$layer] = $names;
        }

        $namespaces = [];
        $owner      = [];

        foreach ($relative as $layer => $names) {
            foreach ($names as $name) {
                $name = trim($name, '\\');

                if ($name === '') {
                    throw new InvalidArgumentException(sprintf('Layers: layer "%s" has an empty namespace.', $layer));
                }

                $namespace = $root . '\\' . $name;

                if (isset($owner[$namespace])) {
                    if ($owner[$namespace] === $layer) {
                        continue;
                    }

                    throw new InvalidArgumentException(sprintf(
                        'Layers: namespace "%s" is in layer "%s" and in layer "%s".',
                        $namespace,
                        $owner[$namespace],
                        $layer,
                    ));
                }

                $owner[$namespace]    = $layer;
                $namespaces[$layer][] = $namespace;
            }
        }

        return new self($namespaces);
    }

    /**
     * @return non-empty-list<non-empty-string>
     *
     * @throws InvalidArgumentException for an unknown layer
     */
    public function of(string $layer): array
    {
        if (!isset($this->namespaces[$layer])) {
            throw new InvalidArgumentException(sprintf('Layers: unknown layer "%s".', $layer));
        }

        return $this->namespaces[$layer];
    }
}
