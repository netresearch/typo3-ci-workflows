<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Form;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\Complete\Service\Publisher;

final class ArticleElement
{
    public function use(Publisher $dependency): void {}
}
