<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Event;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Domain\Model\Article;

final class ArticlePublished
{
    public function use(Article $dependency): void {}
}
