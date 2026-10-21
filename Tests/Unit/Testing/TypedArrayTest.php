<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Unit\Testing;

use InvalidArgumentException;
use Netresearch\Typo3CiWorkflows\Testing\TypedArray;
use Netresearch\Typo3CiWorkflows\Tests\Unit\AssertsThrows;
use PHPUnit\Framework\Attributes\CoversClass;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;
use stdClass;
use UnexpectedValueException;

#[CoversClass(TypedArray::class)]
final class TypedArrayTest extends TestCase
{
    use AssertsThrows;

    private const DATA = [
        'ctrl'     => ['title' => 'Pages', 'sortby' => 10, 'hideTable' => false, 'ratio' => 1.5],
        'columns'  => ['title' => ['config' => ['type' => 'input', 'items' => [['label' => 'A'], ['label' => 'B']]]]],
        'numeric'  => '1',
        'nothing'  => null,
        'map'      => [1 => 'a', 2 => 'b'],
        'features' => ['security.backend.enforceReferrer' => true],
    ];

    /** @var list<string> */
    private array $files = [];

    protected function tearDown(): void
    {
        unset($GLOBALS['TYPED_ARRAY_TEST']);

        foreach ($this->files as $file) {
            unlink($file);
        }

        parent::tearDown();
    }

    #[Test]
    public function eachReadReturnsTheValueAtItsPath(): void
    {
        $data = TypedArray::fromArray(self::DATA);

        self::assertSame('Pages', $data->string('ctrl.title'));
        self::assertSame(10, $data->int('ctrl.sortby'));
        self::assertFalse($data->bool('ctrl.hideTable'));
        self::assertSame(['type' => 'input', 'items' => [['label' => 'A'], ['label' => 'B']]], $data->array('columns.title.config'));
        self::assertSame([['label' => 'A'], ['label' => 'B']], $data->list('columns.title.config.items'));
    }

    #[Test]
    public function aNumericSegmentReadsAListEntry(): void
    {
        self::assertSame('B', TypedArray::fromArray(self::DATA)->string('columns.title.config.items.1.label'));
    }

    #[Test]
    public function aListOfKeysReachesAKeyThatContainsADot(): void
    {
        self::assertTrue(TypedArray::fromArray(self::DATA)->bool(['features', 'security.backend.enforceReferrer']));
    }

    /**
     * @return iterable<string, array{string, string}>
     */
    public static function typeMismatches(): iterable
    {
        yield 'numeric string is no int' => ['int', 'data: "numeric" is string, expected int.'];
        yield 'numeric string is no bool' => ['bool', 'data: "numeric" is string, expected bool.'];
        yield 'float is no int' => ['int:ctrl.ratio', 'data: "ctrl.ratio" is float, expected int.'];
        yield 'int is no string' => ['string:ctrl.sortby', 'data: "ctrl.sortby" is int, expected string.'];
        yield 'null is reported as null' => ['string:nothing', 'data: "nothing" is null, expected string.'];
        yield 'string is no array' => ['array:ctrl.title', 'data: "ctrl.title" is string, expected array.'];
        yield 'map is no list' => ['list:map', 'data: "map" is array, expected list.'];
        yield 'string is no list' => ['list:numeric', 'data: "numeric" is string, expected list.'];
    }

    #[Test]
    #[DataProvider('typeMismatches')]
    public function aValueOfAnotherTypeThrowsNamingPathAndType(string $read, string $message): void
    {
        [$method, $path] = str_contains($read, ':') ? explode(':', $read, 2) : [$read, 'numeric'];
        $data            = TypedArray::fromArray(self::DATA, 'data');

        self::assertThrows(
            UnexpectedValueException::class,
            $message,
            fn (): mixed => match ($method) {
                'string' => $data->string($path),
                'int'    => $data->int($path),
                'bool'   => $data->bool($path),
                'array'  => $data->array($path),
                'list'   => $data->list($path),
                default  => self::fail('unknown read ' . $method),
            },
        );
    }

    #[Test]
    public function aMissingKeyThrowsNamingTheFullPathAndWhereItStopped(): void
    {
        self::assertThrows(
            UnexpectedValueException::class,
            'TCA: no value at "columns.title.config.renderType", because "columns.title.config" has no key "renderType".',
            fn (): mixed => TypedArray::fromArray(self::DATA, 'TCA')->string('columns.title.config.renderType'),
        );
    }

    #[Test]
    public function aMissingFirstKeyNamesTheArray(): void
    {
        self::assertThrows(
            UnexpectedValueException::class,
            'array: no value at "palettes.general", because the array has no key "palettes".',
            fn (): mixed => TypedArray::fromArray(self::DATA)->array('palettes.general'),
        );
    }

