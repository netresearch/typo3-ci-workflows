<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\EventListener;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Event\ArticlePublished;

final class OnPublished
{
    public function use(ArticlePublished $dependency): void {}
}
