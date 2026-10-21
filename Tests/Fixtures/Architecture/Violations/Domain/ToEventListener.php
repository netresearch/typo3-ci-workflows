<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Domain;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\EventListener\Target;

final class ToEventListener
{
    public function use(Target $dependency): void {}
}
