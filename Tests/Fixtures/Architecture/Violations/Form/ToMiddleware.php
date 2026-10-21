<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Form;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Middleware\Target;

final class ToMiddleware
{
    public function use(Target $dependency): void {}
}
