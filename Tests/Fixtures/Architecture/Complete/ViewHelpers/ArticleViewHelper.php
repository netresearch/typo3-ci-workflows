<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\ViewHelpers;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Domain\Model\Article;

final class ArticleViewHelper
{
    public function use(Article $dependency): void {}
}
