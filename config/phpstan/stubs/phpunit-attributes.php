<?php

declare(strict_types=1);

/**
 * PHPStan stub for PHPUnit 12 attributes that may not exist in PHPUnit 11.
 *
 * Loaded via bootstrapFiles so the attribute class exists at runtime
 * (stubFiles only provides type info, which is insufficient for attributes).
 * The class_exists guard prevents "Cannot redeclare class" on PHPUnit 12+
 * where the real class is provided by phpunit/phpunit.
 */

namespace PHPUnit\Framework\Attributes;

if (!class_exists(AllowMockObjectsWithoutExpectations::class, false)) {
    #[\Attribute(\Attribute::TARGET_CLASS)]
    final class AllowMockObjectsWithoutExpectations {}
}
