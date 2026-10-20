<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Hook;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service\Publisher;

final class DataHandlerHook
{
    public function use(Publisher $dependency): void {}
}
