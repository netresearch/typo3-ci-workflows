<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Domain\Repository\ArticleRepository;

final class Publisher
{
    public function use(ArticleRepository $dependency): void {}
}