    #[Test]
    public function aScalarOnThePathThrowsNamingItsType(): void
    {
        self::assertThrows(
            UnexpectedValueException::class,
            'array: no value at "ctrl.sortby.min", because "ctrl.sortby" is int, not an array.',
            fn (): mixed => TypedArray::fromArray(self::DATA)->int('ctrl.sortby.min'),
        );
    }

    /**
     * @return iterable<string, array{string|list<int|string>, string}>
     */
    public static function emptyPaths(): iterable
    {
        yield 'empty string' => ['', 'TypedArray: the path "" has an empty key.'];
        yield 'double dot' => ['ctrl..title', 'TypedArray: the path "ctrl..title" has an empty key.'];
        yield 'empty list' => [[], 'TypedArray: the path "" has an empty key.'];
        yield 'empty key in list' => [['ctrl', ''], 'TypedArray: the path "ctrl." has an empty key.'];
    }

    /**
     * @param string|list<int|string> $path
     */
    #[Test]
    #[DataProvider('emptyPaths')]
    public function aPathWithAnEmptyKeyIsRefused(string|array $path, string $message): void
    {
        self::assertThrows(
            InvalidArgumentException::class,
            $message,
            fn (): mixed => TypedArray::fromArray(self::DATA)->string($path),
        );
    }

    #[Test]
    public function fromGlobalsReadsTheGlobalAndNamesItInMessages(): void
    {
        $this->setGlobal(['SYS' => ['sitename' => 'Site']]);
        $data = TypedArray::fromGlobals('TYPED_ARRAY_TEST');

        self::assertSame('Site', $data->string('SYS.sitename'));
        self::assertThrows(
            UnexpectedValueException::class,
            "\$GLOBALS['TYPED_ARRAY_TEST']: \"SYS.sitename\" is string, expected int.",
            fn (): mixed => $data->int('SYS.sitename'),
        );
    }

    #[Test]
    public function fromGlobalsRefusesAMissingGlobal(): void
    {
        self::assertThrows(
            UnexpectedValueException::class,
            "\$GLOBALS['TYPED_ARRAY_TEST_MISSING'] does not exist.",
            fn (): mixed => TypedArray::fromGlobals('TYPED_ARRAY_TEST_MISSING'),
        );
    }

    #[Test]
    public function fromGlobalsRefusesAGlobalThatIsNoArray(): void
    {
        $this->setGlobal(new stdClass());

        self::assertThrows(
            UnexpectedValueException::class,
            "\$GLOBALS['TYPED_ARRAY_TEST'] is stdClass, expected array.",
            fn (): mixed => TypedArray::fromGlobals('TYPED_ARRAY_TEST'),
        );
    }

    #[Test]
    public function fromYamlFileReadsTheParsedFileAndNamesItInMessages(): void
    {
        $file = $this->yamlFile("imports:\n  - { resource: 'Base.yaml' }\nsettings:\n  limit: 5\n");
        $data = TypedArray::fromYamlFile($file);

        self::assertSame('Base.yaml', $data->string('imports.0.resource'));
        self::assertThrows(
            UnexpectedValueException::class,
            $file . ': "settings.limit" is int, expected string.',
            fn (): mixed => $data->string('settings.limit'),
        );
    }

    #[Test]
    public function fromYamlFileReadsAServicesFileWithConstantsAndCustomTags(): void
    {
        $file = $this->yamlFile(
            "services:\n  _defaults:\n    autowire: true\n  Vendor\\Ext\\Foo:\n    arguments:\n"
            . "      \$handlers: !tagged_iterator vendor.handler\n      \$level: !php/const E_ALL\n",
        );
        $data = TypedArray::fromYamlFile($file);

        self::assertTrue($data->bool('services._defaults.autowire'));
        self::assertSame(E_ALL, $data->int(['services', 'Vendor\Ext\Foo', 'arguments', '$level']));
        self::assertThrows(
            UnexpectedValueException::class,
            $file . ': "services.Vendor\Ext\Foo.arguments.$handlers" is Symfony\Component\Yaml\Tag\TaggedValue, expected string.',
            fn (): mixed => $data->string(['services', 'Vendor\Ext\Foo', 'arguments', '$handlers']),
        );
    }

    #[Test]
    public function fromYamlFileRefusesAFileThatIsNoMapping(): void
    {
        $file = $this->yamlFile("just a string\n");

        self::assertThrows(
            UnexpectedValueException::class,
            $file . ' is string, expected array.',
            fn (): mixed => TypedArray::fromYamlFile($file),
        );
    }

    private function setGlobal(mixed $value): void
    {
        $GLOBALS['TYPED_ARRAY_TEST'] = $value;
    }

    private function yamlFile(string $content): string
    {
        $file = tempnam(sys_get_temp_dir(), 'typed-array-');
        self::assertIsString($file);
        $this->files[] = $file;
        file_put_contents($file, $content);

        return $file;
    }
}
