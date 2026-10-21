<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Middleware;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service\Publisher;

final class ArticleMiddleware
{
    public function use(Publisher $dependency): void {}
}
