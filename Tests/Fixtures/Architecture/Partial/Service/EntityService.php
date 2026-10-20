<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Partial\Service;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Partial\Domain\Entity;

final class EntityService
{
    public function use(Entity $dependency): void {}
}
