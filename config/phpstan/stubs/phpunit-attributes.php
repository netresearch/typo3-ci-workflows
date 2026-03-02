<?php

declare(strict_types=1);

/**
 * PHPStan stub for PHPUnit 12 attributes that may not exist in PHPUnit 11.
 *
 * This stub allows PHPStan to analyze code that uses PHPUnit 12 attributes
 * even when running on PHPUnit 11 (PHP 8.2).
 */

namespace PHPUnit\Framework\Attributes;

use Attribute;

#[Attribute(Attribute::TARGET_CLASS)]
final class AllowMockObjectsWithoutExpectations {}
