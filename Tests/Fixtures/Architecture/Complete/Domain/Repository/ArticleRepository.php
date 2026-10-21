<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Domain\Repository;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Domain\Model\Article;

final class ArticleRepository
{
    public function use(Article $dependency): void {}
}
