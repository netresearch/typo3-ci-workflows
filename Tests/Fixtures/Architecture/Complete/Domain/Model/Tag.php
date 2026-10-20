<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Domain\Model;

final class Tag
{
    public function use(Article $dependency): void {}
}
