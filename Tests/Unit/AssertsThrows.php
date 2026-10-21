<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Unit;

use Closure;
use Throwable;

/**
 * Asserts an exception's class and its whole message.
 *
 * PHPUnit 13.4 deprecates expectExceptionMessage(), and its replacement
 * expectExceptionMessageIs() does not exist in PHPUnit 11 and 12, which the
 * package also installs. Catching the exception works with all three.
 */
trait AssertsThrows
{
    /**
     * @param class-string<Throwable> $class
     * @param Closure(): mixed        $call
     */
    private static function assertThrows(string $class, string $message, Closure $call): void
    {
        try {
            $call();
        } catch (Throwable $throwable) {
            self::assertInstanceOf($class, $throwable);
            self::assertSame($message, $throwable->getMessage());

            return;
        }

        self::fail(sprintf('Expected %s with the message "%s"; nothing was thrown.', $class, $message));
    }
}
