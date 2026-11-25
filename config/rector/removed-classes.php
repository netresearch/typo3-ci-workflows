<?php

/*
 * Value objects Rector 2.9.0 removed and ssch/typo3-rector still uses.
 *
 * ssch/typo3-rector 3.17.0 allows every Rector 2.x from 2.8.3 on, but its
 * TYPO3 10 and 11 sets and its strict-types sets construct these classes, so
 * loading a Typo3LevelSetList ends with "Class ... not found". Each class is
 * declared only while Rector does not bring it. Once a release of
 * ssch/typo3-rector works without them and composer.json requires it, this
 * file can go.
 */

declare(strict_types=1);

namespace Rector\Transform\ValueObject {
    use PHPStan\Type\ObjectType;

    if (!class_exists(MethodCallToStaticCall::class)) {
        final class MethodCallToStaticCall
        {
            public function __construct(
                private readonly string $oldClass,
                private readonly string $oldMethod,
                private readonly string $newClass,
                private readonly string $newMethod,
            ) {}

            public function getOldObjectType(): ObjectType
            {
                return new ObjectType($this->oldClass);
            }

            public function getOldMethod(): string
            {
                return $this->oldMethod;
            }

            public function getNewClass(): string
            {
                return $this->newClass;
            }

            public function getNewMethod(): string
            {
                return $this->newMethod;
            }
        }
    }
}

namespace Rector\Renaming\ValueObject {
    use PHPStan\Type\ObjectType;

    if (!class_exists(RenameStaticMethod::class)) {
        final class RenameStaticMethod
        {
            public function __construct(
                private readonly string $oldClass,
                private readonly string $oldMethod,
                private readonly string $newClass,
                private readonly string $newMethod,
            ) {}

            public function getOldObjectType(): ObjectType
            {
                return new ObjectType($this->oldClass);
            }

            public function getOldMethod(): string
            {
                return $this->oldMethod;
            }

            public function getNewClass(): string
            {
                return $this->newClass;
            }

            public function getNewMethod(): string
            {
                return $this->newMethod;
            }

            public function hasClassChanged(): bool
            {
                return $this->oldClass !== $this->newClass;
            }
        }
    }
}

namespace Rector\TypeDeclaration\ValueObject {
    use PHPStan\Type\Type;

    if (!class_exists(AddPropertyTypeDeclaration::class)) {
        final class AddPropertyTypeDeclaration
        {
            public function __construct(
                private readonly string $class,
                private readonly string $propertyName,
                private readonly Type $type,
            ) {}

            public function getClass(): string
            {
                return $this->class;
            }

            public function getPropertyName(): string
            {
                return $this->propertyName;
            }

            public function getType(): Type
            {
                return $this->type;
            }
        }
    }
}
