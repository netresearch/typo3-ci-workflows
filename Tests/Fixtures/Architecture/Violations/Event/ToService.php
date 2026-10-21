<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Event;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Service\Target;

final class ToService
{
    public function use(Target $dependency): void {}
}
