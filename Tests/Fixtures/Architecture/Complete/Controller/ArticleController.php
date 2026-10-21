<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Controller;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service\Publisher;

final class ArticleController
{
    public function use(Publisher $dependency): void {}
}
