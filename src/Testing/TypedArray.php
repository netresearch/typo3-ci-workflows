<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Testing;

use InvalidArgumentException;
use Symfony\Component\Yaml\Yaml;
use UnexpectedValueException;

/**
 * Typed reads from an untyped array, for tests.
 *
 * TCA, `$GLOBALS['TYPO3_CONF_VARS']` and parsed YAML are `mixed` all the way
 * down. A read names its path — `'columns.title.config.type'`, or a list of keys
 * where a key contains a dot — and returns the value in the type asked for, or
 * throws an UnexpectedValueException that names the source, the path and the
 * type found. Nothing is converted: `"1"` is neither an int nor a bool.
 */
final class TypedArray
{
    /**
     * @param array<mixed> $data
     */
    private function __construct(
        private readonly array $data,
        private readonly string $source,
    ) {}

    /**
     * @param array<mixed> $data
     * @param string       $source how the array is named in an exception message
     */
    public static function fromArray(array $data, string $source = 'array'): self
    {
        return new self($data, $source);
    }

    /**
     * @param string $key the key in `$GLOBALS`, e.g. `TCA` or `TYPO3_CONF_VARS`
     *
     * @throws UnexpectedValueException when `$GLOBALS[$key]` is missing or not an array
     */
    public static function fromGlobals(string $key): self
    {
        $source = sprintf("\$GLOBALS['%s']", $key);

        if (!array_key_exists($key, $GLOBALS)) {
            throw new UnexpectedValueException(sprintf('%s does not exist.', $source));
        }

        return new self(self::rootArray($GLOBALS[$key], $source), $source);
    }

    /**
     * Parses the file with the flags Symfony's YamlFileLoader uses for
     * Services.yaml: `!php/const` resolves to the constant's value, and a
     * custom tag such as `!tagged_iterator` becomes a
     * `Symfony\Component\Yaml\Tag\TaggedValue`. Without the flags the first
     * reads as null and the second fails to parse.
     *
     * @throws UnexpectedValueException when the file does not parse to an array
     */
    public static function fromYamlFile(string $file): self
    {
        return new self(
            self::rootArray(Yaml::parseFile($file, Yaml::PARSE_CONSTANT | Yaml::PARSE_CUSTOM_TAGS), $file),
            $file,
        );
    }

    /**
     * @param string|list<int|string> $path
     *
     * @throws UnexpectedValueException
     */
    public function string(string|array $path): string
    {
        $value = $this->value($path);

        if (!is_string($value)) {
            throw $this->typeMismatch($path, 'string', $value);
        }

        return $value;
    }

    /**
     * @param string|list<int|string> $path
     *
     * @throws UnexpectedValueException
     */
    public function int(string|array $path): int
    {
        $value = $this->value($path);

        if (!is_int($value)) {
            throw $this->typeMismatch($path, 'int', $value);
        }

        return $value;
    }

    /**
     * @param string|list<int|string> $path
     *
     * @throws UnexpectedValueException
     */
    public function bool(string|array $path): bool
    {
        $value = $this->value($path);

        if (!is_bool($value)) {
            throw $this->typeMismatch($path, 'bool', $value);
        }

        return $value;
    }

    /**
     * @param string|list<int|string> $path
     *
     * @return array<mixed>
     *
     * @throws UnexpectedValueException
     */
    public function array(string|array $path): array
    {
        $value = $this->value($path);

        if (!is_array($value)) {
            throw $this->typeMismatch($path, 'array', $value);
        }

        return $value;
    }

    /**
     * @param string|list<int|string> $path
     *
     * @return list<mixed>
     *
     * @throws UnexpectedValueException for a value that is not an array, or an
     *                                  array whose keys are not 0, 1, 2, …
     */
    public function list(string|array $path): array
    {
        $value = $this->value($path);

        if (!is_array($value) || !array_is_list($value)) {
            throw $this->typeMismatch($path, 'list', $value);
        }

        return $value;
    }

    /**
     * @param string|list<int|string> $path
     *
     * @throws UnexpectedValueException when a key on the path is missing, or a
     *                                  value before the last key is not an array
     */
    private function value(string|array $path): mixed
    {
        $keys   = self::keys($path);
        $value  = $this->data;
        $walked = [];

        foreach ($keys as $key) {
            if (!is_array($value)) {
                throw new UnexpectedValueException(sprintf(
                    '%s: no value at "%s", because "%s" is %s, not an array.',
                    $this->source,
                    self::render($keys),
                    self::render($walked),
                    get_debug_type($value),
                ));
            }

            if (!array_key_exists($key, $value)) {
                throw new UnexpectedValueException(sprintf(
                    '%s: no value at "%s", because %s has no key "%s".',
                    $this->source,
                    self::render($keys),
                    $walked === [] ? 'the array' : sprintf('"%s"', self::render($walked)),
                    $key,
                ));
            }

            $value    = $value[$key];
            $walked[] = $key;
        }

        return $value;
    }

    /**
     * @param string|list<int|string> $path
     *
     * @return non-empty-list<int|string>
     *
     * @throws InvalidArgumentException for an empty path or an empty key
     */
    private static function keys(string|array $path): array
    {
        $keys = is_string($path) ? explode('.', $path) : $path;

        if ($keys === [] || in_array('', $keys, true)) {
            throw new InvalidArgumentException(sprintf(
                'TypedArray: the path "%s" has an empty key.',
                is_string($path) ? $path : self::render($path),
            ));
        }

        return $keys;
    }

    /**
     * @param list<int|string> $keys
     */
    private static function render(array $keys): string
    {
        return implode('.', $keys);
    }

    /**
     * @param string|list<int|string> $path
     */
    private function typeMismatch(string|array $path, string $expected, mixed $value): UnexpectedValueException
    {
        return new UnexpectedValueException(sprintf(
            '%s: "%s" is %s, expected %s.',
            $this->source,
            self::render(self::keys($path)),
            get_debug_type($value),
            $expected,
        ));
    }

    /**
     * @return array<mixed>
     */
    private static function rootArray(mixed $value, string $source): array
    {
        if (!is_array($value)) {
            throw new UnexpectedValueException(sprintf('%s is %s, expected array.', $source, get_debug_type($value)));
        }

        return $value;
    }
}
