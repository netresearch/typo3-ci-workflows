<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Command;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Controller\Target;

final class ToController
{
    public function use(Target $dependency): void {}
}
