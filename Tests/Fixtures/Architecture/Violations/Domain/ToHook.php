<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Domain;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Hook\Target;

final class ToHook
{
    public function use(Target $dependency): void {}
}
