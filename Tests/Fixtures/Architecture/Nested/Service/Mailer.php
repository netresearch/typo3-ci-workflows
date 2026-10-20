<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Nested\Service;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Nested\Service\Listener\Helper;

final class Mailer
{
    public function use(Helper $dependency): void {}
}
