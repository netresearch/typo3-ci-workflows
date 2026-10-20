<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\EventListener;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Violations\Form\Target;

final class ToForm
{
    public function use(Target $dependency): void {}
}
