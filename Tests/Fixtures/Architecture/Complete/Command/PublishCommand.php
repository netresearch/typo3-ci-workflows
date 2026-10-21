<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Command;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service\Publisher;

final class PublishCommand
{
    public function use(Publisher $dependency): void {}
}
