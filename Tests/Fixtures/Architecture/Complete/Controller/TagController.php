<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Controller;

final class TagController
{
    public function use(ArticleController $dependency): void {}
}
