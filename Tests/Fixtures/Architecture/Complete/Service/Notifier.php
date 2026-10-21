<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Event\ArticlePublished;

final class Notifier
{
    public function use(ArticlePublished $dependency): void {}
}
